// 手动体检工具 (非 CI 测试): 收藏「想看」分类逐番验证 — 是否存在可播放
// 的源 (搜索命中 → 章节齐全 → 观看页可达), 每番凑满 2 个可播源即停。
// ⚠ 环境同 manual_plugin_health_test (runAsync + HttpOverrides + mocks)。
// 运行 (仓库根, 先关闭 Kazumi):
//   ../tools/flutter3477/bin/flutter.bat test --no-pub test/manual_collect_check_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart' as hive_flutter;
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/storage/storage.dart';

void _mark(String msg) {
  File(r'C:\Users\liuxuan\Downloads\Kazumi-2.1.4\镜像隧道\collect_check.log')
      .writeAsStringSync('[${DateTime.now().toIso8601String()}] $msg\n',
          mode: FileMode.append, flush: true);
}

/// 已知不可用源 (11-06 体检结论): 跳过省时间
const skipSources = {
  'mutefun',    // API 返回非 JSON
  'dalvdm',     // 章节接口网络失败
  'baimao',     // 章节接口失效 (301 跳转后)
  'xfdmnext',   // 接收超时
  'HanimeOne',  // R18 验证码挑战
};

String _norm(String s) => s
    .replaceAll(RegExp(r'[\s　·・~～\-–—_！!？?：:，,「」『』【】\[\]()（）]+'), '')
    .toLowerCase();

bool _nameMatch(String a, String b) {
  final x = _norm(a);
  final y = _norm(b);
  if (x.isEmpty || y.isEmpty) return false;
  return x == y || x.contains(y) || y.contains(x);
}

void main() {
  testWidgets('想看收藏逐番源验证', (WidgetTester tester) async {
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
    _mark('环境就绪 (真实 HTTP)');
    _setupPageDio();

    final lines = <String>[];
    await tester.runAsync(() async {
      final staging = Directory.systemTemp.createTempSync('kazumi-collect-');
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
      final box = await hive_flutter.Hive.openBox<CollectedBangumi>(
          'collectibles');
      final planToWatch = box.values
          .where((c) => c.type == CollectType.planToWatch.value)
          .toList()
        ..sort((a, b) => a.time.compareTo(b.time));
      _mark('想看 ${planToWatch.length} 部');

      final raw = File(
              r'C:\Users\liuxuan\AppData\Roaming\com.example\kazumi\plugins\v2\plugins.json')
          .readAsStringSync();
      final plugins = (jsonDecode(raw) as List)
          .map((e) => Plugin.fromJson(Map<String, dynamic>.from(e as Map)))
          .where((p) => !skipSources.contains(p.name))
          .toList();

      var idx = 0;
      for (final entry in planToWatch) {
        idx++;
        final item = entry.bangumiItem;
        final title = item.nameCn.trim().isNotEmpty
            ? item.nameCn.trim()
            : item.name.trim();
        final buf = StringBuffer('[$idx] $title: ');
        _mark('验证 $title');
        var playableSources = 0;
        final detail = <String>[];

        for (final plugin in plugins) {
          if (playableSources >= 2) break;
          try {
            final trace = await plugin
                .traceSearch(title)
                .timeout(const Duration(seconds: 30));
            // 名称匹配的最佳命中
            dynamic best;
            for (final hit in trace.response.data) {
              if (_nameMatch(title, hit.name)) {
                best = hit;
                break;
              }
            }
            best ??= trace.response.data.isEmpty
                ? null
                : trace.response.data.first;
            if (best == null) {
              detail.add('${plugin.name}: 无结果');
              continue;
            }
            if (!_nameMatch(title, best.name)) {
              detail.add('${plugin.name}: 命中不匹配(${best.name})');
              continue;
            }
            final chapterTrace = await plugin
                .traceChapters(best.src)
                .timeout(const Duration(seconds: 30));
            var epCount = 0;
            String? firstEp;
            for (final r in chapterTrace.roads) {
              epCount += r.data.length;
              firstEp ??= r.data.isNotEmpty ? r.data.first : null;
            }
            if (epCount == 0) {
              detail.add('${plugin.name}: 章节0集');
              continue;
            }
            // 观看页可达性 (相对路径拼 baseUrl)
            var pageUrl = firstEp ?? '';
            if (pageUrl.startsWith('/')) {
              pageUrl = '${plugin.baseUrl}$pageUrl';
            }
            final page = await pageDio.get<String>(pageUrl)
                .timeout(const Duration(seconds: 20));
            final body = page.data ?? '';
            final playable = page.statusCode == 200 &&
                (body.contains('player') ||
                    body.contains('video') ||
                    body.contains('m3u8') ||
                    body.contains('mp4'));
            if (playable) {
              playableSources++;
              detail.add('${plugin.name}: ✓${chapterTrace.roads.length}线路/$epCount集');
            } else {
              detail.add('${plugin.name}: 页面无可播特征');
            }
          } catch (e) {
            final s = e.toString().replaceAll('\n', ' ');
            detail.add('${plugin.name}: FAIL(${s.substring(0, s.length.clamp(0, 50))})');
          }
        }
        buf.write(playableSources > 0
            ? '✓ 有可播源 ($playableSources 个: ${detail.join(' | ')})'
            : '✗ 无可播源 (${detail.join(' | ')})');
        lines.add(buf.toString());
        _mark(buf.toString());
      }
    });

    for (final line in lines) {
      // ignore: avoid_print
      print(line);
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}

/// 观看页抓取用 Dio (出站走 Clash; 单例)
final Dio pageDio = Dio(BaseOptions());
void _setupPageDio() {
  final adapter = pageDio.httpClientAdapter;
  try {
    (adapter as dynamic).findProxy = (uri) => 'PROXY 127.0.0.1:7897';
  } catch (_) {}
}
