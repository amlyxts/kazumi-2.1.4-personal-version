// [my修改] 源直连搜索: 绕过 Bangumi 直接检索规则源 (R18 场景, Bangumi 搜索
// 被官方过滤无入口)。链路: 规则搜索 (FlareSolverr 自动过盾) → 取集 → 播放,
// 历史记录使用伪 bangumi 条目 (md5 稳定 id, 与本地视频同构)。
// 可选: 带 Bangumi 令牌时并行检索里番条目 (filter nsfw=true), 标题匹配者
// 展示评分与 bgm.tv 跳转。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/device.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:url_launcher/url_launcher.dart';

class DirectSearchPage extends StatefulWidget {
  const DirectSearchPage({super.key});

  @override
  State<DirectSearchPage> createState() => _DirectSearchPageState();
}

class _DirectSearchPageState extends State<DirectSearchPage>
    with KazumiDialogOwner {
  final PluginsController _pluginsController = inject<PluginsController>();

  Plugin? _selectedPlugin;
  final TextEditingController _keywordController = TextEditingController();
  bool _searching = false;
  String? _searchError;
  List<SearchItem> _results = [];
  final Map<String, _BangumiRef> _bangumiRefs = {};
  bool _bangumiQuerying = false;

  @override
  void initState() {
    super.initState();
    final plugins = _pluginsController.pluginList;
    if (plugins.isNotEmpty) _selectedPlugin = plugins.first;
  }

  @override
  void dispose() {
    _keywordController.dispose();
    super.dispose();
  }

  /// 归一化标题 (匹配用): 去空白/常见符号, 小写
  static String _normalizeTitle(String s) => s
      .replaceAll(
          RegExp(r'[\s　·・~\-–—「」『』【】\[\]()（）]+'),
          '')
      .toLowerCase();

  static int _stableDirectId(String source) {
    final hex = crypto.md5
        .convert(utf8.encode('direct_search/$source'))
        .toString();
    return int.parse(hex.substring(0, 7), radix: 16);
  }

  BangumiItem _fabricatedItem(SearchItem item, Plugin plugin) {
    final name = item.name.trim();
    return BangumiItem(
      id: _stableDirectId('${plugin.name}_${item.src}'),
      type: 2,
      name: name,
      nameCn: name,
      summary: '',
      airDate: '',
      airWeekday: 0,
      rank: 0,
      images: const {},
      tags: [],
      alias: [],
      ratingScore: 0.0,
      votes: 0,
      votesCount: [],
      info: '',
    );
  }

  Future<void> _search() async {
    final keyword = _keywordController.text.trim();
    final plugin = _selectedPlugin;
    if (keyword.isEmpty || plugin == null || _searching) return;
    setState(() {
      _searching = true;
      _searchError = null;
      _results = [];
      _bangumiRefs.clear();
    });
    try {
      final response = await plugin.queryBangumi(keyword, shouldRethrow: true);
      if (!mounted) return;
      setState(() => _results = response.data);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _searchError = error.toString();
        _results = [];
      });
    } finally {
      if (mounted) setState(() => _searching = false);
    }
    await _queryBangumiRefs(keyword);
  }

  /// 带 Bangumi 令牌的里番条目检索 (filter nsfw=true), 按归一化标题匹配源结果
  Future<void> _queryBangumiRefs(String keyword) async {
    final token = GStorage.getSetting(SettingsKeys.bangumiAccessToken).trim();
    if (token.isEmpty) return;
    setState(() => _bangumiQuerying = true);
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: Duration(seconds: 15),
        receiveTimeout: Duration(seconds: 20),
        validateStatus: (_) => true,
      ));
      dio.options.headers = {
        'user-agent': 'liuxuan/kazumi-personal (direct search ratings)',
        'authorization': 'Bearer $token',
      };
      final resp = await dio.post(
        'https://api.bgm.tv/v0/search/subjects',
        data: {'keyword': keyword, 'limit': 50, 'filter': {'nsfw': true}},
      );
      final data = resp.data['data'] as List? ?? [];
      if (!mounted) return;
      setState(() {
        for (final subject in data) {
          final name = (subject['name'] ?? '').toString();
          final rating = subject['rating'] ?? {};
          _bangumiRefs[_normalizeTitle(name)] = _BangumiRef(
            subjectId: (subject['id'] ?? 0).toString(),
            score: (rating['score'] as num?)?.toDouble() ?? 0,
            votes: (rating['total'] ?? 0).toString(),
          );
        }
        _bangumiQuerying = false;
      });
    } catch (e) {
      KazumiLogger().i('DirectSearch: bangumi nsfw query failed: $e');
      if (mounted) setState(() => _bangumiQuerying = false);
    }
  }

  _BangumiRef? _refFor(SearchItem item) {
    final key = _normalizeTitle(item.name);
    if (_bangumiRefs.containsKey(key)) return _bangumiRefs[key];
    for (final e in _bangumiRefs.entries) {
      if (e.key.isEmpty) continue;
      if (key.contains(e.key) || e.key.contains(key)) return e.value;
    }
    return null;
  }

  Future<void> _play(SearchItem item) async {
    final plugin = _selectedPlugin;
    if (plugin == null || dialogs.isRunning) return;
    final fabricated = _fabricatedItem(item, plugin);
    await dialogs.run((task) async {
      final roads = await task.loading(
        message: '正在获取播放列表',
        barrierDismissible: isDesktop(),
        action: () => plugin.queryChapterRoads(item.src),
      );
      if (roads.isEmpty) {
        throw Exception('未获取到播放线路');
      }
      if (mounted) {
        task.withContext((context) => context.pushNamed(
              '/video/',
              arguments: OnlineVideoPlaybackArgs(
                bangumiItem: fabricated,
                plugin: plugin,
                title: item.name,
                src: item.src,
                roads: roads,
              ),
            ));
      }
    }, onError: (error, stackTrace) {
      KazumiLogger().w('DirectSearch: play failed', error: error);
      KazumiDialog.showToast(message: '获取播放列表失败，请重试');
    });
  }

  Future<void> _openBgmSubject(String subjectId) async {
    final url = Uri.parse('https://bgm.tv/subject/$subjectId');
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      KazumiDialog.showToast(message: '无法打开浏览器');
    }
  }

  @override
  Widget build(BuildContext context) {
    final plugins = _pluginsController.pluginList;
    return SettingsDetailScaffold(
      title: const Text('源直连搜索'),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: DropdownButton<Plugin>(
                    isExpanded: true,
                    value: _selectedPlugin,
                    items: [
                      for (final p in plugins)
                        DropdownMenuItem(value: p, child: Text(p.name)),
                    ],
                    onChanged: (p) => setState(() => _selectedPlugin = p),
                    hint: const Text('选择规则源'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _keywordController,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration:
                        const InputDecoration(hintText: '站内搜索关键词'),
                  ),
                ),
                IconButton(
                  onPressed: _searching ? null : _search,
                  icon: const Icon(Icons.search),
                ),
              ],
            ),
          ),
          if (_bangumiQuerying)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('正在匹配 Bangumi 评分…',
                    style: TextStyle(fontSize: 12)),
              ),
            ),
          if (_searchError != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_searchError!,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          Expanded(
            child: _searching
                ? const Center(child: CircularProgressIndicator())
                : _results.isEmpty
                    ? Center(
                        child: Text(_searchError == null
                            ? '输入关键词搜索'
                            : '无结果 (过盾失败时请重试一次)'))
                    : ListView.builder(
                        itemCount: _results.length,
                        itemBuilder: (context, index) {
                          final item = _results[index];
                          final ref = _bangumiQuerying ? null : _refFor(item);
                          return ListTile(
                            title: Text(item.name),
                            subtitle: ref != null
                                ? Text(
                                    'bgm ★${ref.score.toStringAsFixed(1)} (${ref.votes}人)',
                                    style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary),
                                  )
                                : null,
                            trailing: ref != null
                                ? IconButton(
                                    icon: const Icon(Icons.open_in_new),
                                    tooltip: '在 bgm.tv 打开 (评分/评论)',
                                    onPressed: () =>
                                        _openBgmSubject(ref.subjectId),
                                  )
                                : null,
                            onTap: () => _play(item),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class _BangumiRef {
  _BangumiRef({
    required this.subjectId,
    required this.score,
    required this.votes,
  });
  final String subjectId;
  final double score;
  final String votes;
}
