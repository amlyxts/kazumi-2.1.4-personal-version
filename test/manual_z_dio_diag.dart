// 一次性工具 (非 CI): gugu.fan dio 复现 — 与 pluginDio 同款头/配置, 记录
// 重定向历史与 body 特征, 定位引擎 200-但-0-结果 的真实响应。
// 运行 (仓库根): ../tools/flutter3477/bin/flutter.bat test --no-pub test/manual_z_dio_diag.dart
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('gugu dio probe', () async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 12),
      followRedirects: true,
      validateStatus: (s) => s != null && s >= 200 && s < 300,
      headers: {
        'user-agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36',
        'accept-language': 'zh-CN,zh;q=0.9',
      },
    ));
    for (var i = 0; i < 3; i++) {
      try {
        final res = await dio.get<String>(
            'https://gugu.fan/search?q=%E6%B5%B7%E8%B4%BC%E7%8E%8B');
        final body = res.data ?? '';
        final cards = 'search-result-card'.allMatches(body).length;
        final redirects = res.headers.value('dio-redirect') ?? '';
        // ignore: avoid_print
        print('try$i: ${res.statusCode} len=${body.length} cards=$cards '
            'uri=${res.realUri}');
        // ignore: avoid_print
        print('  redirected: ${res.realUri.toString() != res.requestOptions.uri.toString()}');
      } catch (e) {
        // ignore: avoid_print
        print('try$i: ERROR ${e.toString().substring(0, e.toString().length > 120 ? 120 : e.toString().length)}');
      }
    }
    dio.close();
  }, timeout: const Timeout(Duration(minutes: 5)));
}
