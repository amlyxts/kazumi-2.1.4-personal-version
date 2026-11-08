// [my新增] 想看全源覆盖扫描 (阶段 1) — 52 源 × 116 部 × 双标题版, 逐对落盘断点续跑。
// 每对: traceSearch(10s) → 命中则 traceChapters(8s)。结果文件存在即跳过。
// 源清单: KAZUMI_SCAN_SOURCES (逗号分隔); 番清单: 外层 wantwatch_titles.json。
// 结果: 外层 ww_phase1/<src>_<num>_v<idx>.json; 进度: ww_phase1_progress.txt。
// 运行 (仓库根):
//   ../tools/flutter3477/bin/flutter.bat test --no-pub test/manual_z_ww_scan.dart
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
  File(r'C:\Users\liuxuan\Downloads\Kazumi-2.1.4\ww_phase1_progress.txt')
      .writeAsStringSync('[${DateTime.now().toIso8601String()}] $msg\n',
          mode: FileMode.append, flush: true);
}

Future<void> main() async {
  final sources = (Platform.environment['KAZUMI_SCAN_SOURCES'] ?? '')
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  testWidgets('想看覆盖扫描', (WidgetTester tester) async {
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

    await tester.runAsync(() async {
      final staging = Directory.systemTemp.createTempSync('kazumi-ww-');
      final srcHive = Directory(
          r'C:\Users\liuxuan\AppData\Roaming\com.example\kazumi\hive');
      final dstHive = Directory('${staging.path}/hive');
      await dstHive.create(recursive: true);
      await for (final f in srcHive.list()) {
        if (f is File && !f.path.endsWith('.lock')) {
          try {
            await f.copy('${dstHive.path}/${f.uri.pathSegments.last}');
          } catch (_) {}
        }
      }
      hive_flutter.Hive.init(dstHive.path);
      await GStorage.init();

      final outDir = Directory(
          r'C:\Users\liuxuan\Downloads\Kazumi-2.1.4\ww_phase1');
      outDir.createSync(recursive: true);
      final titles = jsonDecode(File(
              r'C:\Users\liuxuan\Downloads\Kazumi-2.1.4\wantwatch_titles.json')
          .readAsStringSync()) as List<dynamic>;

      final rulesDir =
          Directory(r'C:\Users\liuxuan\Downloads\Kazumi-2.1.4\repo_rules');
      var done = 0, hits = 0, skipped = 0, failed = 0;
      final total = sources.length * titles.length;

      for (final srcName in sources) {
        final f = File('${rulesDir.path}/$srcName.json');
        if (!f.existsSync()) {
          mark('$srcName: 规则文件缺失, 跳过');
          done += titles.length;
          continue;
        }
        Map<String, dynamic> rule;
        try {
          rule = Map<String, dynamic>.from(
              jsonDecode(f.readAsStringSync()) as Map);
        } catch (_) {
          mark('$srcName: 规则解析失败');
          done += titles.length;
          continue;
        }
        final plugin = Plugin.fromJson(rule);
        if (plugin.requiresNewerClient) {
          mark('$srcName: api 超客户端, 跳过');
          done += titles.length;
          continue;
        }
        for (final t in titles) {
          final num = (t as Map)['num'] as int;
          final variants =
              ((t)['variants'] as List).map((e) => e.toString()).toList();
          for (var vi = 0; vi < variants.length; vi++) {
            final outFile = File(
                '${outDir.path}/${srcName}_${num}_v$vi.json');
            if (outFile.existsSync()) {
              skipped++;
              done++;
              continue;
            }
            final kw = variants[vi];
            final result = <String, dynamic>{
              'src': srcName,
              'num': num,
              'variant': vi,
              'keyword': kw,
            };
            try {
              final searchTmo = int.tryParse(
                      Platform.environment['KAZUMI_SCAN_TMO'] ?? '') ??
                  10;
              final trace = await plugin
                  .traceSearch(kw)
                  .timeout(Duration(seconds: searchTmo));
              final data = trace.response.data;
              result['count'] = data.length;
              if (data.isNotEmpty) {
                // 取首个含关键词的结果, 否则第一条
                dynamic pick = data.first;
                for (final d in data) {
                  if (d.name.contains(kw)) {
                    pick = d;
                    break;
                  }
                }
                result['firstTitle'] = pick.name;
                result['src1'] = pick.src;
                try {
                  final ct = await plugin
                      .traceChapters(pick.src)
                      .timeout(Duration(seconds: searchTmo));
                  var eps = 0;
                  for (final r in ct.roads) {
                    eps += r.data.length;
                  }
                  result['roads'] = ct.roads.length;
                  result['eps'] = eps;
                  if (eps > 0) hits++;
                } catch (_) {
                  result['eps'] = 0;
                }
              }
            } catch (e) {
              result['error'] = e.toString().length > 120
                  ? e.toString().substring(0, 120)
                  : e.toString();
              failed++;
            }
            outFile.writeAsStringSync(
                jsonEncode(result), flush: true);
            done++;
            if (done % 50 == 0) {
              mark('进度 $done/$total 命中$hits 失败$failed 跳过$skipped');
            }
          }
        }
        mark('$srcName: 完成');
      }
      mark('PHASE1-DONE: 对数$done 命中$hits 失败$failed 跳过$skipped');
    });
  }, timeout: const Timeout(Duration(hours: 6)));
}
