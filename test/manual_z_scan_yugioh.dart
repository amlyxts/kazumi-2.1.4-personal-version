// 一次性工具 (非 CI): 游戏王专项源扫描 — 在 16 个体检通过的新源里
// 找「游戏王」系列内容, 输出每源搜索命中标题 + 章节数。
// ⚠ 环境: tester.runAsync 包真实 IO; HttpOverrides=null 恢复真实网络;
// path_provider/connectivity mock; GStorage 沙盒副本。
// 运行 (仓库根):
//   ../tools/flutter3477/bin/flutter.bat test --no-pub test/manual_z_scan_yugioh.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/plugin/rule_engine.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';
import 'package:hive_ce_flutter/hive_flutter.dart' as hive_flutter;
import 'package:kazumi/services/storage/storage.dart';

void mark(String msg) {
  File(r'C:\Users\liuxuan\Downloads\Kazumi-2.1.4\镜像隧道\scan_yugioh.log')
      .writeAsStringSync('[${DateTime.now().toIso8601String()}] $msg\n',
          mode: FileMode.append, flush: true);
}

// 关键词可用环境变量 KAZUMI_SCAN_KW 覆盖 (flutter test 继承父进程 env)
final title = Platform.environment['KAZUMI_SCAN_KW'] ?? '游戏王';
// 16 个体检通过源 (新源批量体检报告_20261107.md), 大库优先
final candidates = (Platform.environment['KAZUMI_SCAN_SOURCES'] ?? '')
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList()..addAll((Platform.environment['KAZUMI_SCAN_SOURCES'] ?? '').isEmpty
        ? ['xigua', 'fcdm', '9ciyuan', 'gpjda', 'yishijie', 'TvTFun',
           'FQDM', 'Fantuan', 'LMM', 'WYDM', 'anime7', 'ant', 'dmghg',
           'milimili', 'omofun', 'skr']
        : const []);

void main() {
  testWidgets('关键词专项扫描 (16 新源)', (WidgetTester tester) async {
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

    final results = <String>[];
    var hit = 0;

    await tester.runAsync(() async {
      final staging = Directory.systemTemp.createTempSync('kazumi-kwsan-');
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
      mark('GStorage 就绪');

      final rulesDir = Directory(r'C:\Users\liuxuan\Downloads\Kazumi-2.1.4\repo_rules');
      for (final name in candidates) {
        final f = File('${rulesDir.path}/$name.json');
        if (!f.existsSync()) {
          results.add('$name: 规则文件缺失');
          continue;
        }
        Map<String, dynamic> rule;
        try {
          rule = Map<String, dynamic>.from(
              jsonDecode(f.readAsStringSync()) as Map);
        } catch (_) {
          results.add('$name: 规则解析失败');
          continue;
        }
        final plugin = Plugin.fromJson(rule);
        final buf = StringBuffer('$name');
        try {
          final trace = await plugin
              .traceSearch(title)
              .timeout(const Duration(seconds: 20));
          final data = trace.response.data;
          if (data.isEmpty) {
            buf.write(' → 搜索0条');
            results.add(buf.toString());
            mark('[kwsan] $name: 搜索0条');
            continue;
          }
          // 命中标题采样 (最多 5 条)
          final names =
              data.take(5).map((e) => e.name).toSet().take(5).join(' / ');
          buf.write(' → 搜索${data.length}条: $names');
          // 取第一个含「游戏王」的结果验章节, 没有就用第一条
          dynamic pick;
          for (final d in data) {
            if (d.name.contains(title)) {
              pick = d;
              break;
            }
          }
          pick ??= data.first;
          try {
            final ct = await plugin
                .traceChapters(pick.src)
                .timeout(const Duration(seconds: 15));
            var epCount = 0;
            for (final r in ct.roads) {
              epCount += r.data.length;
            }
            buf.write(' ⇒《${pick.name}》${ct.roads.length}线路$epCount集');
            if (epCount > 0) hit++;
          } catch (e) {
            buf.write(' ⇒ 章节FAIL');
          }
        } catch (e) {
          buf.write(' → 搜索FAIL: ${e.toString().substring(0, e.toString().length > 160 ? 160 : e.toString().length)}');
          // [对照取证] 引擎失败时用裸 HttpClient 抓同 URL, 对比 body 差异
          if (name == 'gugu3') {
            try {
              final c2 = HttpClient();
              c2.connectionTimeout = const Duration(seconds: 15);
              final req2 = await c2.getUrl(Uri.parse(plugin.searchURL
                  .replaceAll('@keyword', title)));
              final res2 = await req2.close().timeout(const Duration(seconds: 30));
              final body2 = await res2.transform(const Utf8Decoder()).join();
              final cards2 = 'search-result-card'.allMatches(body2).length;
              buf.write(' | 对照: ${res2.statusCode} len=${body2.length} cards=$cards2');
              c2.close();
            } catch (e2) {
              buf.write(' | 对照抓取失败: ${e2.toString().substring(0, 80)}');
            }
          }
        }
        results.add(buf.toString());
        mark('[kwsan] $name: 完成');
      }

      results.insert(0, '== 关键词专项扫描 (16 新源) ==');
      results.insert(1, '有货源数: $hit/16');
    });

    for (final line in results) {
      // ignore: avoid_print
      print(line);
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}
