// [my修改] FlareSolverr 客户端: 本地 CF 挑战求解服务 (无头浏览器渲染目标页,
// 返回过盾后的 HTML + cookies + UA)。
// 配置: 设置 → 网络 → FlareSolverr (地址留空 = 功能关闭)。
// 出口一致性: FlareSolverr 需与应用走同一代理出口 (配置代理地址指向 Clash),
// 否则求解得到的 cf_clearance 因 IP 不匹配对应用请求无效。
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';

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
