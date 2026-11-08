// 一次性工具 (非 CI): 设置实查 — 白名单/镜像/token/bgm nsfw 搜索验证。
// ⚠ 必须走 testWidgets + runAsync (真异步 IO); 标题经 KAZUMI_BGM_TEST_KW 注入。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart' as hive_flutter;
import 'package:kazumi/services/storage/storage.dart';

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    return r'C:\Users\liuxuan\AppData\Roaming\com.example\kazumi';
  });
  const connChannel = MethodChannel('dev.fluttercommunity.plus/connectivity');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(connChannel, (call) async {
    return ['wifi'];
  });
  HttpOverrides.global = null;

  testWidgets('settings probe', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final staging = Directory.systemTemp.createTempSync('kazumi-probe-');
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
      // ignore: avoid_print
      print('[stage] ready');

      // ignore: avoid_print
      print('WL_EXTRA=[${GStorage.getSetting(SettingsKeys.proxyWhitelistExtra)}]');
      // ignore: avoid_print
      print('PC_MIRROR_BASE=[${GStorage.getSetting(SettingsKeys.skipMirrorBase)}]');

      // [诊断] 带授权重搜 bgm (标题经环境变量传入, 不落代码/日志)
      final testKw = Platform.environment['KAZUMI_BGM_TEST_KW'] ?? '';
      final bt = GStorage.getSetting(SettingsKeys.bangumiAccessToken).trim();
      // ignore: avoid_print
      print('BGM_TOKEN=[${bt.isEmpty ? "<未配置>" : "已配置(len=${bt.length})"}]');
      if (testKw.isNotEmpty) {
        Future<void> doSearch(String mode, Map<String, String> auth) async {
          try {
            final client = HttpClient()
              ..connectionTimeout = const Duration(seconds: 12)
              ..findProxy = (uri) =>
                  Platform.environment['KAZUMI_NO_CLASH'] == '1'
                      ? 'DIRECT'
                      : 'PROXY 127.0.0.1:7897';
            client.userAgent = 'amlyxts/kazumi-maintenance';
            final rq = await client.openUrl(
                'POST', Uri.parse('https://api.bgm.tv/v0/search/subjects'));
            rq.headers.set('Content-Type', 'application/json');
            auth.forEach(rq.headers.set);
            final bodyText = jsonEncode({
              'keyword': testKw,
              'limit': 10,
              if (mode == '带登录' && auth.isNotEmpty)
                'filter': {'nsfw': true},
            });
            rq.add(utf8.encode(bodyText));
            final rs = await rq.close().timeout(const Duration(seconds: 20));
            final text = await rs.transform(utf8.decoder).join();
            // ignore: avoid_print
            print('  [status] ' + rs.statusCode.toString() + ' body头: ' + text.substring(0, text.length > 80 ? 80 : text.length));
            final d = jsonDecode(text);
            final data = (d['data'] ?? []) as List;
            final nsfwCount = data.where((x) => x['nsfw'] == true).length;
            final plats = data
                .map((x) => '${x['platform'] ?? '?'}/${x['nsfw'] ?? '?'}')
                .toList();
            // ignore: avoid_print
            print('[$mode] ${data.length} 条 | nsfw=True: $nsfwCount | ${plats.join(", ")}');
            client.close();
          } catch (e) {
            final m = e.toString();
            // ignore: avoid_print
            print('[$mode] 失败: ${m.substring(0, m.length > 90 ? 90 : m.length)}');
          }
        }

        await doSearch('无登录', {});
        if (bt.isNotEmpty) {
          await doSearch('带登录', {'Authorization': 'Bearer ' + bt});
        } else {
          // ignore: avoid_print
          print('[带登录] 跳过 — app 未配置 bgm 授权 token (设置→Bangumi 授权)');
        }
      } else {
        // ignore: avoid_print
        print('KAZUMI_BGM_TEST_KW 未设置, 跳过搜索对比');
      }

      // [诊断] 按 ID 直取对比 (未认证 vs 认证) — 独立于标题测试
      final testId = Platform.environment['KAZUMI_BGM_TEST_ID'] ?? '';
      if (testId.isNotEmpty) {
        for (final mode in ['ID未认证', 'ID认证']) {
          try {
            final client = HttpClient()
              ..connectionTimeout = const Duration(seconds: 12)
              ..findProxy = (uri) => 'PROXY 127.0.0.1:7897';
            client.userAgent = 'amlyxts/kazumi-maintenance';
            final rq = await client.openUrl(
                'GET', Uri.parse('https://api.bgm.tv/v0/subjects/' + testId));
            rq.headers.set('Accept', 'application/json');
            if (mode == 'ID认证' && bt.isNotEmpty) {
              rq.headers.set('Authorization', 'Bearer ' + bt);
            }
            final rs = await rq.close().timeout(const Duration(seconds: 15));
            final text = await rs.transform(utf8.decoder).join();
            final d = jsonDecode(text);
            print('[$mode] HTTP ${rs.statusCode} nsfw=${d['nsfw']} '
                'platform=${d['platform']} name_cn=${d['name_cn']}');
            client.close();
          } catch (e) {
            final m = e.toString();
            print('[$mode] 失败: ${m.substring(0, m.length > 70 ? 70 : m.length)}');
          }
        }
      }
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}
