// 一次性工具 (非 CI): gugu.fan XPath 求值隔离诊断 — 验证 searchList 各写法
// 在 Kazumi 同款 xpath 包下的命中数。
// 运行 (仓库根): ../tools/flutter3477/bin/flutter.bat test --no-pub test/manual_z_xpath_diag.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart';
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

void main() {
  testWidgets('gugu xpath diag', (WidgetTester tester) async {
    HttpOverrides.global = null;
    String html = '';
    await tester.runAsync(() async {
      final c = HttpClient();
      c.connectionTimeout = const Duration(seconds: 15);
      final req = await c.getUrl(Uri.parse(
          'https://gugu.fan/search?q=%E6%B5%B7%E8%B4%BC%E7%8E%8B'));
      final res = await req.close().timeout(const Duration(seconds: 30));
      html = await res.transform(const Utf8Decoder()).join();
      c.close();
    });
    // ignore: avoid_print
    print('html len: ${html.length}');

    final doc = parse(html).documentElement!;
    final variants = {
      'contains类': "//article[contains(@class,'search-result-card')]",
      '精确类': "//article[@class='schedule-card search-result-card']",
      '纯article': '//article',
      'h2锚点': '//h2',
      'contains小写': "//article[contains(@class,'schedule-card')]",
    };
    for (final e in variants.entries) {
      try {
        final r = doc.queryXPath(e.value);
        // ignore: avoid_print
        print('${e.key}: ${r.nodes.length} 命中');
      } catch (err) {
        // ignore: avoid_print
        print('${e.key}: 异常 ${err.toString().substring(0, 80)}');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
