import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

void main() {
  test('分区页卡片解析 (引擎同款)', () {
    final raw = File('C:/Users/liuxuan/Downloads/Kazumi-2.1.4/tools/hanime1_genre_rifan.html').readAsStringSync();
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
