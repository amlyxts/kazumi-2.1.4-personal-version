import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:kazumi/services/flaresolverr/flaresolverr_service.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/http_headers.dart';
import 'package:webview_windows/webview_windows.dart';

/// [my新增] 隐藏 WebView 页面取回服务 — 规则引擎「挑战回退」链的主力通道。
///
/// 直连命中挑战 (CF / 雷池 WAF / JS 渲染壳) 时, 用真实浏览器内核取页:
/// 挑战在 WebView 内自动求解 (实测 3-8s), cookie 留存在 WebView 会话内,
/// 同站后续取页走快速通道 (1-3s)。WebView 不可用 (Linux / 运行时缺失)
/// 时抛异常, 由调用方兜底 FlareSolverr。
///
/// 平台: Windows = webview_windows HeadlessWebview (captcha/视频解析同款
/// 模式); Android/iOS/macOS = flutter_inappwebview 平台接口 Headless
/// (源直连 captcha 流同款模式); Linux 未支持。
/// 单实例常驻 (挑战只需解一次), 取页串行化。
class WebviewPageFetchService {
  WebviewPageFetchService._();

  static final WebviewPageFetchService instance = WebviewPageFetchService._();

  Future<void>? _tail = Future<void>.value();
  PlatformHeadlessInAppWebView? _mobileWebview;
  HeadlessWebview? _windowsWebview;
  bool _windowsEnvReady = false;

  bool get _supported =>
      Platform.isWindows ||
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS;

  /// 取回页面 HTML; 挑战页会轮询等待自解, 超时抛 [TimeoutException]。
  Future<String> fetchHtml(
    String url, {
    Duration timeout = const Duration(seconds: 15),
  }) {
    final task = _tail!.then((_) => _fetchHtml(url, timeout));
    _tail = task.then<void>((_) {}, onError: (_) {});
    return task;
  }

  Future<String> _fetchHtml(String url, Duration timeout) async {
    if (!_supported) {
      throw UnsupportedError('WebviewPageFetchService: 当前平台不支持隐藏取页');
    }
    KazumiLogger().i('WebviewFetch: 取页 $url');
    final deadline = DateTime.now().add(timeout);
    try {
      final html = Platform.isWindows
          ? await _fetchWindows(url, deadline)
          : await _fetchMobile(url, deadline);
      KazumiLogger().i('WebviewFetch: 成功 len=${html.length}');
      return html;
    } catch (e) {
      KazumiLogger().w('WebviewFetch: 失败 $url: $e');
      rethrow;
    }
  }

  // ===== Windows (webview_windows HeadlessWebview) =====

  Future<String> _fetchWindows(String url, DateTime deadline) async {
    final wv = _windowsWebview ??= await _initWindows();
    await wv.loadUrl(url);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final html = await _windowsHtml(wv);
      if (html.isNotEmpty && !FlareSolverrService.isChallengeBody(html)) {
        return html;
      }
    }
    throw TimeoutException('WebviewFetch: 挑战未在时限内自解 (Windows)');
  }

  Future<HeadlessWebview> _initWindows() async {
    // 环境初始化幂等容错 (视频解析链可能已初始化过)
    if (!_windowsEnvReady) {
      try {
        await WebviewController.initializeEnvironment();
      } catch (_) {}
      _windowsEnvReady = true;
    }
    final wv = HeadlessWebview();
    await wv.run();
    await wv.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
    return wv;
  }

  Future<String> _windowsHtml(HeadlessWebview wv) async {
    try {
      // complete 才采集; interactive 但 DOM 已大于 20KB 也放行 (防死页)
      final r = await wv.executeScript(
          "document.readyState === 'complete' || "
          "(document.readyState === 'interactive' && "
          "document.body && document.body.innerHTML.length > 20000) "
          "? document.documentElement.outerHTML : '';");
      final s = r?.toString() ?? '';
      // webview_windows 返回 JSON 编码的字符串值, 防御性解包
      if (s.length > 1 && s.codeUnitAt(0) == 0x22) {
        try {
          return jsonDecode(s) as String? ?? s;
        } catch (_) {
          return s;
        }
      }
      return s;
    } catch (_) {
      return '';
    }
  }

  // ===== Android / iOS / macOS (flutter_inappwebview 平台接口) =====

  Future<String> _fetchMobile(String url, DateTime deadline) async {
    final wv = _mobileWebview ??= await _initMobile();
    final c = wv.webViewController;
    if (c == null) {
      throw StateError('WebviewFetch: headless controller 缺失');
    }
    await c.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final html = await _mobileHtml(c);
      if (html.isNotEmpty && !FlareSolverrService.isChallengeBody(html)) {
        return html;
      }
    }
    throw TimeoutException('WebviewFetch: 挑战未在时限内自解 (移动端)');
  }

  Future<PlatformHeadlessInAppWebView> _initMobile() async {
    final wv = PlatformHeadlessInAppWebView(
      PlatformHeadlessInAppWebViewCreationParams(
        initialSettings: InAppWebViewSettings(
          userAgent: getRandomUA(),
          cacheEnabled: true,
          // 取 HTML 不需要图片渲染; 脚本 (挑战求解) 必须放行
          blockNetworkImage: true,
          loadsImagesAutomatically: false,
          transparentBackground: true,
        ),
      ),
    );
    await wv.run();
    return wv;
  }

  Future<String> _mobileHtml(PlatformInAppWebViewController c) async {
    try {
      final r = await c.evaluateJavascript(
          source:
              "document.readyState === 'complete' || "
              "(document.readyState === 'interactive' && "
              "document.body && document.body.innerHTML.length > 20000) "
              "? document.documentElement.outerHTML : '';");
      return r?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }

  Future<void> dispose() async {
    try {
      await _mobileWebview?.dispose();
    } catch (_) {}
    _mobileWebview = null;
    try {
      await _windowsWebview?.dispose();
    } catch (_) {}
    _windowsWebview = null;
    _tail = Future<void>.value();
  }
}
