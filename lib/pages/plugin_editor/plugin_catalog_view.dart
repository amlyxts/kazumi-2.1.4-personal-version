import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/bean/card/rule_card.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/widget/error_widget.dart';
import 'package:kazumi/bean/widget/kazumi_menu.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/bean/widget/loading_indicator.dart';
import 'package:kazumi/bean/widget/state_presentation.dart';
import 'package:kazumi/modules/plugin/plugin_http_module.dart';
import 'package:kazumi/pages/plugin_editor/plugin_update_actions.dart';
import 'package:kazumi/request/apis/plugin_catalog_api.dart';
import 'package:kazumi/services/plugin/rule_llm_audit_service.dart';
import 'package:kazumi/pages/plugin_editor/rule_management_widgets.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/storage/storage.dart';

enum _CatalogSort { lastUpdate, name }

enum _CatalogFilter { all, installed, updates }

class PluginCatalogView extends StatefulWidget {
  const PluginCatalogView({
    super.key,
    required this.controller,
  }) : _scrollViewBuilder = null;

  const PluginCatalogView.onboarding({
    super.key,
    required this.controller,
    required Widget Function(BuildContext context, List<Widget> slivers)
        builder,
  }) : _scrollViewBuilder = builder;

  final PluginsController controller;
  final Widget Function(BuildContext context, List<Widget> slivers)?
      _scrollViewBuilder;

  bool get _onboarding => _scrollViewBuilder != null;

  @override
  State<PluginCatalogView> createState() => _PluginCatalogViewState();
}

class _PluginCatalogViewState extends State<PluginCatalogView> {
  final _search = TextEditingController();
  final Set<String> _installing = {};
  _CatalogSort _sort = _CatalogSort.lastUpdate;
  _CatalogFilter _filter = _CatalogFilter.all;
  bool _loading = true;
  bool _loadFailed = false;

  // [my修改] 仓库切换: 打开页面默认官方仓库, 切到自定义仓库按需加载
  List<RuleRepo> _repos = [];
  String? _selectedRepoBase;

  PluginsController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _repos = PluginCatalogApi.listRepos();
    if (_controller.isPluginCatalogFresh) {
      _loading = false;
    } else {
      unawaited(_loadPluginCatalog());
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadPluginCatalog({bool forceRefresh = false}) async {
    try {
      if (forceRefresh) {
        await _controller.refreshPluginCatalog();
      } else {
        await _controller.ensurePluginCatalog();
      }
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
      }
    }
  }

  Future<void> _switchRepo(RuleRepo? repo) async {
    final targetBase = repo?.base;
    final targetName = repo?.name ?? '官方仓库';
    if (_selectedRepoBase == targetBase) return;
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      await _controller.switchCatalogForRepo(targetBase, targetName);
      if (mounted) {
        setState(() {
          _selectedRepoBase = targetBase;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
        KazumiDialog.showToast(message: '切换到「$targetName」失败, 请检查仓库地址或网络');
      }
    }
  }

  void _refresh() {
    if (_loading) return;
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    unawaited(_loadPluginCatalog(forceRefresh: true));
  }

  Future<void> _toggleGitProxyAndRefresh() async {
    try {
      final enabled = GStorage.getSetting(SettingsKeys.enableGitProxy);
      await GStorage.putSetting(SettingsKeys.enableGitProxy, !enabled);
      if (mounted) _refresh();
    } catch (_) {
      KazumiDialog.showToast(message: '切换规则镜像失败，请重试');
    }
  }

  /// [my修改] 第三方仓库的高危规则安装确认: 目录条目带 antiCrawlerEnabled
  /// (自定义 JS 验证脚本类) 且来自自定义仓库时, 先拉规则全文做 LLM 审查,
  /// 对话框展示 AI 判定与证据引用后由用户决定。
  /// 官方仓库规则不弹 (作者已审), 但同类规则仍建议用测试器 --audit 复核。
  Future<bool> _confirmRiskyInstall(PluginHTTPItem item) async {
    if (item.sourceBase.isEmpty || !item.antiCrawlerEnabled) return true;
    final theme = Theme.of(context);
    RuleLlmAuditResult? audit;
    var auditing = RuleLlmAuditService.configured;
    if (auditing) {
      // 拉规则全文交给 LLM 审 (失败/无渠道则 auditing=false, 仅静态提示)
      try {
        final plugin = await PluginCatalogApi.getPlugin(item.name,
            base: item.sourceBase);
        audit = await RuleLlmAuditService.audit(json.encode(plugin.toJson()));
      } catch (_) {
        auditing = false;
      }
    }
    if (!mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          scrollable: true,
          title: Text(audit?.malicious == true
              ? 'AI 审查: 疑似恶意规则'
              : '安装含验证脚本的规则?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '「${item.name}」来自自定义仓库, 带有反爬验证配置。'
                '若其为"自定义脚本"型 (captchaType 3), 安装后规则提供的 '
                'JavaScript 将在应用的 WebView 中执行。',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              if (audit != null) ...[
                Text(
                  audit.malicious
                      ? 'AI 判定: 恶意 (建议拒绝安装)'
                      : audit.suspicious
                          ? 'AI 判定: 可疑 (请人工核实)'
                          : 'AI 判定: 良性',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: audit.malicious
                        ? theme.colorScheme.error
                        : audit.suspicious
                            ? theme.colorScheme.tertiary
                            : theme.colorScheme.primary,
                  ),
                ),
                if (audit.summary.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(audit.summary,
                      style: theme.textTheme.bodySmall),
                ],
                for (final f in audit.findings.take(4)) ...[
                  const SizedBox(height: 8),
                  Text('• \${f.risk}', style: theme.textTheme.bodySmall),
                  if (f.evidence.isNotEmpty)
                    Text('  证据: \${f.evidence}',
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            fontFamily: 'monospace')),
                ],
              ] else if (auditing) ...[
                const Center(child: CircularProgressIndicator()),
              ] else ...[
                Text('(未配置审查渠道, 无法 AI 审读; 可在 网络设置→验证码自动识别 配置)',
                    style: theme.textTheme.bodySmall),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(audit?.malicious == true ? '拒绝' : '取消'),
            ),
            FilledButton(
              style: audit?.malicious == true
                  ? FilledButton.styleFrom(
                      backgroundColor: theme.colorScheme.error)
                  : null,
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(audit?.malicious == true ? '仍要安装' : '仍然安装'),
            ),
          ],
        ),
      ),
    );
    return ok == true;
  }

  Future<void> _install(
      PluginHTTPItem item, PluginCatalogItemStatus status) async {
    if (!_installing.add(item.name)) return;
    setState(() {});
    try {
      if (!await _confirmRiskyInstall(item)) return;
      await updatePluginWithFeedback(_controller, item.name,
          installing: status == PluginCatalogItemStatus.install);
    } finally {
      if (mounted) setState(() => _installing.remove(item.name));
    }
  }

  List<PluginHTTPItem> _visibleItems() {
    final query = _search.text.trim().toLowerCase();
    final items = _controller.pluginHTTPList.where((item) {
      final status = _controller.pluginStatus(item);
      return (item.name.toLowerCase().contains(query) ||
              item.author.toLowerCase().contains(query)) &&
          switch (_filter) {
            _CatalogFilter.all => true,
            _CatalogFilter.installed =>
              status != PluginCatalogItemStatus.install,
            _CatalogFilter.updates => status == PluginCatalogItemStatus.update,
          };
    }).toList();
    switch (_sort) {
      case _CatalogSort.lastUpdate:
        items.sort((a, b) => b.lastUpdate.compareTo(a.lastUpdate));
      case _CatalogSort.name:
        items.sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }
    return items;
  }

  Widget _sortButton() => KazumiMenuButton(
        builder: (context, toggle) => TextButton.icon(
          onPressed: toggle,
          icon: const Icon(Icons.sort_rounded, size: 20),
          label: Text(_sort == _CatalogSort.name ? '名称排序' : '最近更新'),
        ),
        menuChildren: [
          for (final sort in _CatalogSort.values)
            KazumiMenuItem(
              selected: _sort == sort,
              onPressed: () => setState(() => _sort = sort),
              label: sort == _CatalogSort.name ? '按名称排序' : '按更新时间排序',
            ),
        ],
      );

  Widget _header(int total, int installed, int updates) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!widget._onboarding) ...[
        const RulePageIntro(
          title: '发现更多来源',
          description: '浏览社区规则，为你的番剧搜索添加更多选择。',
          icon: Icons.travel_explore_rounded,
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _search,
          onChanged: (_) => setState(() {}),
          decoration: ruleInputDecoration(context,
              hint: '搜索规则或作者',
              prefix: const Icon(Icons.search_rounded),
              suffix: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除搜索',
                      onPressed: () => setState(_search.clear),
                      icon: const Icon(Icons.close_rounded))),
        ),
        const SizedBox(height: 12),
        if (_repos.isNotEmpty) ...[
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              FilterChip(
                  label: const Text('官方仓库'),
                  selected: _selectedRepoBase == null,
                  onSelected: (_) => _switchRepo(null)),
              for (final repo in _repos)
                FilterChip(
                    label: Text(repo.name),
                    selected: _selectedRepoBase == repo.base,
                    onSelected: (_) => _switchRepo(repo)),
            ],
          ),
          const SizedBox(height: 8),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final entry in [
              (_CatalogFilter.all, '全部 $total'),
              (_CatalogFilter.installed, '已安装 $installed'),
              (_CatalogFilter.updates, '可更新 $updates'),
            ])
              FilterChip(
                  label: Text(entry.$2),
                  selected: _filter == entry.$1,
                  onSelected: (_) => setState(() => _filter = entry.$1)),
          ],
        ),
      ],
      Row(children: [
        if (widget._onboarding)
          Expanded(
            child: Text('规则仓库 · 已安装 $installed',
                style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600)),
          )
        else ...[
          _sortButton(),
          const Spacer(),
        ],
        IconButton.filledTonal(
            tooltip: '刷新规则列表',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded)),
      ]),
      if (_loading && total > 0)
        const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator()),
      if (_loadFailed && total > 0)
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('刷新失败，正在显示上次获取的规则。', style: theme.textTheme.bodySmall)),
      const SizedBox(height: 8),
    ]);
  }

  Widget _emptyBody() {
    if (_loading) {
      return const Padding(
          padding: EdgeInsets.all(48),
          child: Center(child: LoadingIndicator()));
    }
    if (_loadFailed && _controller.pluginHTTPList.isEmpty) {
      final enabled = GStorage.getSetting(SettingsKeys.enableGitProxy);
      return GeneralErrorWidget(
        title: '无法访问规则仓库',
        errMsg: '请检查网络连接，或切换规则仓库镜像后重试。',
        icon: Icons.cloud_off_rounded,
        onRetry: _refresh,
        retryText: '重新加载',
        actions: [
          StateActionButton.tonal(
            onPressed: _toggleGitProxyAndRefresh,
            icon: Icons.tune_rounded,
            text: enabled ? '关闭规则镜像' : '启用规则镜像',
          ),
        ],
      );
    }
    return GeneralEmptyState(
      title: _controller.pluginHTTPList.isEmpty ? '仓库暂无规则' : '没有符合条件的规则',
      icon: _controller.pluginHTTPList.isEmpty
          ? Icons.extension_rounded
          : Icons.search_off_rounded,
    );
  }

  @override
  Widget build(BuildContext context) => Observer(builder: (context) {
        final colors = Theme.of(context).colorScheme;
        final catalog = _controller.pluginHTTPList.toList();
        final installed = catalog
            .where((p) =>
                _controller.pluginStatus(p) != PluginCatalogItemStatus.install)
            .length;
        final updates = catalog
            .where((p) =>
                _controller.pluginStatus(p) == PluginCatalogItemStatus.update)
            .length;
        final items = _visibleItems();
        final slivers = <Widget>[
          SliverPadding(
            padding: widget._onboarding
                ? EdgeInsets.zero
                : const EdgeInsets.fromLTRB(16, 12, 16, 24),
            sliver: SliverMainAxisGroup(slivers: [
              SliverToBoxAdapter(
                  child: _header(catalog.length, installed, updates)),
              if (items.isEmpty)
                SliverToBoxAdapter(child: _emptyBody())
              else
                SliverList.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final status = _controller.pluginStatus(item);
                    final busy = _installing.contains(item.name);
                    return RuleCard(
                      key: ValueKey(item.name),
                      title: item.name,
                      installed: status == PluginCatalogItemStatus.installed,
                      subtitle:
                          item.author.isEmpty ? null : '作者 · ${item.author}',
                      tags: [
                        RuleTag(
                            label: item.version,
                            background: colors.surfaceContainerHighest,
                            foreground: colors.onSurfaceVariant),
                        if (item.antiCrawlerEnabled)
                          RuleTag(
                              label: '含验证支持',
                              background: colors.tertiaryContainer,
                              foreground: colors.onTertiaryContainer),
                      ],
                      caption: item.lastUpdate > 0
                          ? '更新于 ${DateTime.fromMillisecondsSinceEpoch(item.lastUpdate).toString().split(' ').first}'
                          : null,
                      trailing: _CatalogRuleAction(
                        status: status,
                        busy: busy,
                        onPressed: () => _install(item, status),
                      ),
                    );
                  },
                ),
            ]),
          ),
        ];
        return widget._scrollViewBuilder?.call(context, slivers) ??
            CustomScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: slivers,
            );
      });
}

class _CatalogRuleAction extends StatelessWidget {
  const _CatalogRuleAction({
    required this.status,
    required this.busy,
    required this.onPressed,
  });

  final PluginCatalogItemStatus status;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (!busy && status == PluginCatalogItemStatus.installed) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.check_rounded, size: 18, color: colors.onSurfaceVariant),
          const SizedBox(width: 6),
          Text('已安装',
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(color: colors.onSurfaceVariant)),
        ]),
      );
    }
    final installing = status == PluginCatalogItemStatus.install;
    return FilledButton.tonal(
      style: FilledButton.styleFrom(
        minimumSize: const Size(108, 48),
        padding: const EdgeInsets.symmetric(horizontal: 16),
      ),
      onPressed: busy ? null : onPressed,
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (busy)
          const LoadingIndicator(size: 20)
        else
          Icon(installing ? Icons.add_rounded : Icons.sync_rounded, size: 18),
        const SizedBox(width: 6),
        Text(installing ? (busy ? '安装中' : '安装') : (busy ? '更新中' : '更新')),
      ]),
    );
  }
}
