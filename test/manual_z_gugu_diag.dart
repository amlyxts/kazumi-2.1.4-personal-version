// 一次性工具 (非 CI): gugu.fan 详情页章节 XPath 验证 — chapterRoads/chapterResult
// 在 Kazumi 同款解析链 (package:html + xpath_selector) 下的命中情况。
// 运行 (仓库根): ../tools/flutter3477/bin/flutter.bat test --no-pub test/manual_z_gugu_diag.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart';
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

Future<String> fetch(String url) async {
  final c = HttpClient();
  c.connectionTimeout = const Duration(seconds: 15);
  final req = await c.getUrl(Uri.parse(url));
  final res = await req.close().timeout(const Duration(seconds: 40));
  final body = await res.transform(const Utf8Decoder()).join();
  c.close();
  return body;
}

void main() {
  test('gugu UA 矩阵', () async {
    HttpOverrides.global = null;
    const uas = [
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36 Edg/141.0.0.0',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:125.0) Gecko/20100101 Firefox/125.0',
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.1',
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.1 Safari/605.1.15',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36 Edg/134.0.0.0',
    ];
    final c = HttpClient();
    c.connectionTimeout = const Duration(seconds: 15);
    for (var i = 0; i < uas.length; i++) {
      try {
        final req = await c.getUrl(Uri.parse(
            'https://gugu.fan/search?q=%E6%B5%B7%E8%B4%BC%E7%8E%8B'));
        req.headers.set('user-agent', uas[i]);
        final res = await req.close().timeout(const Duration(seconds: 30));
        final body = await res.transform(const Utf8Decoder()).join();
        final cards = 'search-result-card'.allMatches(body).length;
        // ignore: avoid_print
        print('UA#$i (${uas[i].contains('Safari') && !uas[i].contains('Chrome') ? 'Safari' : uas[i].contains('Firefox') ? 'Firefox' : 'Chrome系'}) '
            'len=${body.length} cards=$cards');
      } catch (e) {
        // ignore: avoid_print
        print('UA#$i ERROR ${e.toString().substring(0, 60)}');
      }
    }
    c.close();
  }, timeout: const Timeout(Duration(minutes: 8)));
}
