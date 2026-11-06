// 一次性工具 (非 CI): 未装新源批量体检 — 对 68 个官方仓库规则逐源跑
// 「搜索 → 章节」真实解析, 输出存活分类表 (OK / 有搜索无章节 / 死源)。
// ⚠ 环境: tester.runAsync 包真实 IO; HttpOverrides=null 恢复真实网络;
// path_provider/connectivity mock; GStorage 沙盒副本。
// 运行 (仓库根):
//   ../tools/flutter3477/bin/flutter.bat test --no-pub test/manual_repo_scan_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/services/plugin/rule_engine.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';
import 'package:hive_ce_flutter/hive_flutter.dart' as hive_flutter;
import 'package:kazumi/services/storage/storage.dart';

void mark(String msg) {
  File(r'C:\Users\liuxuan\Downloads\Kazumi-2.1.4\镜像隧道\repo_scan.log')
      .writeAsStringSync('[${DateTime.now().toIso8601String()}] $msg\n',
          mode: FileMode.append, flush: true);
}

const title = '海贼王';
// 每源单个搜索超时 20s; 章节超时 15s

void main() {
  testWidgets('未装新源批量体检 (68 源)', (WidgetTester tester) async {
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
    var ok = 0, searchFail = 0, chapterFail = 0, noResult = 0, skipped = 0;

    await tester.runAsync(() async {
      final staging = Directory.systemTemp.createTempSync('kazumi-repo-scan-');
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

      final raw = File(
              r'C:\Users\liuxuan\AppData\Roaming\com.example\kazumi\plugins\v2\plugins.json')
          .readAsStringSync();
      final installed = (jsonDecode(raw) as List)
          .map((e) =>
              (e as Map)['name'].toString())
          .toSet();

      final rulesDir = Directory(r'C:\Users\liuxuan\Downloads\Kazumi-2.1.4\repo_rules');
      final ruleFiles = rulesDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      for (final f in ruleFiles) {
        final name = f.path.split(Platform.pathSeparator).last
            .replaceAll('.json', '');
        if (installed.contains(name)) continue; // 已装跳过
        skipped++;
        Map<String, dynamic> rule;
        try {
          rule = Map<String, dynamic>.from(jsonDecode(f.readAsStringSync())
              as Map);
        } catch (_) {
          results.add('$name: 规则文件解析失败');
          searchFail++;
          continue;
        }
        if (rule['deprecated'] == true) {
          // 官方标弃用但站点可能活着 — 仍测, 只是记录
        }
        final plugin = Plugin.fromJson(rule);
        if (plugin.requiresNewerClient) {
          results.add('$name: 跳过 (api ${plugin.api} > 客户端 9)');
          skipped++;
          continue;
        }
        final buf = StringBuffer('$name (${plugin.searchMode}/'
            '${plugin.chapterMode}, api ${plugin.api})');
        try {
          final trace = await plugin
              .traceSearch(title)
              .timeout(const Duration(seconds: 20));
          final count = trace.response.data.length;
          if (count == 0) {
            buf.write(' → 搜索0条');
            results.add(buf.toString());
            noResult++;
            continue;
          }
          buf.write(' → 搜索${count}条');
          // 章节
          try {
            final chapterTrace = await plugin
                .traceChapters(trace.response.data.first.src)
                .timeout(const Duration(seconds: 15));
            var epCount = 0;
            for (final r in chapterTrace.roads) {
              epCount += r.data.length;
            }
            buf.write(' / 章节${chapterTrace.roads.length}线路$epCount集');
            if (epCount > 0) {
              ok++;
            } else {
              chapterFail++;
            }
          } catch (e) {
            buf.write(' / 章节FAIL');
            chapterFail++;
          }
        } catch (e) {
          buf.write(' / 搜索FAIL');
          searchFail++;
        }
        results.add(buf.toString());
        mark('[repo-scan] $name: 完成');
      }

      results.insert(0, '== 未装新源体检结果 (关键词=$title) ==');
      results.insert(1, 'OK=$ok / 有搜索无章节=$noResult / 章节FAIL=$chapterFail / '
          '搜索FAIL=$searchFail / 跳过=$skipped');
    });

    for (final line in results) {
      // ignore: avoid_print
      print(line);
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
