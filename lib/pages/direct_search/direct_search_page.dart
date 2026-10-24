// [my修改] 源直连浏览与搜索: 绕过 Bangumi 直接使用规则源 (R18 场景,
// Bangumi 搜索被官方过滤无入口)。
// 浏览: 源站目录页 + 分区 chips + 標籤多选 + 封面墙 + 翻页 (FlareSolverr
// 过盾取页, 凭证播种后走 dio 快速通道; 站点轮换视频 CDN 域名, 解析按播放器
// 元素定位)。
// 播放: 取集 → 伪 bangumi 条目 (md5 稳定 id, 与本地视频模式同构)。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/dialog/dialog_task.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
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

  // Bangumi 里番评分匹配 (搜索关键词模式)
  final Map<String, _BangumiRef> _bangumiRefs = {};

  /// 手动认领 (卡片 href → {id, score, votes}): 自动匹配漏网时手动绑定
  /// bgm 条目, JSON 落设置框; 查找优先级高于自动匹配。
  Map<String, Map<String, dynamic>> _claims = {};
  bool _bangumiQuerying = false;

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
    _genre = _rememberedGenre;
    _activeTags.addAll(_rememberedTags);
    _page = _rememberedPage;
    _loadClaims();
    _collectController.loadCollectibles();
    _collectedIds.addAll(
        _collectController.collectibles.map((c) => c.bangumiItem.id));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // [my修复] 初始加载带记忆页码 — 原先 initState 恢复 _page 后,
      // 这里仍按默认 page:1 加载并回写, 记忆等于白恢复
      _loadList(reset: true, page: _rememberedPage > 1 ? _rememberedPage : 1);
    });
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
      final proxy =
          NetworkConfig.fromSettings().proxyForUri(Uri.parse(url));
      // [my修复] 不带 --compressed: Win10 内置 curl 8.4.0 (Schannel) 不支持
      // 该参数, 直接 exit 2 空输出, 快速通道上线以来从未真正生效过。
      final r = await Process.run(
        exe,
        [
          '-s',
          '--max-time',
          '20',
          if (proxy != null) ...['-x', 'http://${proxy.host}:${proxy.port}'],
          '-A',
          _fsUA ?? 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
          '-H',
          'Cookie: ${_fsCookies!}',
          url,
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      final body = r.stdout.toString();
      final page = _consumeListBody(body);
      if (page != null) {
        KazumiLogger().i(
            'DirectSearch: curl fast path ok, ${page.cards.length} cards');
      } else {
        KazumiLogger().w(
            'DirectSearch: curl fast path null | exit=${r.exitCode} len=${body.length} challenge=${body.contains('challenge-platform')} stderr=${r.stderr.toString().trim()}');
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
      KazumiLogger().i(
          'DirectSearch: curl fast path ${sw.elapsedMilliseconds}ms, ${viaCurl.cards.length} cards');
      return viaCurl;
    }
    final viaDio = await _fetchViaDio(url);
    if (viaDio != null && viaDio.cards.isNotEmpty) {
      KazumiLogger().i(
          'DirectSearch: dio fast path ${sw.elapsedMilliseconds}ms, ${viaDio.cards.length} cards');
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
      return _ListPage(cards: cards, currentPage: cur, nextPage: next);
    } catch (e) {
      KazumiLogger().w('DirectSearch: parse cards failed: $e');
      return null;
    }
  }

  String _lastFetchedUrl = '';

  /// 构建当前列表 URL: 分区与标签可同时生效 (站点原生支持组合参数)
  String _listUrlFor() => _urlForGenre(_genre);

  /// 指定分区的列表 URL (悬停预取用, 不动当前状态)
  String _urlForGenre(String genre) {
    final params = <String>[];
    if (_activeTags.isNotEmpty) {
      params.addAll(_activeTags
          .map((t) => 'tags%5B%5D=${Uri.encodeComponent(t)}'));
    }
    if (genre != '最新') {
      params.add('genre=${Uri.encodeComponent(genre)}');
    }
    if (params.isEmpty) return '$_siteBase/search';
    return '$_siteBase/search?${params.join('&')}';
  }

  /// 指定页码的完整 URL (与 _loadList 的拼法保持一致, 供预取做缓存键)
  String _listUrlForPage(int page) {
    var url = _listUrlFor();
    if (page > 1) url += '&page=$page';
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
      });
    } catch (_) {
    } finally {
      _prefetchInflight.remove(url);
    }
  }

  /// 悬停预取: 桌面端鼠标扫过分区条 = 意图信号, 提前拉该分区第 1 页。
  /// 200ms 防抖: 快速扫过整条只触发停下的那个, 不为路过者付请求。
  Timer? _hoverDebounce;
  void _hoverPrefetchGenre(String genre) {
    _hoverDebounce?.cancel();
    _hoverDebounce = Timer(const Duration(milliseconds: 200), () {
      if (genre == _genre || _loading || _siteBase.isEmpty) return;
      _prefetch(_urlForGenre(genre));
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
        _page = page;
      });
      _refreshInBackground(url);
      // 后台顺带预取下一页
      if (_nextPage != null && _nextPage! > _page) {
        _prefetch(_listUrlForPage(page + 1));
      }
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
        _page = page;
        _rememberedPage = page;
      }
    });
    // 成功后入缓存并后台预取下一页 (fire-and-forget)
    if (listPage != null && listPage.cards.isNotEmpty) {
      _cachePut(url, listPage);
      if (_nextPage != null && _nextPage! > _page) {
        _prefetch(_listUrlForPage(page + 1));
      }
    }
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
    // 手动认领优先: 绑定关系持久, 自动匹配是会话级的
    final claim = _claims[card.href];
    if (claim != null) {
      return _BangumiRef(
        subjectId: (claim['id'] ?? '').toString(),
        score: (claim['score'] as num?)?.toDouble() ?? 0,
        votes: (claim['votes'] ?? '').toString(),
      );
    }
    final key = _normalizeTitle(card.title);
    if (_bangumiRefs.containsKey(key)) return _bangumiRefs[key];
    for (final e in _bangumiRefs.entries) {
      if (e.key.isEmpty) continue;
      if (key.contains(e.key) || e.key.contains(key)) return e.value;
    }
    return null;
  }

  // ====== 手动认领 (自动匹配漏网的卡片手动绑定 bgm 条目) ======

  void _loadClaims() {
    final raw = GStorage.getSetting(SettingsKeys.directSearchClaims).trim();
    if (raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        _claims = decoded.map((k, v) =>
            MapEntry(k.toString(), Map<String, dynamic>.from(v as Map)));
      }
    } catch (e) {
      KazumiLogger().w('DirectSearch: parse claims failed: $e');
    }
  }

  Future<void> _persistClaims() async {
    await GStorage.putSetting(
        SettingsKeys.directSearchClaims, jsonEncode(_claims));
  }

  Future<void> _setClaim(_BrowseCard card, Map<String, dynamic>? claim) async {
    if (claim == null) {
      _claims.remove(card.href);
    } else {
      _claims[card.href] = claim;
    }
    await _persistClaims();
    if (mounted) setState(() {});
  }

  /// 认领检索: bgm v0 搜索 (含 nsfw), 选中即绑定; 已认领可解除。
  Future<void> _showClaimSearch(_BrowseCard card) async {
    final controller = TextEditingController(text: card.title);
    List<Map<String, dynamic>> results = [];
    var querying = false;
    var searched = false;

    Future<void> runSearch(
        void Function(void Function()) setDialogState, String keyword) async {
      final token =
          GStorage.getSetting(SettingsKeys.bangumiAccessToken).trim();
      if (token.isEmpty) {
        KazumiDialog.showToast(message: '未配置 Bangumi 令牌, 无法检索');
        return;
      }
      setDialogState(() => querying = true);
      try {
        final dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 20),
          validateStatus: (_) => true,
        ));
        dio.options.headers = {
          'user-agent': 'kazumi-direct-search/1.0 (bgm claim)',
          'authorization': 'Bearer $token',
        };
        final resp = await dio.post(
          'https://api.bgm.tv/v0/search/subjects',
          data: {'keyword': keyword, 'limit': 20, 'filter': {'nsfw': true}},
        );
        final data = (resp.data['data'] as List? ?? [])
            .whereType<Map>()
            .map((s) => Map<String, dynamic>.from(s))
            .toList();
        setDialogState(() {
          results = data;
          querying = false;
          searched = true;
        });
      } catch (e) {
        KazumiLogger().i('DirectSearch: claim search failed: $e');
        setDialogState(() => querying = false);
        KazumiDialog.showToast(message: '检索失败');
      }
    }

    await KazumiDialog.show(
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final current = _claims[card.href];
          return AlertDialog(
            title: Text('认领条目 — ${card.title}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15)),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (current != null)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.link_off, size: 20),
                      title: Text(
                          '已认领 bgm #${current['id']} — 点击解除认领',
                          style: const TextStyle(fontSize: 13)),
                      onTap: () async {
                        await _setClaim(card, null);
                        KazumiDialog.dismiss();
                      },
                    ),
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: controller,
                        onSubmitted:
                            (v) => runSearch(setDialogState, v),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.search),
                      onPressed: () =>
                          runSearch(setDialogState, controller.text),
                    ),
                  ]),
                  const SizedBox(height: 8),
                  Flexible(
                    child: querying
                        ? const Center(child: CircularProgressIndicator())
                        : ListView(
                            shrinkWrap: true,
                            children: [
                              for (final s in results)
                                ListTile(
                                  dense: true,
                                  title: Text((s['name'] ?? '').toString(),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 13)),
                                  subtitle: Text(
                                      '${(s['nameCn'] ?? '').toString()}  ★${((s['rating'] ?? const {})['score'] ?? 0)}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style:
                                          const TextStyle(fontSize: 11)),
                                  onTap: () async {
                                    final rating = s['rating'] ?? const {};
                                    await _setClaim(card, {
                                      'id': (s['id'] ?? 0).toString(),
                                      'score':
                                          (rating['score'] as num?) ?? 0,
                                      'votes': (rating['total'] ?? 0)
                                          .toString(),
                                    });
                                    KazumiDialog.dismiss();
                                    KazumiDialog.showToast(
                                        message: '已认领, 收藏将同步 Bangumi');
                                  },
                                ),
                              if (results.isEmpty && searched)
                                const ListTile(
                                    dense: true,
                                    title: Text('无结果',
                                        style: TextStyle(fontSize: 13))),
                            ],
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: KazumiDialog.dismiss,
                child: Text('关闭',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.outline)),
              ),
            ],
          );
        },
      ),
    );
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
    // [my修复] 本地存储用 CollectType 语义 (1=在看 2=想看 4=看过), 与
    // Bangumi API 枚举 (1=想看 2=看过) 数值不同 — 之前传错枚举导致选项错位。
    int? selectedType = wasCollected ? CollectType.watched.value : null;
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
                if (_claims[card.href] == null && _refFor(card) == null)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.inventory_2, size: 20),
                    title: const Text('手动认领条目…',
                        style: TextStyle(fontSize: 13)),
                    subtitle: const Text('匹配 Bangumi 条目获取评分 (仅信息, 不同步)',
                        style: TextStyle(fontSize: 11)),
                    onTap: () => _showClaimSearch(card),
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
                  // 弹窗打开期间可能刚完成认领, 条目 id 会从哈希变真实条目,
                  // 现取现用避免旧 id 进本地库
                  final item = _fabricatedItem(card);
                  // [my修复] type==0 (取消收藏) 此前被提前 return 拦死,
                  // 从未生效; 现按有无 bgm 匹配走对应删除路径。
                  // [my修改] 本页收藏一律入里番区 (section=1): 纯本地 +
                  // WebDAV, 永不同步 Bangumi (整站成人内容, 表番账号保持
                  // 干净); 认领仅用于评分/信息增强, 不触发同步
                  if (type == 0) {
                    _collectController.deleteCollectLocalOnly(item);
                  } else {
                    _collectController.addCollectLocalOnly(item,
                        type: type, section: 1);
                  }
                  // [my修复] setState 刷新星标 + toast 反馈
                  final label = CollectType.fromValue(type).label;
                  setState(() {
                    if (type == 0) {
                      _collectedIds.remove(item.id);
                    } else {
                      _collectedIds.add(item.id);
                    }
                  });
                  KazumiDialog.dismiss();
                  KazumiDialog.showToast(
                      message: type == 0 ? '已取消收藏' : '已收藏 · $label');
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
                                    onSelected: (_) => setDialogState(() =>
                                        selected.contains(t)
                                            ? selected.remove(t)
                                            : selected.add(t)),
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
    // [my修复] 回写静态记忆 — 原实现从未写入 _rememberedTags, 标签记忆
    // 自上线起实际未生效 (切走再回/重建后标签丢失)
    _rememberedTags
      ..clear()
      ..addAll(selected);
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
