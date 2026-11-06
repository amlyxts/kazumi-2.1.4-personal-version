// 手动批处理工具 (非 CI): 想看收藏 × 全部规则源 播放覆盖矩阵。
// 每源一个串行 worker (对本站友好), 18 worker 并行; 每组合:
// 搜索(名称匹配) → 章节集数。进度实时落 镜像隧道/collect_matrix.log。
// 运行 (仓库根, 先关闭 Kazumi):
//   ../tools/flutter3477/bin/flutter.bat test --no-pub test/manual_collect_matrix_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart' as hive_flutter;
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/plugin/rule_engine.dart';
import 'package:kazumi/services/storage/storage.dart';

void mark(String msg) {
  File(r'C:\Users\liuxuan\Downloads\Kazumi-2.1.4\镜像隧道\collect_matrix.log')
      .writeAsStringSync('[${DateTime.now().toIso8601String()}] $msg\n',
          mode: FileMode.append, flush: true);
}

String norm(String s) => s
    .replaceAll(RegExp(r'[\s　·・~～\-–—_！!？?：:，,「」『』【】\[\]()（）]+'), '')
    .toLowerCase();

bool nameMatch(String a, String b) {
  final x = norm(a);
  final y = norm(b);
  if (x.isEmpty || y.isEmpty) return false;
  return x == y || x.contains(y) || y.contains(x);
}

class PairResult {
  PairResult(this.status, [this.note = '']);
  final String status; // covered / noresult / fail:<原因>
  final String note;
  @override
  String toString() => status + (note.isEmpty ? '' : '($note)');
}

Future<void> main() async {
  testWidgets('想看×全源 播放覆盖矩阵', (WidgetTester tester) async {
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
    mark('环境就绪 (真实 HTTP, Clash 出站)');

    final lines = <String>[];
    await tester.runAsync(() async {
      // 沙盒副本 Hive
      final staging = Directory.systemTemp.createTempSync('kazumi-matrix-');
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

      final box = await hive_flutter.Hive.openBox<CollectedBangumi>(
          'collectibles');
      final planToWatch = box.values
          .where((c) => c.type == CollectType.planToWatch.value)
          .toList()
        ..sort((a, b) => a.time.compareTo(b.time));
      final titles = <String>[];
      for (final e in planToWatch) {
        final item = e.bangumiItem;
        titles.add(item.nameCn.trim().isNotEmpty
            ? item.nameCn.trim()
            : item.name.trim());
      }
      mark('想看 ${titles.length} 部');

      final raw = File(
              r'C:\Users\liuxuan\AppData\Roaming\com.example\kazumi\plugins\v2\plugins.json')
          .readAsStringSync();
      final plugins = (jsonDecode(raw) as List)
          .map((e) => Plugin.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      final engine = RuleEngine();

      // 每源一个 worker: 串行遍历全部标题 (对本站友好), 18 worker 并行
      final results = <String, Map<int, PairResult>>{};
      final workers = <Future<void>>[];
      for (final plugin in plugins) {
        final name = plugin.name;
        results[name] = {};
        workers.add(() async {
          var consecNetFail = 0;
          for (var idx = 0; idx < titles.length; idx++) {
            if (consecNetFail >= 3) {
              for (var j = idx; j < titles.length; j++) {
                results[name]![j] =
                    PairResult('fail:源不可达(连续网络失败,跳过余下)');
              }
              mark('[$name] 连续网络失败 → 该源中止');
              return;
            }
            final title = titles[idx];
            try {
              final trace = await engine
                  .search(plugin.healthConfig, title)
                  .timeout(const Duration(seconds: 25));
              consecNetFail = 0;
              dynamic best;
              for (final hit in trace.response.data) {
                if (nameMatch(title, hit.name)) {
                  best = hit;
                  break;
                }
              }
              if (best == null) {
                results[name]![idx] = PairResult('noresult');
                continue;
              }
              final chapterTrace = await engine
                  .queryChapters(plugin.healthConfig, best.src)
                  .timeout(const Duration(seconds: 25));
              var epCount = 0;
              for (final r in chapterTrace.roads) {
                epCount += r.data.length;
              }
              consecNetFail = 0;
              results[name]![idx] =
                  PairResult('covered', '$epCount集');
              mark('[$name] #$idx ${title} → ${epCount}集');
            } catch (e) {
              final s = e.toString();
              final isNet = s.contains('NetworkException') ||
                  s.contains('DioException') ||
                  s.contains('Timeout');
              if (isNet) consecNetFail++;
              results[name]![idx] = PairResult(
                  isNet ? 'fail:网络' : 'noresult',
                  s.substring(0, s.length.clamp(0, 40)));
            }
          }
          mark('[$name] worker 完成');
        }());
      }
      await Future.wait(workers);

      // 汇总矩阵报告 (按番聚合)
      var fullCover = 0, partialCover = 0, noCover = 0;
      for (var idx = 0; idx < titles.length; idx++) {
        final covered = <String>[];
        var failCount = 0, noresult = 0;
        for (final p in plugins) {
          final r = results[p.name]?[idx];
          if (r == null) continue;
          if (r.status == 'covered') {
            covered.add(p.name);
          } else if (r.status.startsWith('fail')) {
            failCount++;
          } else {
            noresult++;
          }
        }
        final line = StringBuffer('[${idx + 1}] ${titles[idx]}: ');
        if (covered.isNotEmpty) {
          line.write('✓ 可播候选 ${covered.length} 源 [${covered.join(", ")}]');
          if (failCount == 0 && noresult == 0) {
            fullCover++;
          } else {
            partialCover++;
          }
        } else {
          line.write('✗ 全源无覆盖 (失败 $failCount / 无结果 $noresult)');
          noCover++;
        }
        lines.add(line.toString());
      }
      lines.add('');
      lines.add('统计: 全源命中=$fullCover / 部分覆盖=$partialCover / 无覆盖=$noCover '
          '(共 ${titles.length} 部 × ${plugins.length} 源)');
      lines.add('源级说明: fail:网络 = 该源连续失败被中止(不可达); noresult = 搜索无此番');
    });

    final reportFile = File(
        r'C:\Users\liuxuan\Downloads\Kazumi-2.1.4\收藏想看全源矩阵_20261106.md');
    reportFile.writeAsStringSync('# 收藏想看×全源矩阵\n\n'
        + lines.join('\n') + '\n', flush: true);
    for (final line in lines) {
      // ignore: avoid_print
      print(line);
    }
  }, timeout: const Timeout(Duration(minutes: 40)));
}
