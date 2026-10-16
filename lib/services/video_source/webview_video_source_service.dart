import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/webview/video/video_webview_controller.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';
import 'package:kazumi/services/video_source/video_source_service.dart';

/// WebView 视频源解析服务
///
/// 使用 WebView 解析视频页面，提取视频源 URL。
/// WebView 实例在服务生命周期内复用，切换集数时调用 unloadPage 释放页面资源，
/// 仅在 [dispose] 时才真正销毁 WebView。
class WebViewVideoSourceService implements IVideoSourceService {
  VideoWebviewController? _webview;
  StreamSubscription? _logSubscription;

  // 单个服务实例持有一个 WebView，因此解析任务按实例串行执行。
  // 下载并行通过多个服务实例实现。
  Future<void>? _resolveTail = Future<void>.value();
  _ResolveRequest? _activeRequest;

  final StreamController<String> _logController =
      StreamController<String>.broadcast();
  Stream<String> get onLog => _logController.stream;

  // [my修改] 明文直链快路径: 部分站点 (MacCMS encrypt=0) 的播放页内嵌未加密的
  // 播放器配置/媒体 URL, 纯 dio 提取即可命中, 免去 WebView 加载+播放器执行 (5-10s)。
  // 提取失败的 host 记入本实例黑名单 (服务实例随播放/下载会话创建, 自然重置)。
  final Set<String> _directFailures = {};
  final Dio _directDio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 6),
    receiveTimeout: const Duration(seconds: 6),
    validateStatus: (s) => s != null && s < 400,
  ));

  static final RegExp _playerConfigRe =
      RegExp(r'player_aaaa\s*=\s*(\{[^}]*\})');
  /// 从播放页 HTML 提取明文媒体直链; 无把握一律返回 null 走 WebView
  Future<VideoSource?> _tryDirectResolve(String episodeUrl) async {
    final host = Uri.tryParse(episodeUrl)?.host ?? '';
    if (host.isEmpty || _directFailures.contains(host)) return null;
    String html;
    try {
      final r = await _directDio.get<String>(episodeUrl,
          options: Options(responseType: ResponseType.plain, headers: {
            'user-agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
          }));
      html = r.data ?? '';
    } catch (_) {
      _directFailures.add(host);
      return null;
    }
    String? mediaUrl;
    // 1. MacCMS 明文播放器配置 (encrypt 0: url 为明文 http 链接)
    final cfgMatch = _playerConfigRe.firstMatch(html);
    if (cfgMatch != null) {
      try {
        final cfg = jsonDecode(cfgMatch.group(1)!);
        if (cfg is Map) {
          final u = cfg['url']?.toString() ?? '';
          if (u.startsWith('http') &&
              (u.contains('.m3u8') || u.contains('.mp4'))) {
            mediaUrl = u;
          }
        }
      } catch (_) {}
    }
    if (mediaUrl == null ||
        !(mediaUrl.contains('.m3u8') || mediaUrl.contains('.mp4'))) {
      _directFailures.add(host);
      return null;
    }
    _logController.add(
        '[DirectResolve] 明文直链命中, 跳过 WebView: ${mediaUrl.substring(0, mediaUrl.length.clamp(0, 60))}');
    return VideoSource(
      url: mediaUrl,
      offset: 0,
      type: VideoSourceType.online,
      format:
          mediaUrl.contains('.m3u8') ? VideoSourceFormat.hls : VideoSourceFormat.auto,
    );
  }

  @override
  Future<VideoSource> resolve(
    String episodeUrl, {
    required bool useLegacyParser,
    int offset = 0,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final resolveTail = _resolveTail;
    if (resolveTail == null) {
      throw const VideoSourceCancelledException();
    }

    _activeRequest?.cancel();
    final request = _ResolveRequest();
    _activeRequest = request;

    final resolveFuture = resolveTail.then(
      (_) async {
        // [my修改] 快路径: 明文直链直接命中则免 WebView
        try {
          final direct = await _tryDirectResolve(episodeUrl)
              .timeout(const Duration(seconds: 8), onTimeout: () {
            final host = Uri.tryParse(episodeUrl)?.host ?? '';
            if (host.isNotEmpty) _directFailures.add(host);
            return null;
          });
          request.throwIfNotCurrent(_activeRequest);
          if (direct != null) return direct;
        } on VideoSourceCancelledException {
          rethrow;
        } catch (_) {}
        return _runResolve(
          request,
          episodeUrl,
          useLegacyParser: useLegacyParser,
          offset: offset,
          timeout: timeout,
        );
      },
    );

    _resolveTail = resolveFuture.then<void>((_) {}, onError: (_) {});
    return resolveFuture;
  }

  Future<VideoSource> _runResolve(
    _ResolveRequest request,
    String episodeUrl, {
    required bool useLegacyParser,
    required int offset,
    required Duration timeout,
  }) async {
    request.throwIfNotCurrent(_activeRequest);

    if (_webview == null) {
      _webview = VideoWebviewControllerFactory.getController();
      await _webview!.init();

      _logSubscription = _webview!.onLog.listen((log) {
        if (!_logController.isClosed) {
          _logController.add(log);
        }
      });
    }

    var didStartLoad = false;
    try {
      request.throwIfNotCurrent(_activeRequest);
      didStartLoad = true;
      await _webview!.loadUrl(
        episodeUrl,
        useLegacyParser,
        offset: offset,
      );

      request.throwIfNotCurrent(_activeRequest);

      final parserFuture = _webview!.onVideoURLParser.first.timeout(
        timeout,
        onTimeout: () {
          request.throwIfNotCurrent(_activeRequest);
          throw VideoSourceTimeoutException(timeout);
        },
      );
      final cancelFuture = request.cancelled.then<VideoParserEvent>((_) {
        throw const VideoSourceCancelledException();
      });
      final event = await Future.any([parserFuture, cancelFuture]);

      request.throwIfNotCurrent(_activeRequest);

      return VideoSource(
        url: event.url,
        offset: event.offset,
        type: VideoSourceType.online,
        format: event.format,
      );
    } catch (e) {
      if (e is VideoSourceCancelledException) {
        rethrow;
      }
      request.throwIfNotCurrent(_activeRequest);
      rethrow;
    } finally {
      if (didStartLoad) {
        await _webview?.unloadPage();
      }
      if (identical(_activeRequest, request)) {
        _activeRequest = null;
      }
    }
  }

  @override
  void cancel() {
    _activeRequest?.cancel();
  }

  @override
  Future<void> dispose() async {
    final resolveTail = _resolveTail;
    _resolveTail = null;
    cancel();
    await resolveTail;
    _activeRequest = null;
    await _logSubscription?.cancel();
    _logSubscription = null;
    if (!_logController.isClosed) {
      await _logController.close();
    }
    await _webview?.dispose();
    _webview = null;
  }
}

class _ResolveRequest {
  final Completer<void> _cancelled = Completer<void>();

  Future<void> get cancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) {
      _cancelled.complete();
    }
  }

  void throwIfNotCurrent(_ResolveRequest? current) {
    if (_cancelled.isCompleted || !identical(current, this)) {
      throw const VideoSourceCancelledException();
    }
  }
}
