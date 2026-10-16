// [my修改] 自定义规则仓库管理器: 多仓库增删改, JSON 存本地设置
// 仓库约定: {url}index.json 目录 + {url}<规则名>.json 规则体
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:kazumi/request/apis/plugin_catalog_api.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 弹出仓库管理器。返回 true 表示有修改并已保存。
Future<bool> showRuleRepoManager(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => const _RuleRepoManagerDialog(),
  );
  return result == true;
}

class _RuleRepoManagerDialog extends StatefulWidget {
  const _RuleRepoManagerDialog();

  @override
  State<_RuleRepoManagerDialog> createState() => _RuleRepoManagerDialogState();
}

class _RuleRepoManagerDialogState extends State<_RuleRepoManagerDialog> {
  late List<RuleRepo> _repos;

  @override
  void initState() {
    super.initState();
    _repos = PluginCatalogApi.listRepos();
  }

  void _saveAndPop() {
    GStorage.putSetting(SettingsKeys.customRuleRepos,
        jsonEncode([for (final r in _repos) r.toJson()]));
    Navigator.of(context).pop(true);
  }

  Future<void> _editRepo(int index) async {
    final edited = await showDialog<RuleRepo>(
      context: context,
      builder: (_) =>
          _RuleRepoEditorDialog(initial: index >= 0 ? _repos[index] : null),
    );
    if (edited == null) return;
    setState(() {
      if (index >= 0) {
        _repos[index] = edited;
      } else {
        _repos.add(edited);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      scrollable: true,
      title: const Text('自定义规则仓库'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '仓库需含 index.json 目录与 <规则名>.json 规则体；'
              '在插件市场顶部切换查看，同名规则以所选仓库为准',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            if (_repos.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('尚未添加自定义仓库',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
            for (var i = 0; i < _repos.length; i++)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  dense: true,
                  title: Text(_repos[i].name),
                  subtitle: Text(_repos[i].url,
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.edit_outlined, size: 20),
                        onPressed: () => _editRepo(i),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.delete_outline_rounded,
                            size: 20),
                        onPressed: () => setState(() => _repos.removeAt(i)),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 4),
            OutlinedButton.icon(
              onPressed: () => _editRepo(-1),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('添加仓库'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saveAndPop,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

class _RuleRepoEditorDialog extends StatefulWidget {
  const _RuleRepoEditorDialog({this.initial});

  final RuleRepo? initial;

  @override
  State<_RuleRepoEditorDialog> createState() => _RuleRepoEditorDialogState();
}

class _RuleRepoEditorDialogState extends State<_RuleRepoEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initial?.name ?? '');
    _url = TextEditingController(text: widget.initial?.url ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final url = _url.text.trim();
    if (name.isEmpty || url.isEmpty) {
      setState(() => _error = '名称与地址不能为空');
      return;
    }
    final repo = RuleRepo(name: name, url: url);
    if (!repo.valid) {
      setState(() => _error = '地址格式无效 (需 http/https)');
      return;
    }
    Navigator.of(context).pop(repo);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: Text(widget.initial == null ? '添加仓库' : '编辑仓库'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                  labelText: '显示名称 (插件市场切换按钮文字)',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                  labelText: '仓库 base 地址',
                  hintText:
                      'https://raw.githubusercontent.com/<user>/<repo>/main/',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            Text(
              'raw.githubusercontent 源可套 gh-proxy 前缀加速',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('确定'),
        ),
      ],
    );
  }
}
