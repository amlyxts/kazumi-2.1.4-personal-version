// 一次性工具 (非 CI): bgm 关联诊断 — PC adultBgmMap 实况 + 云端 settings.json 实况。
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
  HttpOverrides.global = null;
  testWidgets('bgm map diag', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final staging = Directory.systemTemp.createTempSync('kazumi-bgmdiag-');
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
      // PC 本地实况
      final mapRaw = GStorage.getSetting(SettingsKeys.adultBgmMap).trim();
      final cookie = GStorage.getSetting(SettingsKeys.bgmWebCookie).trim();
      final email = GStorage.getSetting(SettingsKeys.bgmAccountEmail).trim();
      var pcCount = 0;
      if (mapRaw.isNotEmpty) {
        try {
          pcCount = (jsonDecode(mapRaw) as Map).length;
        } catch (_) {}
      }
      print('PC adultBgmMap: $pcCount 条 | cookie: ${cookie.isEmpty ? "空" : "有(${cookie.length}B)"} | 账号: ${email.isEmpty ? "未填" : "已填"}');
      if (mapRaw.isNotEmpty) {
        try {
          final m = jsonDecode(mapRaw) as Map;
          m.forEach((k, v) {
            final name = v is Map ? (v['nameCn'] ?? '') : '';
            final bgmId = v is Map ? (v['bgmId'] ?? '') : '';
            print('  PC 关联: $k -> bgmId=$bgmId nameCn=$name');
          });
        } catch (_) {}
      }

      // 云端 settings.json 实况 (单次 GET, 低强度)
      final url = GStorage.getSetting(SettingsKeys.webDavURL).trim();
      final user = GStorage.getSetting(SettingsKeys.webDavUsername).trim();
      final pass = GStorage.getSetting(SettingsKeys.webDavPassword).trim();
      if (url.isEmpty || user.isEmpty || pass.isEmpty) {
        print('CLOUD: 凭据不完整, 跳过');
        return;
      }
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..findProxy = (uri) => 'DIRECT';
      client.userAgent = 'amlyxts/kazumi-maintenance';
      final base = url.endsWith('/') ? url : '$url/';
      final auth = base64Encode(utf8.encode('$user:$pass'));
      final rq = await client.openUrl(
          'GET', Uri.parse('${base}kazumiSync/settings.json'));
      rq.headers.set('Authorization', 'Basic $auth');
      rq.headers.set('Accept', 'application/json');
      final rs = await rq.close().timeout(const Duration(seconds: 25));
      final text = await rs.transform(utf8.decoder).join();
      print('CLOUD settings.json: HTTP ${rs.statusCode} | ${text.length}B');
      print('Last-Modified: ${rs.headers.value('last-modified') ?? '?'}');
      if (rs.statusCode == 200) {
        final d = jsonDecode(text) as Map;
        final cloudMap = (d['adultBgmMap'] ?? '').toString().trim();
        final cloudCookie = (d['bgmWebCookie'] ?? '').toString().trim();
        var cloudCount = 0;
        if (cloudMap.isNotEmpty) {
          try {
            cloudCount = (jsonDecode(cloudMap) as Map).length;
          } catch (_) {}
        }
        print('CLOUD adultBgmMap: $cloudCount 条 | cookie: ${cloudCookie.isEmpty ? "空" : "有"}');
        if (cloudMap.isNotEmpty) {
          final m = jsonDecode(cloudMap) as Map;
          m.forEach((k, v) {
            final name = v is Map ? (v['nameCn'] ?? '') : '';
            final bgmId = v is Map ? (v['bgmId'] ?? '') : '';
            print('  云端关联: $k -> bgmId=$bgmId nameCn=$name');
          });
        }
        print('CLOUD 含 settingsSyncUpdatedAt: ${d['webDavSettingsSyncUpdatedAt'] ?? '无'}');
      }
      client.close();
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}
