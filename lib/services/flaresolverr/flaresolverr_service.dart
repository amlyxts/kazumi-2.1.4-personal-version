// [my修改] FlareSolverr 客户端: 本地 CF 挑战求解服务 (无头浏览器渲染目标页,
// 返回过盾后的 HTML + cookies + UA)。
// 配置: 设置 → 网络 → FlareSolverr (地址留空 = 功能关闭)。
// 出口一致性: FlareSolverr 需与应用走同一代理出口 (配置代理地址指向 Clash),
// 否则求解得到的 cf_clearance 因 IP 不匹配对应用请求无效。
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/video_source/video_source_service.dart';

class FlareSolverrSolution {
  FlareSolverrSolution({
    required this.html,
    required this.cookies,
    required this.userAgent,
  });

  final String html;
  final List<Map<String, dynamic>> cookies;
  final String userAgent;

  String get cookieString =>
      cookies.map((c) => '${c['name']}=${c['value']}').join('; ');
}

class FlareSolverrService {
  FlareSolverrService._();

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: Duration(seconds: 10),
    receiveTimeout: Duration(seconds: 90),
  ));

  // 环境变量优先 (QA 无头驱动用), 其次应用设置。
  static String? get _baseUrl {
    final env = Platform.environment['KAZUMI_FLARESOLVERR_URL'];
    if (env != null && env.trim().isNotEmpty) {
      return env.trim().replaceAll(RegExp(r'/+$'), '');
    }
    final raw = GStorage.getSetting(SettingsKeys.flareSolverrUrl).trim();
    if (raw.isEmpty) return null;
    return raw.replaceAll(RegExp(r'/+$'), '');
  }

  static String? get _proxyUrl {
    final env = Platform.environment['KAZUMI_FLARESOLVERR_PROXY'];
    if (env != null && env.trim().isNotEmpty) return env.trim();
    final raw = GStorage.getSetting(SettingsKeys.flareSolverrProxy).trim();
    return raw.isEmpty ? null : raw;
  }

  static bool get isConfigured => _baseUrl != null;

  /// [my修改] 渲染播放页并提取主播放器正片直链 (质量取最高)。
  /// 该站页面为服务端渲染, 正片 mp4 直链写在 HTML 里; 页面上混有广告视频
  /// (动态注入), 嗅探会误抓 —— 直取直链从机制上规避广告。
  /// 返回 null = 未配置/求解失败/页面里没有正片直链 (调用方回退嗅探)。
  static Future<VideoSource?> resolveVideo(String url, {int offset = 0}) async {
    final solution = await solve(url);
    if (solution == null) return null;
    final html = solution.html;
    final pattern = RegExp(
        r'https://vdownload\.hembed\.com/[^\s"<>]+?-(\d{3,4})p\.mp4\?secure=[^\s"<>,]+');
    String? best;
    int bestQuality = -1;
    for (final m in pattern.allMatches(html)) {
      final quality = int.tryParse(m.group(1) ?? '') ?? 0;
      if (quality > bestQuality) {
        bestQuality = quality;
        best = m.group(0);
      }
    }
    if (best == null) {
      KazumiLogger().w('FlareSolverr: 播放页未解析出正片直链');
      return null;
    }
    KazumiLogger().i(
        'FlareSolverr: 正片直链 (${bestQuality}p) ${best.substring(0, best.indexOf('?secure='))}');
    return VideoSource(
      url: best,
      offset: offset,
      type: VideoSourceType.online,
    );
  }

  /// 交给 FlareSolverr 渲染目标页; 失败/未配置返回 null, 由调用方回退。
  static Future<FlareSolverrSolution?> solve(String url) async {
    final base = _baseUrl;
    if (base == null) return null;
    try {
      final proxyUrl = _proxyUrl;
      final resp = await _dio.post('$base/v1', data: {
        'cmd': 'request.get',
        'url': url,
        'maxTimeout': 60000,
        if (proxyUrl != null) 'proxy': {'url': proxyUrl},
      });
      final data = resp.data;
      if (data is! Map || data['status'] != 'ok') {
        KazumiLogger().w(
            'FlareSolverr: solve failed: ${data is Map ? data['message'] : 'bad response'}');
        return null;
      }
      final solution = data['solution'];
      if (solution is! Map || solution['response'] == null) {
        return null;
      }
      return FlareSolverrSolution(
        html: solution['response'].toString(),
        cookies: (solution['cookies'] as List? ?? [])
            .whereType<Map>()
            .map((c) => Map<String, dynamic>.from(c))
            .toList(),
        userAgent: (solution['userAgent'] ?? '').toString(),
      );
    } catch (e) {
      KazumiLogger().w('FlareSolverr: request error: $e');
      return null;
    }
  }
}
