import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

void main() {
  test('FS HTML 解析验证 (引擎同款构造)', () {
    // 测试 HTML 由探查流程生成 (外部资产), 路径经环境变量传入
    final path = Platform.environment['TEST_FS_HTML'];
    if (path == null || path.isEmpty) {
      print('skip: 未设置 TEST_FS_HTML (外部测试资产)');
      return;
    }
    final raw = File(path).readAsStringSync();
    final root = html_parser.parse(raw).documentElement!;
    final items = root.queryXPath('//a[contains(@class,"video-link")][contains(@href,"watch?v=")]');
    print('双谓词 searchList 命中: ${items.nodes.length}');
    final items2 = root.queryXPath('//a[contains(@class,"video-link")]');
    print('单谓词命中: ${items2.nodes.length}');
    for (final it in items.nodes.take(3)) {
      final element = it.node as html_dom.Element;
      final nameNode = element.queryXPath('./div[contains(@class,"title")]').node;
      final name = nameNode?.text?.trim() ?? '?';
      print('  名称: ${name.substring(0, name.length.clamp(0, 30))} | href: ${element.attributes["href"]}');
    }
    expect(items.nodes.length, greaterThan(10));
  });
}
