import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

void main() {
  test('分区页卡片解析 (引擎同款)', () {
    // 测试 HTML 由探查流程生成 (外部资产), 路径经环境变量传入
    final path = Platform.environment['TEST_GENRE_HTML'];
    if (path == null || path.isEmpty) {
      print('skip: 未设置 TEST_GENRE_HTML (外部测试资产)');
      return;
    }
    final raw = File(path).readAsStringSync();
    final root = html_parser.parse(raw).documentElement!;
    final anchors = root.queryXPath(
        '//a[contains(@class,"video-link")][contains(@href,"watch?v=")]');
    var named = 0;
    String? firstHref;
    for (final node in anchors.nodes) {
      final href = node.attributes['href'] ?? '';
      if (firstHref == null) firstHref = href;
      final t = node.queryXPath('.//div[contains(@class,"title")]').node;
      if ((t?.text ?? '').trim().isNotEmpty) named++;
    }
    print('锚点: ${anchors.nodes.length} | 带标题: $named | 首链: $firstHref');
    expect(anchors.nodes.length, greaterThan(10));
  });
}
