// 手动体检工具 (非 CI 测试): 视频源规则深度体检 — 用应用真实规则引擎
// 逐源跑「搜索 → 章节」, 输出诊断表。
// ⚠⚠ 两个环境关键点:
// 1) testWidgets 主体在 FakeAsync 区, 真实 IO/网络必须包在 tester.runAsync
// 2) flutter_test 默认 _MockHttpOverrides (所有 HttpClient 永远 400) —
//    必须 HttpOverrides.global = null 恢复真实网络
// 运行 (仓库根, 先关闭 Kazumi 避免 Hive 锁冲突):
//   ../tools/flutter3477/bin/flutter.bat test --no-pub test/manual_plugin_health_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart' as hive;
import 'package:hive_ce_flutter/hive_flutter.dart' as hive_flutter;
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';
import 'package:kazumi/services/storage/storage.dart';

void _mark(String msg) {
  // 实时打点: 定位卡点用
  File(r'C:\Users\liuxuan\Downloads\Kazumi-2.1.4\镜像隧道\health_progress.log')
      .writeAsStringSync('[${DateTime.now().toIso8601String()}] $msg\n',
          mode: FileMode.append, flush: true);
}

void main() {
  testWidgets('视频源规则深度体检', (WidgetTester tester) async {
    // path_provider/connectivity mock (测试环境无平台实现, 不 mock 会挂)
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
    // [关键] 恢复真实网络 (mock overrides 进程级 400)
    HttpOverrides.global = null;
    _mark('binding+mocks+真实HTTP 就绪');

    final lines = <String>[];
    await tester.runAsync(() async {
      var ok = 0, degraded = 0, broken = 0, skipped = 0;
      try {
        // 沙盒副本: 真实 hive 拷到临时目录 (零锁竞争, 零真实数据风险)
        final staging = Directory.systemTemp.createTempSync('kazumi-health-');
        final srcHive = Directory(
            r'C:\Users\liuxuan\AppData\Roaming\com.example\kazumi\hive');
        final dstHive = Directory('${staging.path}/hive');
        await dstHive.create(recursive: true);
        await for (final f in srcHive.list()) {
          if (f is File && !f.path.endsWith('.lock')) {
            await f.copy('${dstHive.path}/${f.uri.pathSegments.last}');
          }
        }
        _mark('hive 副本就绪');
        hive.Hive.init(dstHive.path);
        await GStorage.init();
        _mark('GStorage 初始化完成');

        final kwCN = '海贼王';
        final raw = File(
                r'C:\Users\liuxuan\AppData\Roaming\com.example\kazumi\plugins\v2\plugins.json')
            .readAsStringSync();
        final list = (jsonDecode(raw) as List)
            .map((e) => Plugin.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();

        for (final plugin in list) {
          final buf = StringBuffer('${plugin.name} '
              '(${plugin.searchMode}/${plugin.chapterMode}, api ${plugin.api})');
          if (plugin.requiresNewerClient) {
            buf.write(
                ' -> 跳过: api 需 ${plugin.api} > 客户端 ${ApiEndpoints.apiLevel}');
            lines.add(buf.toString());
            skipped++;
            continue;
          }
          final kws =
              plugin.name == 'HanimeOne' ? ['単体作品', kwCN] : [kwCN];
          var verdict = '';
          for (final kw in kws) {
            try {
              final trace = await plugin
                  .traceSearch(kw)
                  .timeout(const Duration(seconds: 30));
              final count = trace.response.data.length;
              if (count == 0) {
                verdict = '搜索=0条 (kw=$kw)';
                continue;
              }
              buf.write(' 搜索=${count}条(kw=$kw)');
              final src = trace.response.data.first.src;
              var roadCount = 0;
              var epCount = 0;
              var chapterOK = false;
              try {
                final chapterTrace = await plugin
                    .traceChapters(src)
                    .timeout(const Duration(seconds: 30));
                roadCount = chapterTrace.roads.length;
                for (final r in chapterTrace.roads) {
                  epCount += r.data.length;
                }
                chapterOK = roadCount > 0 && epCount > 0;
              } catch (e) {
                buf.write(' 章节=FAIL(${_short(e)})');
              }
              if (chapterOK) {
                buf.write(' 章节=${roadCount}线路/${epCount}集');
                verdict = 'OK';
              } else if (verdict.isEmpty || verdict.startsWith('章节')) {
                verdict = '章节FAIL';
              }
              break;
            } on NoResultException {
              verdict = '搜索=0条 (kw=$kw)';
              continue;
            } on CaptchaRequiredException {
              verdict = '验证码挑战';
              break;
            } catch (e) {
              var detail = _short(e);
              try {
                final ne = (e as dynamic).cause;
                final resp = ne?.rawError?.response;
                detail =
                    'status=${resp?.statusCode} ${_short(e)}';
              } catch (_) {}
              verdict = '搜索FAIL($detail)';
              break;
            }
          }
          if (verdict == 'OK') {
            ok++;
          } else if (verdict.startsWith('搜索FAIL') ||
              verdict.startsWith('章节FAIL')) {
            broken++;
          } else {
            degraded++;
          }
          buf.write(' => $verdict');
          lines.add(buf.toString());
          File(r'C:\Users\liuxuan\Downloads\Kazumi-2.1.4\镜像隧道\health_progress.log')
              .writeAsStringSync('${buf.toString()}\n',
                  mode: FileMode.append, flush: true);
        }
      } catch (e) {
        lines.add('!! 体检异常: $e');
      }
      lines.add('');
      lines.add('统计: OK=$ok / 降级(0条,可能关键词不适用)=$degraded / FAIL=$broken / '
          '跳过=$skipped');
    });

    for (final line in lines) {
      // ignore: avoid_print
      print(line);
    }
  }, timeout: const Timeout(Duration(minutes: 15)));
}

String _short(Object e) {
  final s = e.toString().replaceAll('\n', ' ');
  return s.substring(0, s.length.clamp(0, 90));
}
