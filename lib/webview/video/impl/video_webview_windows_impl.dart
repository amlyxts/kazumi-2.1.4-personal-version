import 'dart:async';
import 'package:webview_windows/webview_windows.dart';
import 'package:kazumi/webview/video/video_webview_controller.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/network/proxy_utils.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';

class VideoWebviewWindowsImpl
    extends VideoWebviewController<WebviewController> {
  final List<StreamSubscription> subscriptions = [];

  HeadlessWebview? headlessWebview;

  // [my修改] 每次加载的全响应日志计数, 防止站点资源请求刷爆日志
  int _sourceLogCount = 0;

  @override
  Future<void> init() async {
    await _setupProxy();
    headlessWebview ??= HeadlessWebview();
    await headlessWebview!.run();
    await headlessWebview!.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
    // [my修改] 可见性伪装 + 自动播放: 解析 WebView 无头运行时页面可见性为
    // hidden, 部分站点播放器检查可见性会拒绝出流; 注入覆写让页面视为可见,
    // 并周期性播放页面中的 video 元素 (点击播放型站点的拟人化)。
    await headlessWebview!
        .addScriptToExecuteOnDocumentCreated(_visibilitySpoofScript);
    initEventController.add(true);
  }

  /// 注入每个文档创建时机的伪装+自动播放脚本
  static const String _visibilitySpoofScript = '''
(function() {
  if (window.__kazumiVisSpoof) return;
  window.__kazumiVisSpoof = true;
  try {
    Object.defineProperty(document, 'visibilityState', {
      get: function() { return 'visible'; },
      configurable: true
    });
    Object.defineProperty(document, 'hidden', {
      get: function() { return false; },
      configurable: true
    });
    document.hasFocus = function() { return true; };
  } catch (e) {}
  var n = 0;
  var t = setInterval(function() {
    n++;
    if (n > 60) { clearInterval(t); return; }
    var vids = document.querySelectorAll('video');
    for (var i = 0; i < vids.length; i++) {
      if (vids[i].paused) {
        try { vids[i].play(); } catch (e) {}
      }
    }
  }, 1000);
})();
''';

  Future<void> _setupProxy() async {
    final bool proxyEnable = GStorage.getSetting(SettingsKeys.proxyEnable);
    if (!proxyEnable) {
      // [my修改] 应用代理关闭时显式禁用 WebView2 的系统代理解析:
      // WebView2 (Edge) 默认遵循系统代理——代理软件 (Clash) 的出口访问部分
      // 国内源站会失败 (dm84.tv 实测: 直连 0.5s / 经 Clash 必挂), 导致解析超时。
      // --no-proxy-server 让解析 WebView 与 dio 的直连行为一致。
      try {
        await WebviewController.initializeEnvironment(
          additionalArguments: '--no-proxy-server',
        );
        KazumiLogger().i('WebView: 已禁用系统代理解析 (直连模式)');
      } catch (e) {
        KazumiLogger().e('WebView: 设置直连模式失败 $e');
      }
      return;
    }

    final String proxyUrl = GStorage.getSetting(SettingsKeys.proxyUrl);
    final formattedProxy = ProxyUtils.getFormattedProxyUrl(proxyUrl);
    if (formattedProxy == null) {
      return;
    }

    // [my修改] 源站域名绕过: 这些站直连可达且经代理出口反而失败
    // (dm84.tv 实测: 直连 0.5s / 经 Clash 必挂), 让 WebView 对源站直连
    const sourceBypass =
        '*.2kdm.com;*.dmbus.cc;*.dm84.tv;*.7sefun.top;*.moonci.com;*.lmm85.com;*.xifanacg.com;*.hhplayer.com;*.agedm.io;*.akianime.cc;*.baimaodm.com;*.cycani.org;*.ezdmw.org;*.gugu3.com;*.mgnacg.com;*.sorani.net;*.sbdl.cc;*.xfdm.pro;*.dcc3.com;*.omofun.in;*.skr2.cc';
    try {
      await WebviewController.initializeEnvironment(
        additionalArguments:
            '--proxy-server=$formattedProxy --proxy-bypass-list=$sourceBypass',
      );
      KazumiLogger().i('WebView: 代理设置成功 $formattedProxy (源站域已绕过)');
    } catch (e) {
      KazumiLogger().e('WebView: 设置代理失败 $e');
    }
  }

  @override
  Future<void> loadUrl(String url, bool useLegacyParser,
      {int offset = 0}) async {
    await unloadPage();
    count = 0;
    this.offset = offset;
    isIframeLoaded = false;
    isVideoSourceLoaded = false;
    _sourceLogCount = 0;
    videoLoadingEventController.add(true);
    // [my修改] 全响应日志: 解析超时/无出流时能看到 WebView 实际加载了什么
    // (含 iframe 内请求), 用于诊断站点播放器链路卡在哪一跳。
    subscriptions.add(headlessWebview!.onSourceLoaded.listen((data) {
      if (_sourceLogCount >= 80) return;
      _sourceLogCount++;
      final String url = data['url'] ?? '';
      if (url.isEmpty) return;
      final String contentType = data['contentType'] ?? '';
      logEventController.add('RES ${data['method'] ?? 'GET'} '
          '${contentType.isEmpty ? '-' : contentType} $url');
    }));
    subscriptions.add(headlessWebview!.onM3USourceLoaded.listen((data) {
      if (headlessWebview == null) return;
      String url = data['url'] ?? '';
      if (url.isEmpty) {
        return;
      }
      unloadPage();
      isIframeLoaded = true;
      isVideoSourceLoaded = true;
      videoLoadingEventController.add(false);
      logEventController.add('Loading m3u8 source: $url');
      notifyVideoSourceResolved(
        url,
        format: VideoSourceFormat.hls,
      );
    }));
    subscriptions.add(headlessWebview!.onVideoSourceLoaded.listen((data) {
      if (headlessWebview == null) return;
      String url = data['url'] ?? '';
      if (url.isEmpty) {
        return;
      }
      unloadPage();
      isIframeLoaded = true;
      isVideoSourceLoaded = true;
      videoLoadingEventController.add(false);
      logEventController.add('Loading video source: $url');
      notifyVideoSourceResolved(url);
    }));
    await headlessWebview!.loadUrl(url);
  }

  @override
  Future<void> unloadPage() async {
    for (final s in subscriptions) {
      try {
        s.cancel();
      } catch (_) {}
    }
    subscriptions.clear();
    await redirect2Blank();
  }

  @override
  Future<void> dispose() async {
    for (final s in subscriptions) {
      try {
        s.cancel();
      } catch (_) {}
    }
    subscriptions.clear();
    await headlessWebview?.dispose();
    headlessWebview = null;
    disposeEventControllers();
  }

  // The webview_windows package does not have a method to unload the current page.
  // The loadUrl method opens a new tab, which can lead to memory leaks.
  // Directly disposing of the webview controller would require reinitialization when switching episodes, which is costly.
  // Therefore, this method is used to redirect to a blank page instead.
  Future<void> redirect2Blank() async {
    if (headlessWebview == null) return;
    try {
      await headlessWebview!.executeScript('''
        window.location.href = 'about:blank';
      ''');
    } catch (e) {
      KazumiLogger().d('WebView: redirect2Blank skipped (likely disposed): $e');
    }
  }
}
