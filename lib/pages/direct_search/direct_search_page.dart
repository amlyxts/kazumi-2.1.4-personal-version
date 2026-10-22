// [my修改] 源直连浏览与搜索: 绕过 Bangumi 直接使用规则源 (R18 场景,
// Bangumi 搜索被官方过滤无入口)。
// 浏览: 源站目录页 + 分区 chips + 標籤多选 + 封面墙 + 翻页 (FlareSolverr
// 过盾取页, 凭证播种后走 dio 快速通道; 站点轮换视频 CDN 域名, 解析按播放器
// 元素定位)。
// 播放: 取集 → 伪 bangumi 条目 (md5 稳定 id, 与本地视频模式同构)。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/dialog/dialog_task.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/modules/bangumi/bangumi_collection_type.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/flaresolverr/flaresolverr_service.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/device.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:html/parser.dart' as html_parser;
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';
import 'package:url_launcher/url_launcher.dart';

class _BrowseCard {
  _BrowseCard({required this.title, required this.href, required this.thumb});
  final String title;
  final String href;
  final String thumb;
}

class _ListPage {
  _ListPage({required this.cards, required this.currentPage, this.nextPage});
  final List<_BrowseCard> cards;
  final int currentPage;
  final int? nextPage;
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

class DirectSearchPage extends StatefulWidget {
  const DirectSearchPage({super.key});

  @override
  State<DirectSearchPage> createState() => _DirectSearchPageState();
}

class _DirectSearchPageState extends State<DirectSearchPage>
    with KazumiDialogOwner {
  final PluginsController _pluginsController = inject<PluginsController>();
  final CollectController _collectController = inject<CollectController>();

  /// 已收藏条目 (按条目 id), 控制卡片收藏星标状态
  final Set<int> _collectedIds = {};

  /// 浏览目标站点首页 (卡片结构解析基准), 站名在设置里配置不写入代码。
  String get _siteBase {
    final v = GStorage.getSetting(SettingsKeys.directSearchSite).trim();
    return v.isEmpty ? '' : v.replaceAll(RegExp(r'/+$'), '') + '/';
  }

  /// 浏览/标签/卡片解析是站点结构专用的, 下拉只列出与浏览站点同域的规则源
  List<Plugin> _usableSources() {
    final siteHost = Uri.tryParse(_siteBase)?.host ?? '';
    if (siteHost.isEmpty) return const [];
    return _pluginsController.pluginList
        .where((p) => (Uri.tryParse(p.baseUrl)?.host ?? '') == siteHost)
        .toList();
  }

  static const List<String> _genres = [
    '裏番',
    '泡麵番',
    'Motion Anime',
    '3DCG',
    '2D動畫',
    'AI生成',
    'MMD',
    'Cosplay',
    '新番預告',
  ];

  Plugin? _selectedPlugin;
  final TextEditingController _keywordController = TextEditingController();
  String _genre = '最新'; // '最新' = 全站目录页
  final Set<String> _activeTags = {};
  int _page = 1;
  int? _nextPage;
  List<_BrowseCard> _cards = [];
  bool _loading = false;
  String? _error;

  // FlareSolverr 播种状态 (过盾一次后, 页面翻页走 dio 快速通道)
  String? _fsCookies;
  String? _fsUA;

  // 站点标签表 (从搜索/浏览页的 #tags 模态框提取, 动态更新)
  List<String> _siteTags = [];

  // 会话级记忆 (tab 切换/页面重建后保持选择)
  static Plugin? _rememberedPlugin;
  static String _rememberedGenre = '最新';
  static final Set<String> _rememberedTags = {};

  // Bangumi 里番评分匹配 (搜索关键词模式)
  final Map<String, _BangumiRef> _bangumiRefs = {};
  bool _bangumiQuerying = false;

  @override
  void initState() {
    super.initState();
    final usable = _usableSources();
    if (usable.isNotEmpty) {
      // 恢复会话记忆的源选择 (仍在可用列表中才恢复)
      _selectedPlugin = _rememberedPlugin != null &&
              usable.contains(_rememberedPlugin)
          ? _rememberedPlugin
          : usable.first;
    }
    _genre = _rememberedGenre;
    _activeTags.addAll(_rememberedTags);
    _collectController.loadCollectibles();
    _collectedIds.addAll(
        _collectController.collectibles.map((c) => c.bangumiItem.id));
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _loadList(reset: true));
  }

  /// 归一化标题 (匹配用)
  static String _normalizeTitle(String s) => s
      .replaceAll(RegExp(r'[\s　·・~\-–—「」『』【】\[\]()（）]+'), '')
      .toLowerCase();

  static int _stableDirectId(String source) {
    final hex = crypto.md5
        .convert(utf8.encode('direct_search/$source'))
        .toString();
    return int.parse(hex.substring(0, 7), radix: 16);
  }

  /// 卡片的条目 id: 匹配 bgm 条目时使用真实条目 id (收藏/Bangumi 同步走
  /// 真实条目), 未匹配时用稳定哈希 id (本地条目)。
  int _itemIdFor(_BrowseCard card) {
    final ref = _refFor(card);
    final pluginName = _selectedPlugin?.name ?? 'direct';
    if (ref != null) {
      final realId = int.tryParse(ref.subjectId);
      if (realId != null) return realId;
    }
    return _stableDirectId('${pluginName}_${card.href}');
  }

  BangumiItem _fabricatedItem(_BrowseCard card) {
    final name = card.title.trim();
    final id = _itemIdFor(card);
    final ref = _refFor(card);
    return BangumiItem(
      id: id,
      type: 2,
      name: name,
      nameCn: name,
      summary: '',
      airDate: '',
      airWeekday: 0,
      rank: 0,
      images: {
        if (card.thumb.isNotEmpty) 'large': card.thumb,
      },
      tags: [],
      alias: [],
      ratingScore: ref?.score ?? 0.0,
      votes: 0,
      votesCount: [],
      info: '',
    );
  }

  // ====== 列表抓取 (dio 快速通道优先, 挑战时 FlareSolverr 过盾) ======

  Dio _browseDio() {
    final dio = Dio(BaseOptions(
      connectTimeout: Duration(seconds: 15),
      receiveTimeout: Duration(seconds: 25),
      validateStatus: (_) => true,
    ));
    dio.options.headers = {
      if (_fsUA != null) 'user-agent': _fsUA!,
      if (_fsCookies != null) 'cookie': _fsCookies!,
    };
    return dio;
  }

  Future<_ListPage?> _fetchViaDio(String url) async {
    if (_fsCookies == null) return null;
    try {
      final resp = await _browseDio().get(url);
      if (resp.statusCode != 200) return null;
      final body = resp.data.toString();
      if (body.contains('challenge-platform') &&
          !body.contains('video-item-container')) {
        return null; // 又被挑战了
      }
      return _parseCards(body);
    } catch (_) {
      return null;
    }
  }

  /// 从 HTML 提取站点标签表 (#tags 模态框的 tags[] 复选框值)
  List<String> _parseTags(String html) {
    try {
      return RegExp(r'name="tags\[\]"[^>]*value="([^"]+)"')
          .allMatches(html)
          .map((m) => m.group(1)!)
          .where((v) => v.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<_ListPage?> _fetchViaFlareSolverr(String url) async {
    final solution = await FlareSolverrService.solve(url);
    if (solution == null) return null;
    _fsCookies = solution.cookieString;
    _fsUA = solution.userAgent;
    if (_siteTags.isEmpty) {
      final tags = _parseTags(solution.html);
      if (tags.isNotEmpty && mounted) setState(() => _siteTags = tags);
    }
    return _parseCards(solution.html);
  }

  Future<_ListPage?> _fetchList(String url) async {
    final viaDio = await _fetchViaDio(url);
    if (viaDio != null && viaDio.cards.isNotEmpty) return viaDio;
    return _fetchViaFlareSolverr(url);
  }

  /// 解析卡片列表与翻页。兼容两种卡片结构: 搜索页 (a.video-link +
  /// div.title + img.main-thumb) 与分区页 (裸锚点 + home-rows-videos-title
  /// + img cover)。锚点按 href 识别 (两类通吃), 赞助卡无 watch 锚点天然排除。
  _ListPage? _parseCards(String html) {
    try {
      final root = html_parser.parse(html).documentElement!;
      final cards = <_BrowseCard>[];
      final anchors = root.queryXPath('//a[contains(@href,"watch?v=")]');
      for (final node in anchors.nodes) {
        final href = node.attributes['href'] ?? '';
        if (!href.contains('watch?v=')) continue;
        final titleNode =
            node.queryXPath('.//div[contains(@class,"title")] | .//div[contains(@class,"videos-title")] | .//h4').node;
        final title = (titleNode?.text ?? '').trim();
        final thumbNode =
            node.queryXPath('.//img').node;
        cards.add(_BrowseCard(
          title: title,
          href: href,
          thumb: thumbNode?.attributes['src'] ?? '',
        ));
      }
      if (cards.isEmpty) return null;
      int? next;
      final pageLinks = RegExp(r'[?&]page=(\d+)')
          .allMatches(html)
          .map((m) => int.tryParse(m.group(1)!) ?? 0)
          .toList();
      if (pageLinks.isNotEmpty) next = pageLinks.reduce((a, b) => a > b ? a : b);
      final current = RegExp(r'[?&]page=(\d+)').firstMatch(_lastFetchedUrl);
      final cur = current != null ? int.tryParse(current.group(1)!) ?? 1 : 1;
      return _ListPage(cards: cards, currentPage: cur, nextPage: next);
    } catch (e) {
      KazumiLogger().w('DirectSearch: parse cards failed: $e');
      return null;
    }
  }

  String _lastFetchedUrl = '';

  /// 构建当前列表 URL: 分区与标签可同时生效 (站点原生支持组合参数)
  String _listUrlFor() {
    final params = <String>[];
    if (_activeTags.isNotEmpty) {
      params.addAll(_activeTags
          .map((t) => 'tags%5B%5D=${Uri.encodeComponent(t)}'));
    }
    if (_genre != '最新') {
      params.add('genre=${Uri.encodeComponent(_genre)}');
    }
    if (params.isEmpty) return '$_siteBase/search';
    return '$_siteBase/search?${params.join('&')}';
  }

  Future<void> _loadList({required bool reset, int page = 1}) async {
    if (_siteBase.isEmpty) {
      setState(() => _error = '未配置浏览站点: 网络设置 → 源直连浏览站点');
      return;
    }
    if (_loading) return;
    var url = _listUrlFor();
    if (page > 1) url += '&page=$page';
    _lastFetchedUrl = url;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) _cards = [];
    });
    final listPage = await _fetchList(url);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (listPage == null) {
        _error = '加载失败 (过盾失败或站点不可达), 请重试';
        if (reset) _cards = [];
      } else {
        _cards = listPage.cards;
        _nextPage = listPage.nextPage;
        _page = page;
      }
    });
  }

  Future<void> _nextPageLoad() => _loadList(reset: false, page: _page + 1);
  Future<void> _prevPageLoad() =>
      _page > 1 ? _loadList(reset: false, page: _page - 1) : Future.value();

  // ====== 搜索模式 (站内关键词, 走同一卡片解析) ======

  Future<void> _search() async {
    final keyword = _keywordController.text.trim();
    if (keyword.isEmpty || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
      _bangumiRefs.clear();
    });
    final url =
        '$_siteBase/search?query=${Uri.encodeComponent(keyword)}';
    final listPage = await _fetchList(url);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _cards = listPage?.cards ?? [];
      if (listPage == null) {
        _error = '加载失败 (过盾失败或站点不可达), 请重试';
      }
    });
    if (listPage != null && listPage.cards.isNotEmpty) {
      await _queryBangumiRefs(keyword);
    }
  }

  /// 带 Bangumi 令牌的里番条目检索 (filter nsfw=true), 按归一化标题匹配
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
        'user-agent': 'kazumi-direct-search/1.0 (bgm rating match)',
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

  _BangumiRef? _refFor(_BrowseCard card) {
    final key = _normalizeTitle(card.title);
    if (_bangumiRefs.containsKey(key)) return _bangumiRefs[key];
    for (final e in _bangumiRefs.entries) {
      if (e.key.isEmpty) continue;
      if (key.contains(e.key) || e.key.contains(key)) return e.value;
    }
    return null;
  }

  Future<void> _openBgmSubject(String subjectId) async {
    final url = Uri.parse('https://bgm.tv/subject/$subjectId');
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (e) {
      KazumiDialog.showToast(message: '无法打开浏览器');
    }
  }

  // ====== 收藏切换 (本地收藏 + Bangumi 同步按全局开关走) ======

  /// 星标点击 → 分类选择弹窗 (用户自主判断分类; 已收藏可选取消收藏)
  Future<void> _showCollectTypePicker(_BrowseCard card) async {
    final item = _fabricatedItem(card);
    final wasCollected = _collectedIds.contains(item.id);
    int? selectedType = wasCollected ? 2 : null; // 预选: 已收藏默认看过
    await KazumiDialog.show(
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          Widget typeOption(BangumiCollectionType t) => RadioListTile<int>(
                value: t.value,
                groupValue: selectedType,
                title: Text(t.label),
                dense: true,
                onChanged: (v) => setDialogState(() => selectedType = v),
              );
          return AlertDialog(
            title: Text(card.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final t in [
                  BangumiCollectionType.planToWatch,
                  BangumiCollectionType.watched,
                  BangumiCollectionType.watching,
                  BangumiCollectionType.onHold,
                  BangumiCollectionType.abandoned,
                ])
                  typeOption(t),
                if (wasCollected)
                  ListTile(
                    leading: const Icon(Icons.close),
                    title: const Text('取消收藏'),
                    dense: true,
                    onTap: () => setDialogState(() => selectedType = 0),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: KazumiDialog.dismiss,
                child: Text('取消',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.outline)),
              ),
              TextButton(
                onPressed: () {
                  final type = selectedType;
                  if (type == null || type <= 0) return;
                  final ref = _refFor(card);
                  if (ref != null) {
                    // 匹配 bgm 条目: 走同步路径 (真实条目 id)
                    _collectController.addCollect(item, type: type);
                  } else {
                    // 无匹配: 仅本地收藏 (哈希 id, 同步无意义)
                    _collectController
                        .addCollectLocalOnly(item, type: type);
                  }
                  if (selectedType == 0) {
                    _collectedIds.remove(item.id);
                  } else {
                    _collectedIds.add(item.id);
                  }
                  KazumiDialog.dismiss();
                },
                child: const Text('确定'),
              ),
            ],
          );
        },
      ),
    );
  }

  // ====== 播放 (卡片 → 取集 → 播放页) ======

  Future<void> _play(_BrowseCard card) async {
    final plugin = _selectedPlugin;
    if (plugin == null || dialogs.isRunning) return;
    final fabricated = _fabricatedItem(card);
    await dialogs.run((task) async {
      final roads = await task.loading(
        message: '正在获取播放列表',
        barrierDismissible: isDesktop(),
        action: () => plugin.queryChapterRoads(card.href),
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
                title: card.title,
                src: card.href,
                roads: roads,
              ),
            ));
      }
    }, onError: (error, stackTrace) {
      KazumiLogger().w('DirectSearch: play failed', error: error);
      KazumiDialog.showToast(message: '获取播放列表失败，请重试');
    });
  }

  // ====== 标签多选弹窗 ======

  Future<void> _showTagPicker() async {
    final selected = Set<String>.from(_activeTags);
    final filterController = TextEditingController();
    var visible = List<String>.from(_siteTags)..sort();
    await KazumiDialog.show(
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          void applyFilter(String v) {
            setDialogState(() {
              visible = _siteTags
                  .where((t) => v.trim().isEmpty || t.contains(v.trim()))
                  .toList()
                ..sort();
            });
          }

          return AlertDialog(
            title: const Text('選擇標籤'),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: filterController,
                    decoration: const InputDecoration(hintText: '篩選標籤…'),
                    onChanged: applyFilter,
                  ),
                  const SizedBox(height: 8),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 2,
                        children: [
                          for (final t in visible)
                            FilterChip(
                              label: Text(t,
                                  style: const TextStyle(fontSize: 12)),
                              selected: selected.contains(t),
                              onSelected: (_) => setDialogState(() =>
                                  selected.contains(t)
                                      ? selected.remove(t)
                                      : selected.add(t)),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  selected.clear();
                  KazumiDialog.dismiss();
                },
                child: Text('清除',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.outline)),
              ),
              TextButton(
                onPressed: KazumiDialog.dismiss,
                child: const Text('確定'),
              ),
            ],
          );
        },
      ),
    );
    if (!mounted) return;
    setState(() {
      _activeTags
        ..clear()
        ..addAll(selected);
    });
    await _loadList(reset: true);
  }

  // ====== UI ======

  @override
  Widget build(BuildContext context) {
    final plugins = _usableSources();
    return SettingsDetailScaffold(
      title: const Text('源直连浏览'),
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
                    onChanged: (p) {
                      setState(() {
                        _selectedPlugin = p;
                        _activeTags.clear();
                        _rememberedPlugin = p;
                        _rememberedTags.clear();
                      });
                      _loadList(reset: true);
                    },
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
                  onPressed: _loading ? null : _search,
                  icon: const Icon(Icons.search),
                ),
              ],
            ),
          ),
          // 分区 chips 行 (常显)
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final g in ['最新', ..._genres])
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(g),
                      selected: _genre == g,
                      onSelected: (_) {
                        setState(() {
                          _genre = g;
                          _rememberedGenre = g;
                        });
                        _loadList(reset: true);
                      },
                    ),
                  ),
              ],
            ),
          ),
          // 標籤 chips 行 (标签表提取后显示)
          if (_siteTags.isNotEmpty)
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ActionChip(
                      avatar: const Icon(Icons.sell_outlined, size: 16),
                      label:
                          const Text('標籤', style: TextStyle(fontSize: 12)),
                      onPressed: _showTagPicker,
                    ),
                  ),
                  for (final t in _activeTags)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: InputChip(
                        label: Text(t, style: const TextStyle(fontSize: 12)),
                        onDeleted: () {
                          setState(() => _activeTags.remove(t));
                          _loadList(reset: true);
                        },
                      ),
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
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_error != null)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                    const SizedBox(height: 8),
                    FilledButton.tonal(
                      onPressed: () => _loadList(reset: true),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            )
          else if (_cards.isEmpty)
            const Expanded(child: Center(child: Text('无内容')))
          else
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 220,
                  childAspectRatio: 0.62,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                ),
                itemCount: _cards.length,
                itemBuilder: (context, index) {
                  final card = _cards[index];
                  final ref = _refFor(card);
                  return InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () {
                      final r = _refFor(card);
                      if (r != null) {
                        _openBgmSubject(r.subjectId);
                      } else {
                        _play(card);
                      }
                    },
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: CachedNetworkImage(
                                    imageUrl: card.thumb,
                                    width: double.infinity,
                                    fit: BoxFit.cover,
                                    fadeInDuration:
                                        const Duration(milliseconds: 120),
                                    placeholder: (context, url) => Container(
                                      color: Theme.of(context).colorScheme
                                          .surfaceContainerHighest,
                                    ),
                                    errorWidget: (context, url, error) =>
                                        Container(
                                      color: Theme.of(context).colorScheme
                                          .surfaceContainerHighest,
                                      child: const Center(
                                          child: Icon(Icons.movie_outlined)),
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                right: 6,
                                bottom: 6,
                                child: IconButton(
                                  constraints: const BoxConstraints(),
                                  padding: const EdgeInsets.all(6),
                                  style: IconButton.styleFrom(
                                    backgroundColor: Theme.of(context)
                                        .colorScheme
                                        .primaryContainer,
                                  ),
                                  tooltip: '播放',
                                  icon: const Icon(Icons.play_arrow_rounded,
                                      size: 22),
                                  onPressed: () => _play(card),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        GestureDetector(
                          onTap: () => _showCollectTypePicker(card),
                          child: Icon(
                            _collectedIds.contains(_itemIdFor(card))
                                ? Icons.star
                                : Icons.star_border,
                            size: 18,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        Text(
                          card.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                        if (ref != null)
                          GestureDetector(
                            onTap: () => _openBgmSubject(ref.subjectId),
                            child: Text(
                              'bgm ★${ref.score.toStringAsFixed(1)} →',
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          if (!_loading && _cards.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    onPressed: _page > 1 ? _prevPageLoad : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text('第 $_page 页'),
                  IconButton(
                    onPressed: _nextPage != null ? _nextPageLoad : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
