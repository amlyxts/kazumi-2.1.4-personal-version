import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

void main() {
  test('主页浏览卡片解析 (锚点直选模式)', () {
    // 测试 HTML 由探查流程生成 (外部资产), 路径经环境变量传入
    final path = Platform.environment['TEST_BROWSE_HTML'];
    if (path == null || path.isEmpty) {
      print('skip: 未设置 TEST_BROWSE_HTML (外部测试资产)');
      return;
    }
    final raw = File(path).readAsStringSync();
    final root = html_parser.parse(raw).documentElement!;
    final anchors = root.queryXPath(
        '//a[contains(@class,"video-link")][contains(@href,"watch?v=")]');
    var withThumb = 0;
    String? firstTitle;
    for (final node in anchors.nodes) {
      final t = node.queryXPath('.//div[contains(@class,"title")]').node;
      if ((t?.text ?? '').trim().isNotEmpty && firstTitle == null) {
        firstTitle = t!.text!.trim();
      }
      final thumbEl = node.queryXPath('.//img[contains(@class,"main-thumb")]').node;
      if ((thumbEl?.attributes['src'] ?? '').isNotEmpty) withThumb++;
    }
    print('锚点卡片: ${anchors.nodes.length} | 带封面: $withThumb | 首标题: $firstTitle');
    expect(anchors.nodes.length, greaterThan(50));
  });
}
