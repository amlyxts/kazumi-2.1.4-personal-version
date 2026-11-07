import 'dart:async';
import 'package:dio/dio.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/plugins/api_rule_config.dart';
import 'package:kazumi/request/clients/plugin_site_client.dart';
import 'package:kazumi/request/core/network_exception.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/plugin/api_rule_strategy.dart';
import 'package:kazumi/services/plugin/plugin_cookie_manager.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';
import 'package:kazumi/services/plugin/xpath_rule_strategy.dart';
import 'package:kazumi/services/plugin/webview_page_fetch_service.dart';
import 'package:kazumi/services/flaresolverr/flaresolverr_service.dart';

abstract interface class RuleRequestExecutor {
  Future<String> execute(
    PreparedRuleRequest request,
    RuleExecutionConfig config, {
    CancelToken? cancelToken,
  });
}

class RuleEngine {
  RuleEngine({
    RuleRequestExecutor? requestExecutor,
    ApiRuleStrategy apiStrategy = const ApiRuleStrategy(),
    XPathRuleStrategy xpathStrategy = const XPathRuleStrategy(),
    bool logFailures = true,
  })  : _requestExecutor =
            requestExecutor ?? ChallengeAwareRuleRequestExecutor(
                _DefaultRuleRequestExecutor()),
        _apiStrategy = apiStrategy,
        _xpathStrategy = xpathStrategy,
        _logFailures = logFailures;

  final RuleRequestExecutor _requestExecutor;
  final ApiRuleStrategy _apiStrategy;
  final XPathRuleStrategy _xpathStrategy;
  final bool _logFailures;

  Future<RuleSearchTrace> search(
    RuleExecutionConfig config,
    String keyword, {
    CancelToken? cancelToken,
  }) async {
    late final PreparedRuleRequest request;
    try {
      request = config.searchMode == RuleMode.api
          ? _apiStrategy.prepareRequest(
              config.searchApiConfig.request,
              <String, Object?>{'keyword': keyword},
            )
          : _xpathStrategy.prepareSearchRequest(config, keyword);
    } catch (error, stackTrace) {
      _logFailure(config, 'search request preparation', error, stackTrace);
      throw SearchErrorException(config.pluginName, cause: error);
    }

    late final String raw;
    try {
      raw = await _executeRequest(
        request,
        config,
        phase: 'search request',
        wrapError: (error) =>
            SearchErrorException(config.pluginName, cause: error),
        cancelToken: cancelToken,
      );
    } on SearchErrorException catch (error) {
      if (_isCaptchaChallengeResponse(error, config)) {
        throw CaptchaRequiredException(config.pluginName);
      }
      rethrow;
    }
    try {
      final parsed = config.searchMode == RuleMode.api
          ? _apiStrategy.parseSearch(raw, config.searchApiConfig)
          : _xpathStrategy.parseSearch(raw, config);
      // [my新增] 严格匹配过滤: 模糊站噪声治理 — 标题含关键词者优先保留;
      // 过滤后为空则回退全量 (模糊匹配或许是用户想要的变体, 永不更差)。
      var items = parsed.items;
      final kw = keyword.trim();
      if (config.strictSearchMatch && kw.isNotEmpty && items.length > 1) {
        final matched =
            items.where((e) => e.name.contains(kw)).toList();
        // 严格语义: 全无命中 = 该站确无此内容 (模糊站无结果时灌推荐位),
        // 直接 NoResult; 有命中但非全部 → 只留命中。
        KazumiLogger().i(
            '严格匹配: ${config.pluginName} ${items.length} → ${matched.length} 条');
        items = matched;
      }
      if (items.isEmpty) {
        throw NoResultException(config.pluginName);
      }
      _logDiagnostics(config, 'search', parsed.diagnostics);
      return RuleSearchTrace(
        rawResponse: raw,
        response: PluginSearchResponse(
          pluginName: config.pluginName,
          data: items,
        ),
        matchedFragments: parsed.matchedFragments,
        diagnostics: parsed.diagnostics,
      );
    } on CaptchaRequiredException {
      rethrow;
    } on NoResultException {
      rethrow;
    } catch (error, stackTrace) {
      if (_isCancellation(error)) rethrow;
      _logFailure(config, 'search response parsing', error, stackTrace);
      throw SearchErrorException(config.pluginName, cause: error);
    }
  }

  /// [my修改] 渲染搜索 URL 而不发请求 (FlareSolverr 分流取页面用)。
  /// API/POST 模式返回 null (其响应结构与 GET+XPath 不同)。
  String? buildSearchRequestUrl(RuleExecutionConfig config, String keyword) {
    try {
      if (config.searchMode == RuleMode.api || config.usePost) return null;
      final request = _xpathStrategy.prepareSearchRequest(config, keyword);
      return request.method == 'GET' ? request.url : null;
    } catch (_) {
      return null;
    }
  }

  /// [my修改] 从已取回的 HTML 解析播放线路 (FlareSolverr 分流用)。
  /// 语义与 tryParseHarvestedSearch 一致: 不适用/解析不出线路时返回 null。
  List<Road>? tryParseHarvestedRoads(RuleExecutionConfig config, String raw) {
    if (raw.trim().isEmpty) return null;
    if (config.chapterMode == RuleMode.api) return null;
    try {
      final parsed = _xpathStrategy.parseChapters(raw, config);
      if (parsed.roads.isEmpty) return null;
      _logDiagnostics(config, 'harvested chapters', parsed.diagnostics);
      return parsed.roads;
    } catch (error) {
      if (_logFailures) {
        KazumiLogger().i(
          'Plugin: ${config.pluginName} harvested page not parseable as '
          'chapters, falling back ($error)',
        );
      }
      return null;
    }
  }

  /// Parses HTML harvested from the captcha webview as a search result,
  /// skipping one network round trip after verification. Returns null when
  /// not applicable (API/POST rules) or when the page does not parse into
  /// results (still a challenge page, redirect page, or empty list) — the
  /// caller then falls back to a regular re-search.
  PluginSearchResponse? tryParseHarvestedSearch(
    RuleExecutionConfig config,
    String raw,
  ) {
    if (raw.trim().isEmpty) return null;
    // The webview loads the search URL with GET; API-mode and POST-mode
    // rules may render a different page than the real search response.
    if (config.searchMode == RuleMode.api || config.usePost) return null;
    try {
      final parsed = _xpathStrategy.parseSearch(raw, config);
      if (parsed.items.isEmpty) return null;
      _logDiagnostics(config, 'harvested search', parsed.diagnostics);
      return PluginSearchResponse(
        pluginName: config.pluginName,
        data: parsed.items,
      );
    } catch (error) {
      if (_logFailures) {
        KazumiLogger().i(
          'Plugin: ${config.pluginName} harvested page not parseable, '
          'falling back to re-search ($error)',
        );
      }
      return null;
    }
  }

  Future<RuleChapterTrace> queryChapters(
    RuleExecutionConfig config,
    String source, {
    CancelToken? cancelToken,
  }) async {
    late final PreparedRuleRequest request;
    try {
      request = config.chapterMode == RuleMode.api
          ? _apiStrategy.prepareRequest(
              config.chapterApiConfig.request,
              <String, Object?>{'source': source},
            )
          : _xpathStrategy.prepareChapterRequest(config, source);
    } catch (error, stackTrace) {
      _logFailure(config, 'chapter request preparation', error, stackTrace);
      throw ChapterErrorException(config.pluginName, cause: error);
    }

    final raw = await _executeRequest(
      request,
      config,
      phase: 'chapter request',
      wrapError: (error) =>
          ChapterErrorException(config.pluginName, cause: error),
      cancelToken: cancelToken,
    );
    try {
      final parsed = config.chapterMode == RuleMode.api
          ? _apiStrategy.parseChapters(
              raw,
              config.chapterApiConfig,
              source: source,
              baseUrl: config.baseUrl,
            )
          : _xpathStrategy.parseChapters(raw, config);
      if (parsed.roads.isEmpty) {
        throw ChapterErrorException(config.pluginName);
      }
      _logDiagnostics(config, 'chapter', parsed.diagnostics);
      return RuleChapterTrace(
        rawResponse: raw,
        roads: parsed.roads,
        diagnostics: parsed.diagnostics,
      );
    } on ChapterErrorException {
      rethrow;
    } catch (error, stackTrace) {
      if (_isCancellation(error)) rethrow;
      _logFailure(config, 'chapter response parsing', error, stackTrace);
      throw ChapterErrorException(config.pluginName, cause: error);
    }
  }

  Future<String> _executeRequest(
    PreparedRuleRequest request,
    RuleExecutionConfig config, {
    required String phase,
    required Object Function(Object error) wrapError,
    CancelToken? cancelToken,
  }) async {
    try {
      return await _requestExecutor.execute(
        request,
        config,
        cancelToken: cancelToken,
      );
    } catch (error, stackTrace) {
      if (_isCancellation(error)) rethrow;
      _logFailure(config, phase, error, stackTrace);
      throw wrapError(error);
    }
  }

  bool _isCancellation(Object error) {
    return error is NetworkException &&
        error.type == NetworkExceptionType.cancel;
  }

  /// Checks whether a failed XPath search request actually returned an
  /// anti-crawler challenge page.
  ///
  /// Dio rejects non-2xx responses before [XPathRuleStrategy.parseSearch]
  /// gets a chance to inspect the response body. Protected sites commonly
  /// return challenge HTML with HTTP 403/429/503, so reuse the configured
  /// captcha detector against the preserved Dio response body and hand the
  /// request over to the existing captcha flow when it matches.
  bool _isCaptchaChallengeResponse(
    SearchErrorException error,
    RuleExecutionConfig config,
  ) {
    if (config.searchMode != RuleMode.xpath ||
        !config.antiCrawlerConfig.enabled) {
      return false;
    }

    final cause = error.cause;
    if (cause is! NetworkException ||
        cause.type != NetworkExceptionType.badResponse) {
      return false;
    }

    final rawError = cause.rawError;
    if (rawError is! DioException) return false;

    final response = rawError.response;

    // Cloudflare marks managed challenge responses with this header.
    // This is useful when the body is empty, compressed unexpectedly, or
    // otherwise unavailable to Dio on a specific platform.
    final cfMitigated = response?.headers.value('cf-mitigated');
    if (cfMitigated?.toLowerCase() == 'challenge') {
      return true;
    }

    final data = response?.data;
    final raw = data is String ? data : data?.toString() ?? '';
    if (raw.trim().isEmpty) return false;

    try {
      return _xpathStrategy.detectsCaptchaChallenge(
        raw,
        config.antiCrawlerConfig,
      );
    } catch (detectError, stackTrace) {
      _logFailure(
        config,
        'failed response captcha detection',
        detectError,
        stackTrace,
      );
      return false;
    }
  }

  /// Surfaces partially-skipped nodes so incomplete results are traceable
  /// from logs even when the rule succeeds overall.
  void _logDiagnostics(
    RuleExecutionConfig config,
    String phase,
    List<String> diagnostics,
  ) {
    if (!_logFailures || diagnostics.isEmpty) return;
    final preview = diagnostics.take(3).join('; ');
    KazumiLogger().w(
      'Plugin: ${config.pluginName} $phase skipped ${diagnostics.length} '
      'node(s): $preview',
    );
  }

  void _logFailure(
    RuleExecutionConfig config,
    String phase,
    Object error,
    StackTrace stackTrace,
  ) {
    if (!_logFailures) return;
    KazumiLogger().w(
      'Plugin: ${config.pluginName} $phase failed',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

/// [my新增] 取页兜底双通道全失败 (WebView 不可用 + FlareSolverr 不可用)。
class ChallengeFetchException implements Exception {
  const ChallengeFetchException(this.message);
  final String message;
  @override
  String toString() => 'ChallengeFetchException: $message';
}

/// [my新增] 可注入的挑战取页通道 (单测替换用)。
typedef WebviewHtmlFetcher = Future<String> Function(String url);
typedef FlareSolverrHtmlSolver = Future<String> Function(String url);

/// [my新增] 挑战感知执行器: 包裹默认执行器。规则带 webviewFetch 时,
/// 直连异常或响应命中挑战体 (CF/雷池/JS 壳) → 隐藏 WebView 取页
/// (3-8s, 挑战自解) → FlareSolverr 兜底 (20-40s) → 双失败抛
/// [ChallengeFetchException] (由引擎按阶段包装成搜索/取集错误)。
/// per-host 记忆: 该站直连已确认被挑战后, 后续请求跳过直连直走 WebView。
/// 不带标志的规则零行为变化 (直通)。
class ChallengeAwareRuleRequestExecutor implements RuleRequestExecutor {
  ChallengeAwareRuleRequestExecutor(
    this._inner, {
    WebviewHtmlFetcher? webviewFetcher,
    FlareSolverrHtmlSolver? flareSolverrSolver,
  })  : _webviewFetcher = webviewFetcher ??
            ((url) => WebviewPageFetchService.instance.fetchHtml(url)),
        _flareSolverrSolver = flareSolverrSolver ?? _solveViaFlareSolverr;

  final RuleRequestExecutor _inner;
  final WebviewHtmlFetcher _webviewFetcher;
  final FlareSolverrHtmlSolver _flareSolverrSolver;

  /// 会话内 per-host 记忆 (仅被带标志的规则写入)
  static final Map<String, bool> _hostNeedsFetch = {};

  /// [双层记忆] WebView 对该 host 无效 (如 CF 托管挑战在 WebView2 内不自解):
  /// 后续请求跳过 WebView 直走 FlareSolverr, 免去每次 15s 等待。
  static final Set<String> _hostWebviewBroken = {};

  static Future<String> _solveViaFlareSolverr(String url) async {
    final solution = await FlareSolverrService.solve(url);
    final html = solution?.html ?? '';
    if (html.isEmpty) {
      throw Exception('FlareSolverr 返回空页面');
    }
    return html;
  }

  @override
  Future<String> execute(
    PreparedRuleRequest request,
    RuleExecutionConfig config, {
    CancelToken? cancelToken,
  }) async {
    if (!config.webviewFetch) {
      return _inner.execute(request, config, cancelToken: cancelToken);
    }
    final host = Uri.tryParse(request.url)?.host ?? '';
    if (!(_hostNeedsFetch[host] ?? false)) {
      try {
        final raw =
            await _inner.execute(request, config, cancelToken: cancelToken);
        if (!FlareSolverrService.isChallengeBody(raw)) {
          return raw;
        }
        KazumiLogger().i(
            '挑战回退: ${config.pluginName} 直连命中挑战体 → 隐藏 WebView 取页');
      } catch (directError) {
        if (cancelToken?.isCancelled ?? false) rethrow;
        final msg = directError.toString();
        KazumiLogger().i(
            '挑战回退: ${config.pluginName} 直连异常 → 隐藏 WebView 取页 (${msg.substring(0, msg.length > 80 ? 80 : msg.length)})');
      }
    } else {
      KazumiLogger()
          .d('挑战回退: ${config.pluginName} 命中 per-host 记忆, 跳过直连');
    }
    _hostNeedsFetch[host] = true;
    final webviewBroken = _hostWebviewBroken.contains(host);
    if (webviewBroken) {
      KazumiLogger()
          .d('挑战回退: ${config.pluginName} WebView 已标记失效, 直走 FlareSolverr');
    }
    if (!webviewBroken) {
      try {
        return await _webviewFetcher(request.url);
      } on TimeoutException {
        _hostWebviewBroken.add(host);
        KazumiLogger().w(
            '挑战回退: ${config.pluginName} WebView 挑战自解超时, 标记失效 → FlareSolverr');
      } catch (webviewError) {
        KazumiLogger().w(
            '挑战回退: ${config.pluginName} WebView 取页失败 → FlareSolverr 兜底 ($webviewError)');
        try {
          return await _flareSolverrSolver(request.url);
        } catch (fsError) {
          throw ChallengeFetchException(
              'WebView 与 FlareSolverr 取页均失败 (webview: $webviewError | fs: $fsError)');
        }
      }
    }
    try {
      return await _flareSolverrSolver(request.url);
    } catch (fsError) {
      throw ChallengeFetchException('FlareSolverr 兜底失败: $fsError');
    }
  }
}

class _DefaultRuleRequestExecutor implements RuleRequestExecutor {
  @override
  Future<String> execute(
    PreparedRuleRequest request,
    RuleExecutionConfig config, {
    CancelToken? cancelToken,
  }) async {
    final cookieHeader = request.includeCookies
        ? await _cookieHeaderFor(config.pluginName, request.url)
        : '';
    final verifiedUserAgent = cookieHeader.isNotEmpty
        ? PluginCookieManager.instance.userAgentFor(config.pluginName)
        : null;
    // Header names are lowercased so a rule-supplied 'User-Agent' collides
    // with ours instead of being sent as a second, conflicting header.
    final headers = <String, dynamic>{
      'referer': '${config.baseUrl}/',
      if (cookieHeader.isNotEmpty) 'cookie': cookieHeader,
      for (final entry in request.headers.entries)
        entry.key.toLowerCase(): entry.value,
      // Clearance cookies are bound to the User-Agent they were issued to,
      // so the verified UA overrides the rule's own; sending a different one
      // would make the site serve the challenge page again.
      if (verifiedUserAgent != null) 'user-agent': verifiedUserAgent,
    };
    if (request.method == 'POST') {
      switch (request.bodyType) {
        case ApiBodyType.json:
          headers.putIfAbsent('content-type', () => 'application/json');
          break;
        case ApiBodyType.form:
          headers.putIfAbsent(
            'content-type',
            () => 'application/x-www-form-urlencoded',
          );
          break;
      }
    }
    return PluginSiteClient.instance.requestText(
      request.url,
      method: request.method,
      headers: headers,
      queryParameters: request.query,
      data: request.method == 'POST' ? request.body : null,
      cancelToken: cancelToken,
    );
  }

  Future<String> _cookieHeaderFor(String pluginName, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return '';
    try {
      final cookies =
          await PluginCookieManager.instance.loadForRequest(pluginName, uri);
      return cookies
          .map((cookie) => '${cookie.name}=${cookie.value}')
          .join('; ');
    } catch (_) {
      return '';
    }
  }
}
