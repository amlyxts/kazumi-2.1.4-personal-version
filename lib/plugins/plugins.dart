import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/plugins/anti_crawler_config.dart';
import 'package:kazumi/plugins/api_rule_config.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/services/plugin/api_rule_engine.dart';
import 'package:kazumi/utils/episode_url.dart';
import 'package:dio/dio.dart';
import 'package:kazumi/services/flaresolverr/flaresolverr_service.dart';
import 'package:kazumi/request/core/network_exception.dart';
import 'package:kazumi/services/plugin/plugin_cookie_manager.dart';
import 'package:kazumi/utils/http_headers.dart';

export 'package:kazumi/services/plugin/rule_engine_models.dart'
    show
        CaptchaRequiredException,
        NoResultException,
        SearchErrorException,
        ChapterErrorException;

String pluginNameKey(String name) => name.toLowerCase();

class Plugin {
  static final RuleEngine _ruleEngine = RuleEngine();

  String api;
  String type;
  String name;
  String version;
  bool muliSources;

  /// Legacy schema field retained for rule import/export compatibility.
  bool useWebview;
  // [my修改] 解析走 FlareSolverr (服务端渲染页面直取正片直链, 规避嗅探误抓广告)
  bool resolveViaFlareSolverr;

  /// Legacy schema field retained for rule import/export compatibility.
  bool useNativePlayer;
  bool usePost;
  bool useLegacyParser;
  bool adBlocker;
  String userAgent;
  String baseUrl;
  String searchURL;
  String searchList;
  String searchName;
  String searchResult;
  String chapterRoads;
  String chapterResult;
  String referer;
  String searchMode;
  String chapterMode;
  ApiSearchConfig searchApiConfig;
  ApiChapterConfig chapterApiConfig;
  AntiCrawlerConfig antiCrawlerConfig;

  Plugin({
    required this.api,
    required this.type,
    required this.name,
    required this.version,
    required this.muliSources,
    required this.useWebview,
    this.resolveViaFlareSolverr = false,
    required this.useNativePlayer,
    required this.usePost,
    required this.useLegacyParser,
    required this.adBlocker,
    required this.userAgent,
    required this.baseUrl,
    required this.searchURL,
    required this.searchList,
    required this.searchName,
    required this.searchResult,
    required this.chapterRoads,
    required this.chapterResult,
    required this.referer,
    this.searchMode = RuleMode.xpath,
    this.chapterMode = RuleMode.xpath,
    ApiSearchConfig? searchApiConfig,
    ApiChapterConfig? chapterApiConfig,
    AntiCrawlerConfig? antiCrawlerConfig,
  })  : searchApiConfig = searchApiConfig ?? ApiSearchConfig(),
        chapterApiConfig = chapterApiConfig ?? ApiChapterConfig(),
        antiCrawlerConfig = antiCrawlerConfig ?? AntiCrawlerConfig.empty();

  factory Plugin.fromJson(Map<String, dynamic> json) {
    return Plugin(
      api: json['api']?.toString() ?? '1',
      type: json['type'] as String? ?? 'anime',
      name: json['name'] as String? ?? '',
      version: json['version']?.toString() ?? '',
      muliSources: json['muliSources'] as bool? ?? true,
      useWebview: json['useWebview'] as bool? ?? true,
      resolveViaFlareSolverr:
          json['resolveViaFlareSolverr'] as bool? ?? false,
      useNativePlayer: json['useNativePlayer'] as bool? ?? true,
      usePost: json['usePost'] ?? false,
      useLegacyParser: json['useLegacyParser'] ?? false,
      adBlocker: json['adBlocker'] ?? false,
      userAgent: json['userAgent'] as String? ?? '',
      baseUrl: json['baseURL'] as String? ?? '',
      searchURL: json['searchURL'] as String? ?? '',
      searchList: json['searchList'] as String? ?? '',
      searchName: json['searchName'] as String? ?? '',
      searchResult: json['searchResult'] as String? ?? '',
      chapterRoads: json['chapterRoads'] as String? ?? '',
      chapterResult: json['chapterResult'] as String? ?? '',
      referer: json['referer'] ?? '',
      searchMode: RuleMode.normalize(json['searchMode']),
      chapterMode: RuleMode.normalize(json['chapterMode']),
      searchApiConfig: json['searchApiConfig'] is Map
          ? ApiSearchConfig.fromJson(
              Map<String, dynamic>.from(json['searchApiConfig']),
            )
          : ApiSearchConfig(),
      chapterApiConfig: json['chapterApiConfig'] is Map
          ? ApiChapterConfig.fromJson(
              Map<String, dynamic>.from(json['chapterApiConfig']),
            )
          : ApiChapterConfig(),
      antiCrawlerConfig: json['antiCrawlerConfig'] != null
          ? AntiCrawlerConfig.fromJson(
              Map<String, dynamic>.from(json['antiCrawlerConfig']),
            )
          : AntiCrawlerConfig.empty(),
    );
  }

  factory Plugin.fromTemplate() {
    return Plugin(
      api: ApiEndpoints.apiLevel.toString(),
      type: 'anime',
      name: '',
      version: '',
      muliSources: true,
      useWebview: true,
      useNativePlayer: true,
      usePost: false,
      useLegacyParser: false,
      adBlocker: false,
      userAgent: '',
      baseUrl: '',
      searchURL: '',
      searchList: '',
      searchName: '',
      searchResult: '',
      chapterRoads: '',
      chapterResult: '',
      referer: '',
      searchMode: RuleMode.xpath,
      chapterMode: RuleMode.xpath,
      searchApiConfig: ApiSearchConfig(),
      chapterApiConfig: ApiChapterConfig(),
      antiCrawlerConfig: AntiCrawlerConfig.empty(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'api': api,
      'type': type,
      'name': name,
      'version': version,
      'muliSources': muliSources,
      'useWebview': useWebview,
      'resolveViaFlareSolverr': resolveViaFlareSolverr,
      'useNativePlayer': useNativePlayer,
      'usePost': usePost,
      'useLegacyParser': useLegacyParser,
      'adBlocker': adBlocker,
      'userAgent': userAgent,
      'baseURL': baseUrl,
      'searchURL': searchURL,
      'searchList': searchList,
      'searchName': searchName,
      'searchResult': searchResult,
      'chapterRoads': chapterRoads,
      'chapterResult': chapterResult,
      'referer': referer,
      'searchMode': searchMode,
      'chapterMode': chapterMode,
      // Persisting re-serializes the whole plugin list, so a configured API
      // rule must survive even while the mode points at XPath.
      if (searchMode == RuleMode.api || searchApiConfig.request.url.isNotEmpty)
        'searchApiConfig': searchApiConfig.toJson(),
      if (chapterMode == RuleMode.api ||
          chapterApiConfig.request.url.isNotEmpty)
        'chapterApiConfig': chapterApiConfig.toJson(),
      'antiCrawlerConfig': antiCrawlerConfig.toJson(),
    };
  }

  bool get usesApiSearch => searchMode == RuleMode.api;

  bool get requiresNewerClient => int.parse(api) > ApiEndpoints.apiLevel;

  RuleExecutionConfig get _executionConfig => RuleExecutionConfig(
        pluginName: name,
        baseUrl: baseUrl,
        usePost: usePost,
        searchMode: searchMode,
        chapterMode: chapterMode,
        searchUrl: searchURL,
        searchList: searchList,
        searchName: searchName,
        searchResult: searchResult,
        chapterRoads: chapterRoads,
        chapterResult: chapterResult,
        searchApiConfig: searchApiConfig,
        chapterApiConfig: chapterApiConfig,
        antiCrawlerConfig: antiCrawlerConfig,
      );

  Future<RuleSearchTrace> traceSearch(
    String keyword, {
    RuleCancelToken? cancelToken,
  }) {
    return _ruleEngine.search(
      _executionConfig,
      keyword,
      cancelToken: cancelToken,
    );
  }

  Future<RuleChapterTrace> traceChapters(
    String source, {
    RuleCancelToken? cancelToken,
  }) {
    return _ruleEngine.queryChapters(
      _executionConfig,
      source,
      cancelToken: cancelToken,
    );
  }

  /// Parses HTML harvested from the captcha webview as a search result;
  /// returns null when not applicable, letting callers fall back to
  /// [queryBangumi].
  PluginSearchResponse? parseHarvestedSearch(String html) {
    return _ruleEngine.tryParseHarvestedSearch(_executionConfig, html);
  }

  Future<PluginSearchResponse> queryBangumi(
    String keyword, {
    bool shouldRethrow = false,
    RuleCancelToken? cancelToken,
  }) async {
    try {
      return (await traceSearch(keyword, cancelToken: cancelToken)).response;
    } on CaptchaRequiredException {
      // [my修改] FlareSolverr 分流: 挑战页交给本地求解服务, 成功则播种凭证
      // 并直接出结果; 未配置/失败才回退验证码流程 (rethrow)。
      final solved = await querySearchViaFlareSolverr(keyword);
      if (solved != null) return solved;
      rethrow;
    } on SearchErrorException catch (error) {
      // [my修改] 被墙站直连必然连接超时 (无 403 响应体可检测):
      // FlareSolverr 已配置时同样分流, 由它的无头浏览器代取页面。
      if (_isSearchConnectionTimeout(error)) {
        final solved = await querySearchViaFlareSolverr(keyword);
        if (solved != null) return solved;
      }
      if (shouldRethrow) rethrow;
      return PluginSearchResponse(pluginName: name, data: <SearchItem>[]);
    }
  }

  /// [my修改] 经 FlareSolverr 渲染搜索页: 返回结果; 未配置/失败/解析不出返回
  /// null (调用方回退验证码流程)。顺带把过盾凭证与 UA 播种到凭证管理,
  /// 供后续 dio 请求使用。
  Future<PluginSearchResponse?> querySearchViaFlareSolverr(
      String keyword) async {
    if (!FlareSolverrService.isConfigured) return null;
    final url = buildSearchUrl(keyword);
    if (url == null) return null;
    final solution = await FlareSolverrService.solve(url);
    if (solution == null) return null;
    try {
      await PluginCookieManager.instance.saveFromWebView(
          name, url, solution.cookieString,
          userAgent: solution.userAgent);
    } catch (_) {}
    return parseHarvestedSearch(solution.html);
  }

  /// [my修改] 经 FlareSolverr 渲染播放页并解析线路; 返回 null = 未配置/失败。
  Future<List<Road>?> queryChaptersViaFlareSolverr(String source) async {
    if (!FlareSolverrService.isConfigured) return null;
    // [my提速] curl 快速通道优先 (~2s): CF 按 TLS 指纹拦 dart 栈,
    // Schannel 指纹可过, cookies 取过盾持久化。播放链路里取集与直链解析
    // 抓同一 watch 页, curlFetch 的短缓存让第二次抓取免网络。
    // 解析不出线路 (挑战页/cookies 失效) 再落 FS 求解 (同时刷新 cookies)。
    final curlHtml = await FlareSolverrService.curlFetch(source);
    if (curlHtml != null) {
      final roads = parseHarvestedRoads(curlHtml);
      if (roads != null && roads.isNotEmpty) return roads;
    }
    final solution = await FlareSolverrService.solve(source);
    if (solution == null) return null;
    try {
      await PluginCookieManager.instance.saveFromWebView(
          name, source, solution.cookieString,
          userAgent: solution.userAgent);
    } catch (_) {}
    return parseHarvestedRoads(solution.html);
  }

  /// [my修改] 渲染搜索 URL 而不发请求 (FlareSolverr 分流用)。
  String? buildSearchUrl(String keyword) {
    return _ruleEngine.buildSearchRequestUrl(_executionConfig, keyword);
  }

  /// [my修改] 从已取回的 HTML 解析播放线路 (FlareSolverr 分流用)。
  List<Road>? parseHarvestedRoads(String html) {
    return _ruleEngine.tryParseHarvestedRoads(_executionConfig, html);
  }

  Future<List<Road>> queryChapterRoads(
    String source, {
    RuleCancelToken? cancelToken,
  }) async {
    try {
      return (await traceChapters(source, cancelToken: cancelToken)).roads;
    } on CaptchaRequiredException {
      // [my修改] FlareSolverr 分流 (同搜索环节)
      final solved = await queryChaptersViaFlareSolverr(source);
      if (solved != null) return solved;
      rethrow;
    } on ChapterErrorException catch (error) {
      // [my修改] FlareSolverr 分流覆盖两种形态: 被墙站直连的连接超时,
      // 以及应用代理下 CF 对 dio 指纹的 403 拦截 (响应体含挑战标记)。
      final solved = _chaptersNeedsFlareSolverr(error)
          ? await queryChaptersViaFlareSolverr(source)
          : null;
      if (solved != null) return solved;
      rethrow;
    }
  }

  // [my修改] 章节取集是否应交给 FlareSolverr: 连接超时 (被墙直连) 或
  // 403 + 挑战标记 (CF 对 dio TLS 指纹的拦截)。
  bool _chaptersNeedsFlareSolverr(ChapterErrorException error) {
    final cause = error.cause;
    if (cause is! NetworkException) return false;
    if (cause.type == NetworkExceptionType.connectionTimeout) return true;
    if (cause.type == NetworkExceptionType.badResponse &&
        cause.statusCode == 403) {
      final raw = cause.rawError;
      final body =
          raw is DioException ? (raw.response?.data?.toString() ?? '') : '';
      return body.contains('challenge-platform') ||
          body.contains('Attention Required');
    }
    return false;
  }

  // [my修改] 连接超时判定 (被墙站直连的标志性失败形态)
  bool _isSearchConnectionTimeout(SearchErrorException error) {
    final cause = error.cause;
    return cause is NetworkException &&
        cause.type == NetworkExceptionType.connectionTimeout;
  }

  String buildFullUrl(String urlItem) {
    return normalizeEpisodeUrl(baseUrl, urlItem);
  }

  /// Headers used when resolving or downloading the final media resource.
  Map<String, String> buildHttpHeaders() {
    return {
      'user-agent': userAgent.isEmpty ? getRandomUA() : userAgent,
      if (referer.isNotEmpty) 'referer': referer,
    };
  }
}
