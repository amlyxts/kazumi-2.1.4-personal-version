// [my修改] 源直连浏览与搜索: 绕过 Bangumi 直接使用规则源 (R18 场景,
// Bangumi 搜索被官方过滤无入口)。
// 浏览: 源站目录页 + 分区 chips + 標籤多选 + 封面墙 + 翻页 (FlareSolverr
// 过盾取页, 凭证播种后走 dio 快速通道; 站点轮换视频 CDN 域名, 解析按播放器
// 元素定位)。
// 播放: 取集 → 伪 bangumi 条目 (md5 稳定 id, 与本地视频模式同构)。
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/dialog/dialog_task.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/collect/collect_repair.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/pages/direct_search/series_detector.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'package:kazumi/services/flaresolverr/flaresolverr_service.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/device.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

class _BrowseCard {
  _BrowseCard({required this.title, required this.href, required this.thumb});
  final String title;
  final String href;
  final String thumb;

  Map<String, dynamic> toJson() =>
      {'title': title, 'href': href, 'thumb': thumb};

  static _BrowseCard fromJson(Map<String, dynamic> json) => _BrowseCard(
        title: (json['title'] ?? '').toString(),
        href: (json['href'] ?? '').toString(),
        thumb: (json['thumb'] ?? '').toString(),
      );
}

class _ListPage {
  _ListPage({
    required this.cards,
    required this.currentPage,
    this.nextPage,
    this.lastPage,
    this.cachedAt,
  });
  final List<_BrowseCard> cards;
  final int currentPage;
  final int? nextPage;

  /// [my新增] 站点翻页条里的末页码 — "第 N / M 页"显示与跳转范围
  final int? lastPage;

  /// [my新增] 落盘时间戳 (持久化缓存的新鲜度展示, SWR 刷新后更新)
  final int? cachedAt;

  Map<String, dynamic> toJson() => {
        'cards': [for (final c in cards) c.toJson()],
        'currentPage': currentPage,
        'nextPage': nextPage,
        'lastPage': lastPage,
        'cachedAt': cachedAt ?? DateTime.now().millisecondsSinceEpoch,
      };

  static _ListPage fromJson(Map<String, dynamic> json) => _ListPage(
        cards: [
          for (final c in (json['cards'] as List? ?? []))
            _BrowseCard.fromJson(Map<String, dynamic>.from(c)),
        ],
        currentPage: (json['currentPage'] as num?)?.toInt() ?? 1,
        nextPage: (json['nextPage'] as num?)?.toInt(),
        lastPage: (json['lastPage'] as num?)?.toInt(),
        cachedAt: (json['cachedAt'] as num?)?.toInt(),
      );
}

// [my移除 2026-10-31] bgm 自动匹配 (_BangumiRef/_queryBangumiRefs) 与手动
// 认领 (_showClaimSearch/directSearchClaims) 已下线, 代码备份:
// ../../../../直连Bangumi匹配与认领_备份_20261031.dart.txt

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

  /// [my新增] 已收藏的系列名集合 (里番区直连条目), 星标按作品匹配用 —
  /// 同系列其他集无需再逐集收藏
  final Set<String> _collectedSeriesNames = {};

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

  /// [my新增] 站点末页码 (跳转范围显示)
  int? _lastPage;
  List<_BrowseCard> _cards = [];
  bool _loading = false;
  String? _error;

  // FlareSolverr 播种状态 (过盾一次后, 页面翻页走 dio 快速通道)
  String? _fsCookies;
  String? _fsUA;

  // 站点标签分组 (从搜索/浏览页的 #tags 模态框提取, 动态更新)
  // 结构: {分组名: [标签…]} — 与源站 #tags 模态框的 h5 分组头对齐
  final Map<String, List<String>> _siteTagGroups = {};

  // 会话级记忆 (tab 切换/页面重建后保持选择)
  static Plugin? _rememberedPlugin;
  static String _rememberedGenre = '最新';
  static final Set<String> _rememberedTags = {};

  /// [my新增] 浏览位置记忆 (页码): 页签改按钮导航后切走会销毁重建,
  /// 静态字段是唯一跨重建存活的状态 — 回到源搜索时从上次页码继续。
  static int _rememberedPage = 1;

  /// [my新增] 搜索关键词 (静态跨重建存活, 与 _rememberedPage 配套):
  /// 非空 = 搜索模式, 列表 URL 与翻页统一带 query; 空串 = 普通浏览。
  /// 换分区/标签/源时清空退出搜索。
  static String _rememberedKeyword = '';

  /// [my新增] 站内搜索历史 (新在前, 上限 _historyMax): JSON 落设置框,
  /// 供输入框下拉回填; 只留本地不参与云同步, 与主搜索页 Bangumi 历史分开。
  static const int _historyMax = 20;
  List<String> _keywordHistory = [];
  final FocusNode _keywordFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // 种子: 上次过盾产物 (持久化)。命中则首屏直接走 dio 快速通道,
    // 不必先等 FlareSolverr 求解; cookies 失效时挑战检测会回退求解。
    final cachedCookies = GStorage.getSetting(SettingsKeys.flareSolverrCookies);
    if (cachedCookies.isNotEmpty) {
      _fsCookies = cachedCookies;
      _fsUA = GStorage.getSetting(SettingsKeys.flareSolverrUA);
    }
    final usable = _usableSources();
    if (usable.isNotEmpty) {
      // 恢复会话记忆的源选择 (仍在可用列表中才恢复)
      _selectedPlugin = _rememberedPlugin != null &&
              usable.contains(_rememberedPlugin)
          ? _rememberedPlugin
          : usable.first;
    }
    _restorePageCache();
    _genre = _rememberedGenre;
    _activeTags.addAll(_rememberedTags);
    _page = _rememberedPage;
    _loadKeywordHistory();
    _collectController.loadCollectibles();
    _refreshCollectedState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // [my修复] 初始加载带记忆页码 — 原先 initState 恢复 _page 后,
      // 这里仍按默认 page:1 加载并回写, 记忆等于白恢复
      final firstPage = _rememberedPage > 1 ? _rememberedPage : 1;
      final firstUrl = _listUrlForPage(firstPage);
      // [my提速] 预热未完成且目标页无缓存时, 先等预热 (免进页撞上
      // 冷启动求解); 有缓存时直接上屏, 预热在后台并行
      if (_pageCache[firstUrl] == null) {
        try {
          await FlareSolverrService.warmupFuture;
        } catch (_) {}
      }
      _loadList(reset: true, page: firstPage);
      // [my提速] 预取先行: 与当前页加载并行 (不等它完成), 预取相邻页
      // — 进页后用户第一次翻页大概率命中缓存 ([my调整] 经节流队列错峰)
      _enqueuePrefetch(firstUrl);
      _enqueuePrefetch(_listUrlForPage(firstPage + 1));
      if (firstPage > 1) _enqueuePrefetch(_listUrlForPage(firstPage - 1));
    });
  }

  @override
  void dispose() {
    _keywordFocusNode.dispose();
    super.dispose();
  }

  /// 归一化标题 (匹配用)
  static int _stableDirectId(String source) =>
      // [my修改] 委托 SeriesDetector 统一算法 (收藏/播放/打开三处同源)
      SeriesDetector.stableDirectId(source);

  /// 卡片的条目 id: 恒为稳定哈希 (本地条目)。[my移除 2026-10-31] 原"匹配
  /// bgm 用真实条目 id"分支随自动匹配/认领功能下线 (备份见文件头注释);
  /// 既有 real-id 收藏不受影响 (isDirectSourceItem 凭 info 判定)。
  int _itemIdFor(_BrowseCard card) {
    final pluginName = _selectedPlugin?.name ?? 'direct';
    return _stableDirectId('${pluginName}_${card.href}');
  }

  BangumiItem _fabricatedItem(_BrowseCard card) {
    // [my升级] 条目命名清洗 (方案一): 只剥带明确量词的集数标记
    // (第N话/前後編/PART/【N】等), 不动裸尾数字与标题本体的数字;
    // 系列/单集条目命名风格统一, 时间表/历史跟着干净
    final name = SeriesDetector.namingName(card.title);
    final id = _itemIdFor(card);
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
      ratingScore: 0.0,
      votes: 0,
      votesCount: [],
      // [my新增] 直连条目的播放地址随收藏落库 (WebDAV), 里番收藏页
      // 点击卡片时凭此直接恢复播放 — 无需 bgm 匹配
      info: card.href,
    );
  }

  // ====== 列表抓取 (系统 curl 快速通道优先; 挑战时 FlareSolverr 过盾) ======
  // [my修复] CF 按 TLS 指纹拦截 dart 网络栈: 同 cookies/UA/代理下 curl 200
  // 而 dart HttpClient 403 挑战页 (边缘 ~200ms 即拒), 故快速通道必须走
  // 系统 curl.exe (Schannel 指纹可过); curl 缺失时才落 dio, 挑战落过盾。

  /// 统一处理快速通道拿到的 HTML: 挑战检测 + 标签播种 + 卡片解析
  _ListPage? _consumeListBody(String body) {
    if (body.isEmpty) return null;
    if (body.contains('challenge-platform') &&
        !body.contains('video-item-container')) {
      return null; // 又被挑战了
    }
    if (_siteTagGroups.isEmpty) {
      final groups = _parseTagGroups(body);
      if (groups.isNotEmpty && mounted) {
        setState(() => _siteTagGroups..clear()..addAll(groups));
      }
    }
    return _parseCards(body);
  }

  String? get _curlExe {
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final exe = '$root\\System32\\curl.exe';
    return File(exe).existsSync() ? exe : null;
  }

  Future<_ListPage?> _fetchViaCurl(String url) async {
    if (_fsCookies == null) return null;
    final exe = _curlExe;
    if (exe == null) return null;
    try {
      // [my修复] 不带 --compressed: Win10 内置 curl 8.4.0 (Schannel) 不支持
      // 该参数, 直接 exit 2 空输出, 快速通道上线以来从未真正生效过。
      // [my优化] 参数拼装走 FlareSolverrService.buildCurlArgs 共享构造
      final sw = Stopwatch()..start();
      final r = await Process.run(
        exe,
        FlareSolverrService.buildCurlArgs(
          url: url,
          cookies: _fsCookies!,
          userAgent: _fsUA ?? '',
          extra: const ['--max-time', '20'],
        ),
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      final elapsed = sw.elapsedMilliseconds;
      final body = r.stdout.toString();
      final page = _consumeListBody(body);
      if (page != null) {
        if (elapsed > 1500) {
          KazumiLogger().w(
              'DirectSearch: curl fast path SLOW ${elapsed}ms, ${page.cards.length} cards');
        } else {
          KazumiLogger().i(
              'DirectSearch: curl fast path ok, ${page.cards.length} cards, ${elapsed}ms');
        }
      } else {
        KazumiLogger().w(
            'DirectSearch: curl fast path null | ${elapsed}ms exit=${r.exitCode} len=${body.length} challenge=${body.contains('challenge-platform')} stderr=${r.stderr.toString().trim()}');
      }
      return page;
    } catch (e) {
      KazumiLogger().w('DirectSearch: curl fast path error: $e');
      return null;
    }
  }

  Dio _browseDio() {
    final dio = Dio(BaseOptions(
      connectTimeout: Duration(seconds: 10),
      receiveTimeout: Duration(seconds: 25),
      validateStatus: (_) => true,
    ));
    // 白名单代理判定与全局 Dio 同源: 浏览站点直连不可达, 必须走代理,
    // 否则快速通道每次都耗尽超时再落到 FlareSolverr (页面加载十几秒的根源)。
    dio.httpClientAdapter = NetworkConfig.fromSettings(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 25),
    ).createAdapter();
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
      if (resp.statusCode != 200) {
        KazumiLogger().w(
            'DirectSearch: dio fast path status=${resp.statusCode} (403=CF 按 TLS 指纹拦 dart 栈, 属预期, 由 curl 通道接手)');
        return null;
      }
      return _consumeListBody(resp.data.toString());
    } catch (_) {
      return null;
    }
  }

  /// 从 HTML 提取标签分组 (#tags 模态框: h5 分组头 + tags[] 复选框值)
  Map<String, List<String>> _parseTagGroups(String html) {
    final result = <String, List<String>>{};
    final modalStart = html.indexOf('id="tags"');
    if (modalStart < 0) return result;
    final seg = html.substring(modalStart);
    // 按 <h5 分区分段: 每段 = h5 属性+分组头文本 + </h5> + 该组的复选框
    for (final part in seg.split('<h5').skip(1)) {
      final close = part.indexOf('</h5>');
      if (close < 0) continue;
      final headSeg = part.substring(0, close);
      final gt = headSeg.lastIndexOf('>');
      if (gt < 0) continue;
      final header = headSeg.substring(gt + 1).trim();
      if (header.isEmpty) continue;
      final zone = part.substring(close + 5);
      final values = RegExp(r'name="tags\[\]"[^>]*value="([^"]+)"')
          .allMatches(zone)
          .map((m) => m.group(1)!)
          .where((v) => v.isNotEmpty)
          .toList();
      if (values.isNotEmpty) {
        result.putIfAbsent(header, () => []).addAll(values);
      }
    }
    return result;
  }

  Future<_ListPage?> _fetchViaFlareSolverr(String url) async {
    final solution = await FlareSolverrService.solve(url);
    if (solution == null) return null;
    _fsCookies = solution.cookieString;
    _fsUA = solution.userAgent;
    if (_siteTagGroups.isEmpty) {
      final groups = _parseTagGroups(solution.html);
      if (groups.isNotEmpty && mounted) {
        setState(() => _siteTagGroups..clear()..addAll(groups));
      }
    }
    return _parseCards(solution.html);
  }

  /// allowFallback=false: 预取/SWR 等投机性流量专用 — 快速通道 (curl/dio)
  /// 未命中即静默放弃, 不落 FlareSolverr (求解 ~11s, 预取无权调动; cookies
  /// 失效日扫分类条才不会连环排队求解)。用户触发的加载走默认 true。
  Future<_ListPage?> _fetchList(String url, {bool allowFallback = true}) async {
    final sw = Stopwatch()..start();
    final viaCurl = await _fetchViaCurl(url);
    if (viaCurl != null && viaCurl.cards.isNotEmpty) {
      // [my] 慢速成功 (>1.5s) 落 WARNING 可见, 供性能排查
      if (sw.elapsedMilliseconds > 1500) {
        KazumiLogger().w(
            'DirectSearch: curl fast path SLOW ${sw.elapsedMilliseconds}ms, ${viaCurl.cards.length} cards');
      }
      return viaCurl;
    }
    final viaDio = await _fetchViaDio(url);
    if (viaDio != null && viaDio.cards.isNotEmpty) {
      if (sw.elapsedMilliseconds > 1500) {
        KazumiLogger().w(
            'DirectSearch: dio fast path SLOW ${sw.elapsedMilliseconds}ms, ${viaDio.cards.length} cards');
      }
      return viaDio;
    }
    if (!allowFallback) {
      KazumiLogger().i('DirectSearch: 预取放弃 (快速通道未命中, 不落 FS)');
      return null;
    }
    final viaFs = await _fetchViaFlareSolverr(url);
    KazumiLogger().i(
        'DirectSearch: FlareSolverr fallback ${sw.elapsedMilliseconds}ms, cards=${viaFs?.cards.length ?? 0}');
    return viaFs;
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
      // [my修复] 分类页翻页链接写的是 HTML 实体 (&amp;page=N), 字面量正则会
      // 整页漏配 → next=null → 下一页按钮不显示; 默认页 (?page=2) 不受影响。
      final pageLinks =
          RegExp(r'[?&](?:amp;)?page=(\d+)')
              .allMatches(html)
              .map((m) => int.tryParse(m.group(1)!) ?? 0)
              .toList();
      if (pageLinks.isNotEmpty) next = pageLinks.reduce((a, b) => a > b ? a : b);
      final current = RegExp(r'[?&]page=(\d+)').firstMatch(_lastFetchedUrl);
      final cur = current != null ? int.tryParse(current.group(1)!) ?? 1 : 1;
      // [my新增] 末页码 = 翻页条最大页码 (站点翻页条恒含末页链接)
      final last = pageLinks.isNotEmpty
          ? pageLinks.reduce((a, b) => a > b ? a : b)
          : null;
      return _ListPage(
          cards: cards,
          currentPage: cur,
          nextPage: next,
          lastPage: last);
    } catch (e) {
      KazumiLogger().w('DirectSearch: parse cards failed: $e');
      return null;
    }
  }

  String _lastFetchedUrl = '';

  /// 构建当前列表 URL: 搜索模式 (关键词非空) 带 query, 与浏览共用翻页
  /// 状态机 (修复搜索后翻页/跳页丢失搜索条件)
  String _listUrlFor() {
    final params = <String>[
      if (_rememberedKeyword.isNotEmpty)
        'query=${Uri.encodeComponent(_rememberedKeyword)}',
      ..._scopeParams(_genre),
    ];
    if (params.isEmpty) return '$_siteBase/search';
    return '$_siteBase/search?${params.join('&')}';
  }

  /// [my修改] 分区/标签查询参数 (浏览与搜索共用, 站点原生支持组合):
  /// 标签在前、分区在后; '最新' 分区无参
  List<String> _scopeParams(String genre) {
    final params = <String>[];
    if (_activeTags.isNotEmpty) {
      params.addAll(_activeTags
          .map((t) => 'tags%5B%5D=${Uri.encodeComponent(t)}'));
    }
    if (genre != '最新') {
      params.add('genre=${Uri.encodeComponent(genre)}');
    }
    return params;
  }

  /// 指定分区的列表 URL (悬停预取用, 不动当前状态)
  String _urlForGenre(String genre) {
    final params = _scopeParams(genre);
    if (params.isEmpty) return '$_siteBase/search';
    return '$_siteBase/search?${params.join('&')}';
  }

  /// 指定页码的完整 URL (与 _loadList 的拼法保持一致, 供预取做缓存键)
  /// [my修复] 分隔符自适应: _listUrlFor() 无查询参数时 (默认目录页
  /// /search) 翻页要用 '?', 否则拼出 /search&page=79 (404, 跳转必炸)
  String _listUrlForPage(int page) {
    var url = _listUrlFor();
    if (page > 1) {
      url += (url.contains('?') ? '&' : '?') + 'page=$page';
    }
    return url;
  }

  // ====== 页面缓存 (LRU ~8 页) + SWR ======
  // 命中即免网络秒开; 后台取新版本静默替换 (stale-while-revalidate)。
  // 网络 RTT 实测 ~1.5s (解析仅 ~75ms), 首访省不掉, 命中可全免。

  // [my修复] 页缓存/预取去重升级为静态: 页签改按钮导航后切走即销毁重建,
  // 实例字段随 dispose 丢失 → 切回必然重新取数 (2-3s)。静态字段与
  // _remembered* 同寿命 (进程内存活), 切回命中缓存秒开 (SWR 机制不变)。
  static final Map<String, _ListPage> _pageCache = {};
  static final Set<String> _prefetchInflight = {};

  void _cachePut(String url, _ListPage page) {
    _pageCache
      ..remove(url)
      ..[url] = page;
    while (_pageCache.length > 8) {
      _pageCache.remove(_pageCache.keys.first);
    }
    _persistPageCache();
  }

  /// [my新增] 页缓存磁盘持久化: App 重启后源搜索首屏直接上屏上次内容
  /// (SWR 后台刷新保证新鲜度) — 热点/慢网下 4s 首屏成本只在真冷启动付。
  void _persistPageCache() {
    unawaited(() async {
      try {
        final payload = {
          for (final e in _pageCache.entries)
            e.key: e.value.toJson(),
        };
        await GStorage.putSetting(
            SettingsKeys.directSearchPageCache, jsonEncode(payload));
      } catch (e) {
        KazumiLogger().w('DirectSearch: persist page cache failed: $e');
      }
    }());
  }

  void _restorePageCache() {
    final raw =
        GStorage.getSetting(SettingsKeys.directSearchPageCache).trim();
    if (raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      for (final e in decoded.entries) {
        try {
          _pageCache[e.key] = _ListPage.fromJson(
              Map<String, dynamic>.from(e.value as Map));
        } catch (_) {}
      }
      KazumiLogger().i(
          'DirectSearch: restored ${_pageCache.length} pages from disk');
    } catch (e) {
      KazumiLogger().w('DirectSearch: restore page cache failed: $e');
    }
  }

  Future<void> _prefetch(String url) async {
    if (_pageCache.containsKey(url) || _prefetchInflight.contains(url)) return;
    _prefetchInflight.add(url);
    try {
      final page = await _fetchList(url, allowFallback: false);
      if (page != null && page.cards.isNotEmpty) {
        _cachePut(url, page);
        // 封面预热: 图片缓存提前拉前 12 张, 命中时封面也近乎秒出
        if (mounted) {
          for (final c in page.cards.take(12)) {
            if (c.thumb.isEmpty) continue;
            precacheImage(CachedNetworkImageProvider(c.thumb), context);
          }
        }
      }
    } catch (_) {
      // 预取失败静默丢弃, 翻页时走正常加载
    } finally {
      _prefetchInflight.remove(url);
    }
  }

  // [my修复] 后台预取节流队列: CF 按 burst 触发重挑战 (实测 6 连发窗口内
  // 分类页全被挑, 11:59 复发), 预取统一入静态队列 + 600ms 间隔错峰;
  // 用户触发的加载不排队 (只管预取流量)。
  static final Queue<String> _prefetchQueue = Queue();
  static final Set<String> _prefetchQueued = {};
  static bool _prefetchDraining = false;
  static DateTime _prefetchLastRun =
      DateTime.fromMillisecondsSinceEpoch(0);

  void _enqueuePrefetch(String url) {
    if (_pageCache.containsKey(url) ||
        _prefetchInflight.contains(url) ||
        _prefetchQueued.contains(url)) {
      return;
    }
    _prefetchQueued.add(url);
    _prefetchQueue.add(url);
    _drainPrefetchQueue();
  }

  void _drainPrefetchQueue() {
    if (_prefetchDraining) return;
    _prefetchDraining = true;
    unawaited(() async {
      try {
        while (_prefetchQueue.isNotEmpty) {
          final wait =
              const Duration(milliseconds: 600) -
                  DateTime.now().difference(_prefetchLastRun);
          if (wait > Duration.zero) {
            await Future.delayed(wait);
          }
          if (_prefetchQueue.isEmpty) break;
          final url = _prefetchQueue.removeFirst();
          _prefetchQueued.remove(url);
          _prefetchLastRun = DateTime.now();
          await _prefetch(url);
        }
      } finally {
        _prefetchDraining = false;
      }
    }());
  }

  /// [my新增] 批量预取: 未缓存的 URL 合并进一次 curl 进程 (--next 连发,
  /// 复用 TLS 连接, 热点实测后继请求省 ~60%)。首页结果入缓存; 其余 URL
  /// 各自单发补齐 (批内切分不可靠, 但连接已复用 — 单发走的是已热身的
  /// 代理通道, 代价小)。全部失败静默。
  /// [my新增] 双向预取: N+1 与 N-1 (往回翻也秒开)。
  /// N-1 用当前已知页码直接构造 (页码存在即合法); N+1 需 _nextPage 确认
  /// 有下一页 (末页置灰逻辑同款)。[my调整] 经节流队列错峰出队。
  void _prefetchNeighbors(int page) {
    if (_nextPage != null && _nextPage! > page) {
      _enqueuePrefetch(_listUrlForPage(page + 1));
    }
    if (page > 1) {
      _enqueuePrefetch(_listUrlForPage(page - 1));
    }
  }

  /// SWR: 缓存命中后的后台刷新 — 拉新版本, 用户仍在本页才静默替换
  Future<void> _refreshInBackground(String url) async {
    if (_prefetchInflight.contains(url)) return;
    _prefetchInflight.add(url);
    try {
      final fresh = await _fetchList(url, allowFallback: false);
      if (fresh == null || fresh.cards.isEmpty) return;
      _cachePut(url, fresh);
      if (!mounted || _lastFetchedUrl != url) return;
      setState(() {
        _cards = fresh.cards;
        _nextPage = fresh.nextPage;
        _lastPage = fresh.lastPage ?? _lastPage;
      });
    } catch (_) {
    } finally {
      _prefetchInflight.remove(url);
    }
  }

  /// 悬停预取: 桌面端鼠标扫过分区条 = 意图信号, 提前拉该分区第 1、2 页
  /// (浏览分类的常见深度, 深度+2)。200ms 防抖: 快速扫过整条只触发停下
  /// 的那个, 不为路过者付请求。
  Timer? _hoverDebounce;
  void _hoverPrefetchGenre(String genre) {
    _hoverDebounce?.cancel();
    _hoverDebounce = Timer(const Duration(milliseconds: 200), () {
      if (genre == _genre || _loading || _siteBase.isEmpty) return;
      final base = _urlForGenre(genre);
      // [my调整] 经节流队列错峰 (原直发 2 请求叠加翻页预取即成 burst)
      _enqueuePrefetch(base);
      _enqueuePrefetch('$base&page=2');
    });
  }

  Future<void> _loadList({required bool reset, int page = 1}) async {
    if (_siteBase.isEmpty) {
      setState(() => _error = '未配置浏览站点: 网络设置 → 源直连浏览站点');
      return;
    }
    if (_loading) return;
    final url = _listUrlForPage(page);
    _lastFetchedUrl = url;
    // 缓存命中: 即刻上屏 + 后台刷新 (免 1.5s 网络 RTT)
    final cached = _pageCache[url];
    if (cached != null) {
      setState(() {
        _loading = false;
        _error = null;
        _cards = cached.cards;
        _nextPage = cached.nextPage;
        // [my修复] reset (换范围/新搜索) 时不残留旧范围的总页数:
        // 无翻页条 = 单页 (该站 >1 页必有翻页条)
        _lastPage = cached.lastPage ?? (reset ? 1 : _lastPage);
        _page = page;
      });
      _refreshInBackground(url);
      // 后台顺带双向预取 (下一页 + 上一页)
      _prefetchNeighbors(page);
      return;
    }
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
        // 翻到末页之后 (站点对超出页返回空页/404, 整条链路拿不到卡片) 给出
        // 与站点不可达不同的提示; 当前页内容保留不清空。
        _error = page > 1
            ? '后面没有更多内容了 (或站点暂时不可达)'
            : '加载失败 (过盾失败或站点不可达), 请重试';
        if (reset) _cards = [];
      } else {
        _cards = listPage.cards;
        _nextPage = listPage.nextPage;
        // [my修复] reset (换范围/新搜索) 时旧 _lastPage 不残留 — 单页
        // 结果的搜索页无翻页条, 原实现 `?? _lastPage` 会显示上一范围的
        // 总页数 (分区 79 页 / 搜索 1 页)。无条 = 单页 (空结果除外);
        // 翻页中保留旧值兜底 (翻页条滑窗抖动)
        _lastPage = listPage.lastPage ??
            (reset ? (_cards.isNotEmpty ? 1 : null) : _lastPage);
        _page = page;
        _rememberedPage = page;
      }
    });
    // 成功后入缓存并后台双向预取 (fire-and-forget)
    if (listPage != null && listPage.cards.isNotEmpty) {
      _cachePut(url, listPage);
      _prefetchNeighbors(page);
    }
    // [my新增] 搜索模式收尾: 首页记录搜索历史 (普通浏览跳过)。
    // [my移除 2026-10-31] 原 Bangumi 评分匹配调用随功能下线 (备份见文件头)
    if (listPage != null && _rememberedKeyword.isNotEmpty) {
      if (page == 1) await _recordKeywordHistory(_rememberedKeyword);
    }
  }

  Future<void> _nextPageLoad() => _loadList(reset: false, page: _page + 1);
  Future<void> _prevPageLoad() =>
      _page > 1 ? _loadList(reset: false, page: _page - 1) : Future.value();

  /// [my新增] 页码跳转: 输入目标页 (范围 1..lastPage), 直达加载。
  /// KazumiDialog.show<int> 的 Future 返回弹窗带回的页码。
  Future<void> _jumpToPage() async {
    final last = _lastPage ?? 9999;
    final controller = TextEditingController();
    final page = await KazumiDialog.show<int>(
      clickMaskDismiss: true,
      builder: (dialogContext) => AlertDialog(
        title: const Text('跳转到页码', style: TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('当前第 $_page 页 / 共 $last 页',
                style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                hintText: '1 - $last',
                prefixIcon: const Icon(Icons.tag_rounded),
              ),
              onSubmitted: (v) =>
                  KazumiDialog.dismiss(popWith: int.tryParse(v)),
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
            onPressed: () => KazumiDialog.dismiss(
                popWith: int.tryParse(controller.text)),
            child: const Text('跳转'),
          ),
        ],
      ),
    );
    if (page != null) {
      await _gotoPage(page);
    }
  }

  /// [my新增] 直达指定页 (校验范围)
  Future<void> _gotoPage(int page) async {
    final last = _lastPage ?? page;
    if (page < 1 || page > last || page == _page) return;
    await _loadList(reset: false, page: page);
  }

  // ====== 搜索模式 (站内关键词, 走同一卡片解析) ======

  /// 站内搜索: 关键词入静态状态机, 统一走 _loadList — 翻页/跳页/页缓存/
  /// SWR/双向预取与浏览共用同一套机制 (修复搜索后翻页不带 query)。
  /// 空关键词提交 = 退出搜索回普通浏览。
  Future<void> _search() async {
    final keyword = _keywordController.text.trim();
    if (_loading) return;
    if (keyword.isEmpty && _rememberedKeyword.isEmpty) return;
    setState(() {
      _rememberedKeyword = keyword;
    });
    await _loadList(reset: true);
  }

  // ====== 站内搜索历史 (输入框下拉回填, 只留本地) ======

  void _loadKeywordHistory() {
    final raw =
        GStorage.getSetting(SettingsKeys.directSearchKeywordHistory).trim();
    if (raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        _keywordHistory = decoded
            .map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList();
      }
    } catch (e) {
      KazumiLogger().w('DirectSearch: parse keyword history failed: $e');
    }
  }

  /// 记录一次成功提交: 去重置顶 (大小写不敏感), 超上限裁掉最旧
  Future<void> _recordKeywordHistory(String keyword) async {
    final folded = keyword.toLowerCase();
    _keywordHistory
      ..removeWhere((e) => e.toLowerCase() == folded)
      ..insert(0, keyword);
    if (_keywordHistory.length > _historyMax) {
      _keywordHistory.removeRange(_historyMax, _keywordHistory.length);
    }
    await GStorage.putSetting(
        SettingsKeys.directSearchKeywordHistory, jsonEncode(_keywordHistory));
  }

  Future<void> _clearKeywordHistory() async {
    setState(() => _keywordHistory = []);
    await GStorage.putSetting(SettingsKeys.directSearchKeywordHistory, '');
    // 收起下拉 (清空后无可展示项)
    _keywordFocusNode.unfocus();
  }


  // ====== 收藏切换 (本地收藏 + Bangumi 同步按全局开关走) ======

  /// [my新增] 重建收藏状态缓存: id 集合 + 系列名集合 (星标按作品匹配用)。
  /// [my优化] 系列名存"剥除后"形态, 星标匹配走单侧剥除的快速通道
  void _refreshCollectedState() {
    final items = _collectController.collectibles;
    _collectedIds
      ..clear()
      ..addAll(items.map((c) => c.bangumiItem.id));
    _collectedSeriesNames
      ..clear()
      ..addAll([
        for (final c in items)
          if (c.section == 1 &&
              CollectSectionRepair.isDirectSourceItem(c.bangumiItem))
            SeriesDetector.stripEpisodeMarker(
              (c.bangumiItem.nameCn.isNotEmpty
                      ? c.bangumiItem.nameCn
                      : c.bangumiItem.name)
                  .trim(),
            )
      ].where((n) => n.length >= 2));
  }

  /// [my新增] 卡片是否已收藏: 精确 id 命中, 或标题按作品匹配到里番区
  /// 系列条目 (同系列其他集自动亮星, 无需逐集收藏)
  bool _isCardCollected(_BrowseCard card) {
    if (_collectedIds.contains(_itemIdFor(card))) return true;
    final title = card.title.trim();
    if (title.length < 2) return false;
    for (final name in _collectedSeriesNames) {
      if (SeriesDetector.sameSeriesStripped(name, title)) return true;
    }
    return false;
  }

  /// [my新增] 卡片对应的既有收藏条目: 先按 id 精确找, 再按作品名匹配
  /// (同系列其他集 → 命中系列条目, 弹窗预选其分类, 改分类/取消收藏
  /// 都作用于整个作品)
  CollectedBangumi? _collectedEntryFor(_BrowseCard card) {
    final id = _itemIdFor(card);
    for (final c in _collectController.collectibles) {
      if (c.bangumiItem.id == id) return c;
    }
    final title = card.title.trim();
    if (title.length < 2) return null;
    for (final c in _collectController.collectibles) {
      if (c.section != 1) continue;
      if (!CollectSectionRepair.isDirectSourceItem(c.bangumiItem)) continue;
      final name = c.bangumiItem.nameCn.isNotEmpty
          ? c.bangumiItem.nameCn
          : c.bangumiItem.name;
      if (SeriesDetector.sameSeriesName(name, title)) return c;
    }
    return null;
  }

  /// 星标点击 → 分类选择弹窗 (用户自主判断分类; 已收藏可选取消收藏)
  Future<void> _showCollectTypePicker(_BrowseCard card) async {
    // [my修改] 星标按作品匹配: 命中系列条目时预选其分类, 取消收藏/
    // 改分类都作用于整个作品
    final matched = _collectedEntryFor(card);
    final wasCollected = matched != null;
    // [my修复] 本地存储用 CollectType 语义 (1=在看 2=想看 4=看过), 与
    // Bangumi API 枚举 (1=想看 2=看过) 数值不同 — 之前传错枚举导致选项错位。
    int? selectedType = matched?.type;
    await KazumiDialog.show(
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          Widget typeOption(CollectType t) => RadioListTile<int>(
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
                  CollectType.planToWatch,
                  CollectType.watched,
                  CollectType.watching,
                  CollectType.onHold,
                  CollectType.abandoned,
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
                  if (type == null) return;
                  if (type == 0) {
                    // [my修改] 命中系列条目时取消的是整个作品的收藏
                    final delItem =
                        matched?.bangumiItem ?? _fabricatedItem(card);
                    _collectController.deleteCollectLocalOnly(delItem);
                    setState(() => _refreshCollectedState());
                    KazumiDialog.dismiss();
                    KazumiDialog.showToast(message: '已取消收藏');
                    return;
                  }
                  // 弹窗打开期间可能刚完成认领, 条目 id 会从哈希变真实条目,
                  // 现取现用避免旧 id 进本地库
                  KazumiDialog.dismiss();
                  unawaited(_collectAsSeries(card, _fabricatedItem(card), type));
                },
                child: const Text('确定'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// [my新增] 收藏即作品 (混合方案, 依据 T1 实测): 先走现成取集链路
  /// 拿观看页播放列表, 按"相邻标题公共前缀相似度"判定系列/单集 —
  /// 系列作品: 条目锚点=列表中最老一集的链接 (列表新→旧, 旧集稳定;
  /// 之后打开锚点页即全集, 新集自动出现), 名称=系列名, id=hash(源名+锚点)
  /// → 同系列从任意一集收藏都归并到同一条目;
  /// 单集/无系列特征/取集失败/已认领 bgm 条目: 退回旧行为 (info=卡片链接)。
  /// 本页收藏一律入里番区 (section=1): 纯本地 + WebDAV, 永不同步 Bangumi。
  Future<void> _collectAsSeries(
      _BrowseCard card, BangumiItem baseItem, int type) async {
    if (dialogs.isRunning) return;
    await dialogs.run((task) async {
      BangumiItem item = baseItem;
      var note = '';
      var stored = false;
      final plugin = _selectedPlugin;
      if (plugin != null) {
        List<Road> roads = const [];
        try {
          roads = await task.loading(
            message: '正在解析作品集数',
            barrierDismissible: isDesktop(),
            action: () => plugin.queryChapterRoads(card.href),
          );
        } catch (error) {
          KazumiLogger().w('DirectSearch: collect roads failed', error: error);
        }
        // [my优化·抽取] 判定+构造+落库+合并走共享 upgradeToSeries
        // (created: 帮手内已落库并合并; 否则原条目在方法末尾统一落库)
        final (status, upgradedItem, mergedCount) =
            await SeriesDetector.upgradeToSeries(
          pluginName: plugin.name,
          item: item,
          roads: roads,
          type: type,
          add: (it, t) => _collectController.addCollectLocalOnly(it,
              type: t, section: 1),
          delete: (it) => _collectController.deleteCollectLocalOnly(it),
          all: _collectController.collectibles,
        );
        if (status == SeriesDetector.seriesUpgradeCreated) {
          item = upgradedItem;
          stored = true;
          note = ' · 已按作品聚合';
          if (mergedCount > 0) note = '$note，合并旧收藏$mergedCount条';
        }
      }
      if (!stored) {
        await _collectController.addCollectLocalOnly(item,
            type: type, section: 1);
      }
      if (!mounted) return;
      setState(() => _refreshCollectedState());
      KazumiDialog.showToast(
          message: '已收藏 · ${CollectType.fromValue(type).label}$note');
    }, onError: (error, stackTrace) {
      KazumiLogger().w('DirectSearch: collect-as-series failed',
          error: error);
      KazumiDialog.showToast(message: '收藏失败，请重试');
    });
  }

  // ====== 播放 (卡片 → 取集 → 播放页) ======

  /// [my新增] 公共播放入口 (源搜索卡片与里番收藏页共用):
  /// 取线路 → 跳播放页。src = 播放页地址。
  ///
  /// 系列播放聚合: 判定为系列作品时, 播放条目改用系列锚点 id (与收藏聚合
  /// 一致 → 播放页凭历史恢复"上次访问的集数", 时间表按作品归一), 无历史时
  /// 从第一集 (列表最老一集) 开始。
  Future<void> playViaPlugin({
    required Plugin plugin,
    required String title,
    required String src,
    required BangumiItem item,
  }) async {
    if (dialogs.isRunning) return;
    await dialogs.run((task) async {
      final roads = await task.loading(
        message: '正在获取播放列表',
        barrierDismissible: isDesktop(),
        action: () => plugin.queryChapterRoads(src),
      );
      if (roads.isEmpty) {
        throw Exception('未获取到播放线路');
      }
      var playItem = item;
      var playTitle = title;
      var playSrc = src;
      int? startEpisode;
      var startRoad = 0;
      final detected = SeriesDetector.detect(roads);
      if (detected.isSeries) {
        playItem = SeriesDetector.buildSeriesItem(
            _stableDirectId('${plugin.name}_${detected.anchorUrl}'),
            detected,
            item);
        playTitle = detected.seriesName;
        playSrc = detected.anchorUrl;
        final roadIndex =
            roads.indexWhere((r) => r.data.contains(detected.anchorUrl));
        if (roadIndex >= 0) {
          startRoad = roadIndex;
          startEpisode =
              roads[roadIndex].data.lastIndexOf(detected.anchorUrl) + 1;
        }
      }
      if (mounted) {
        task.withContext((context) => context.pushNamed(
              '/video/',
              arguments: OnlineVideoPlaybackArgs(
                bangumiItem: playItem,
                plugin: plugin,
                title: playTitle,
                src: playSrc,
                roads: roads,
                startEpisode: startEpisode,
                startRoad: startRoad,
              ),
            ));
      }
    }, onError: (error, stackTrace) {
      KazumiLogger().w('DirectSearch: play failed', error: error);
      KazumiDialog.showToast(message: '获取播放列表失败，请重试');
    });
  }

  /// 源搜索卡片播放入口 (保留旧签名, 组装后委托公共方法)
  Future<void> _play(_BrowseCard card) async {
    final plugin = _selectedPlugin;
    if (plugin == null) return;
    await playViaPlugin(
      plugin: plugin,
      title: card.title,
      src: card.href,
      item: _fabricatedItem(card),
    );
  }

  // ====== 标签多选弹窗 ======

  Future<void> _showTagPicker() async {
    final selected = Set<String>.from(_activeTags);
    final filterController = TextEditingController();
    var filter = '';
    await KazumiDialog.show(
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          // 分组渲染: 组名标题 + 组内 chips; 筛选时整组命中才显示组头
          final groups = _siteTagGroups.entries
              .map((e) => MapEntry(
                  e.key,
                  e.value
                      .where((t) =>
                          filter.isEmpty || t.contains(filter))
                      .toList()))
              .where((e) => e.value.isNotEmpty)
              .toList();
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
                    onChanged: (v) => setDialogState(() => filter = v.trim()),
                  ),
                  const SizedBox(height: 8),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final group in groups) ...[
                            Padding(
                              padding: const EdgeInsets.only(top: 8, bottom: 2),
                              child: Text(
                                group.key,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primary,
                                ),
                              ),
                            ),
                            Wrap(
                              spacing: 6,
                              runSpacing: 2,
                              children: [
                                for (final t in group.value)
                                  FilterChip(
                                    label: Text(t,
                                        style: const TextStyle(fontSize: 12)),
                                    selected: selected.contains(t),
                                    onSelected: (_) {
                                      setDialogState(() =>
                                          selected.contains(t)
                                              ? selected.remove(t)
                                              : selected.add(t));
                                      // [my修复] 即时应用: 点选即刻生效
                                      // (原需再点確定才生效)
                                      _activeTags
                                        ..clear()
                                        ..addAll(selected);
                                      _rememberedTags
                                        ..clear()
                                        ..addAll(selected);
                                      _rememberedKeyword = ''; // 换标签退出搜索
                                      _loadList(reset: true);
                                    },
                                  ),
                              ],
                            ),
                          ],
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
                child: const Text('關閉'),
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
    // [my修复] 回写静态记忆 — 原实现从未写入 _rememberedTags, 标签记忆
    // 自上线起实际未生效 (切走再回/重建后标签丢失)
    _rememberedTags
      ..clear()
      ..addAll(selected);
    _rememberedKeyword = ''; // 换标签退出搜索
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
                        _rememberedKeyword = ''; // 换源退出搜索
                      });
                      _loadList(reset: true);
                    },
                    hint: const Text('选择规则源'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 3,
                  // [my新增] 搜索历史下拉: SDK RawAutocomplete, 外部注入
                  // controller/focusNode (_search 与搜索按钮仍读原 controller)
                  child: RawAutocomplete<String>(
                    textEditingController: _keywordController,
                    focusNode: _keywordFocusNode,
                    // 框获焦且为空时展示全部历史, 输入时包含匹配 (不分大小写)
                    optionsBuilder: (TextEditingValue value) {
                      final text = value.text.trim().toLowerCase();
                      if (text.isEmpty) return _keywordHistory;
                      return _keywordHistory
                          .where((e) => e.toLowerCase().contains(text));
                    },
                    fieldViewBuilder: (context, textEditingController,
                        focusNode, onFieldSubmitted) {
                      // 回车保持原行为: 执行搜索, 不吞成下拉选中
                      return TextField(
                        controller: textEditingController,
                        focusNode: focusNode,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _search(),
                        decoration:
                            const InputDecoration(hintText: '站内搜索关键词'),
                      );
                    },
                    optionsViewBuilder: (context, onSelected, options) {
                      if (options.isEmpty) return const SizedBox.shrink();
                      return Align(
                        alignment: Alignment.topLeft,
                        child: Material(
                          elevation: 4,
                          borderRadius: BorderRadius.circular(8),
                          clipBehavior: Clip.antiAlias,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                                maxWidth: 360, maxHeight: 280),
                            child: ListView(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 4),
                              shrinkWrap: true,
                              children: [
                                // 点击历史项仅回填 (Autocomplete 选中即写回
                                // controller), 用户再按搜索, 与主搜索页一致
                                for (final keyword in options)
                                  ListTile(
                                    dense: true,
                                    visualDensity: VisualDensity.compact,
                                    leading: Icon(Icons.history_rounded,
                                        size: 18,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant),
                                    title: Text(keyword,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis),
                                    onTap: () => onSelected(keyword),
                                  ),
                                const Divider(height: 1),
                                ListTile(
                                  dense: true,
                                  visualDensity: VisualDensity.compact,
                                  leading: Icon(Icons.delete_sweep_outlined,
                                      size: 18,
                                      color:
                                          Theme.of(context).colorScheme.error),
                                  title: Text('清空搜索历史',
                                      style: TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .error)),
                                  onTap: _clearKeywordHistory,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
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
                    // 悬停预取: 鼠标扫过即后台拉取该分区第 1 页, 点击命中
                    // 缓存免 1.5s 网络 RTT
                    child: MouseRegion(
                      onEnter: (_) => _hoverPrefetchGenre(g),
                      child: ChoiceChip(
                        label: Text(g),
                        selected: _genre == g,
                        onSelected: (_) {
                          setState(() {
                            _genre = g;
                            _rememberedGenre = g;
                            _rememberedKeyword = ''; // 换分区退出搜索
                          });
                          _loadList(reset: true);
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // 標籤 chips 行 (标签表提取后显示)
          if (_siteTagGroups.isNotEmpty)
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
                          // [my修复] 同步静态记忆 — 原只删 _activeTags,
                          // 切走再回被 _rememberedTags 灌回
                          _rememberedTags.remove(t);
                          _rememberedKeyword = ''; // 换标签退出搜索
                          _loadList(reset: true);
                        },
                      ),
                    ),
                ],
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
                  return InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => _play(card),
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
                            // [my修改] 星标按作品匹配: 同系列其他集自动亮星
                            _isCardCollected(card)
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
                  // [my新增] 点击弹页码跳转 (显示末页码)
                  InkWell(
                    onTap: _lastPage != null ? _jumpToPage : null,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      child: Text(
                        _lastPage != null
                            ? '第 $_page / $_lastPage 页'
                            : '第 $_page 页',
                        style: TextStyle(
                          fontSize: 14,
                          color: _lastPage != null
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    // _nextPage = 站点翻页条里的最大页码 (恒含末页) — 等于当前页
                    // 即已到末页, 置灰; 否则会点进空页使整条取数链路报错。
                    onPressed: _nextPage != null && _nextPage! > _page
                        ? _nextPageLoad
                        : null,
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
