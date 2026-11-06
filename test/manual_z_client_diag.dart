// 一次性工具 (非 CI): gugu.fan 引擎链路复现 — 用执行器同款 PluginSiteClient
// requestText (含 NetworkConfig 适配器/随机头), 对照裸 HttpClient。
// 运行 (仓库根): ../tools/flutter3477/bin/flutter.bat test --no-pub test/manual_z_client_diag.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/request/clients/plugin_site_client.dart';
import 'package:hive_ce_flutter/hive_flutter.dart' as hive_flutter;
import 'package:kazumi/services/storage/storage.dart';
import 'package:html/parser.dart';
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

Future<String> bareFetch(String url) async {
  final c = HttpClient();
  c.connectionTimeout = const Duration(seconds: 15);
  final req = await c.getUrl(Uri.parse(url));
  final res = await req.close().timeout(const Duration(seconds: 30));
  final body = await res.transform(const Utf8Decoder()).join();
  c.close();
  return body;
}

void main() {
  testWidgets('gugu client-chain diag', (WidgetTester tester) async {
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      return r'C:\Users\liuxuan\AppData\Roaming\com.example\kazumi';
    });
    const connChannel =
        MethodChannel('dev.fluttercommunity.plus/connectivity');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(connChannel, (call) async {
      return ['wifi'];
    });
    HttpOverrides.global = null;

    const url = 'https://gugu.fan/search?q=%E6%B5%B7%E8%B4%BC%E7%8E%8B';

    await tester.runAsync(() async {
      final staging = Directory.systemTemp.createTempSync('kazumi-gugu-');
      final srcHive = Directory(
          r'C:\Users\liuxuan\AppData\Roaming\com.example\kazumi\hive');
      final dstHive = Directory('${staging.path}/hive');
      await dstHive.create(recursive: true);
      await for (final f in srcHive.list()) {
        if (f is File && !f.path.endsWith('.lock')) {
          await f.copy('${dstHive.path}/${f.uri.pathSegments.last}');
        }
      }
      hive_flutter.Hive.init(dstHive.path);
      await GStorage.init();

      // 执行器同款调用 (referer 由引擎强制附加)
      try {
        final raw = await PluginSiteClient.instance.requestText(
          url,
          method: 'GET',
          headers: {'referer': 'https://gugu.fan/'},
        );
        final cards = 'search-result-card'.allMatches(raw).length;
        // ignore: avoid_print
        print('requestText: len=${raw.length} cards=$cards');
      } catch (e) {
        // ignore: avoid_print
        print('requestText ERROR: ${e.toString().substring(0, 120)}');
      }

      // 裸 HttpClient 对照
      final bare = await bareFetch(url);
      // ignore: avoid_print
      print('bare: len=${bare.length} '
          'cards=${'search-result-card'.allMatches(bare).length}');

      // 相对轴验证: searchList 条目上的 searchName/searchResult 求值
      final root = parse(bare).documentElement!;
      final items =
          root.queryXPath("//article[contains(@class,'search-result-card')]").nodes;
      // ignore: avoid_print
      print('searchList 命中: ${items.length}');
      if (items.isNotEmpty) {
        final n = items.first;
        for (final expr in ['.//h2', 'h2', './h2', './/h2/a', 'descendant::h2']) {
          try {
            final r = n.queryXPath(expr).nodes;
            // ignore: avoid_print
            print('  searchName[$expr] -> ${r.length}');
          } catch (e) {
            // ignore: avoid_print
            print('  searchName[$expr] -> 异常 ${e.toString().substring(0, 50)}');
          }
        }
      }
    });
  }, timeout: const Timeout(Duration(minutes: 5)));
}
