// 一次性工具 (非 CI): bangumi 同步线路实况 — token /v0/me + 收藏列表分页实测。
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
  testWidgets('bgm api diag', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final staging = Directory.systemTemp.createTempSync('kazumi-bgmapi-');
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
      final token = GStorage.getSetting(SettingsKeys.bangumiAccessToken);
      final syncEnable = GStorage.getSetting(SettingsKeys.bangumiSyncEnable);
      print('token: ${token.isEmpty ? "无" : "有"} | bangumiSyncEnable: $syncEnable');
      if (token.isEmpty) return;
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..findProxy = (uri) => 'DIRECT';
      client.userAgent = 'amlyxts/kazumi-maintenance';
      Future<Map<String, dynamic>> get(String url) async {
        final rq = await client.openUrl('GET', Uri.parse(url));
        rq.headers.set('Authorization', 'Bearer $token');
        rq.headers.set('Accept', 'application/json');
        final rs = await rq.close().timeout(const Duration(seconds: 25));
        final text = await rs.transform(utf8.decoder).join();
        return {'code': rs.statusCode, 'text': text};
      }
      // /v0/me 拿用户名
      final me = await get('https://api.bgmapi.com/v0/me');
      if (me['code'] != 200) {
        print('/v0/me: HTTP ${me['code']} (token 失效?) ${me['text'].substring(0, me['text'].length > 120 ? 120 : me['text'].length)}');
        client.close();
        return;
      }
      final meObj = jsonDecode(me['text'] as String) as Map;
      final username = meObj['username']?.toString() ?? '';
      final nickname = meObj['nickname']?.toString() ?? '';
      print('/v0/me: OK username=$username nickname=$nickname');
      // 收藏列表首页 (动画 subject_type=2, 与 app 同参)
      final r1 = await get(
          'https://api.bgmapi.com/v0/users/$username/collections?subject_type=2&limit=50&offset=0');
      print('collections 首页: HTTP ${r1['code']}');
      if (r1['code'] != 200) {
        print('  ${r1['text'].substring(0, r1['text'].length > 200 ? 200 : r1['text'].length)}');
        client.close();
        return;
      }
      final d = jsonDecode(r1['text'] as String) as Map;
      final total = d['total'];
      final data = d['data'] as List;
      print('  total=$total | 首页条数=${data.length}');
      // 不带 subject_type (全类型) 对照
      final r2 = await get(
          'https://api.bgmapi.com/v0/users/$username/collections?limit=50&offset=0');
      if (r2['code'] == 200) {
        final d2 = jsonDecode(r2['text'] as String) as Map;
        print('  全类型 total=${d2['total']}');
      } else {
        print('  全类型: HTTP ${r2['code']}');
      }
      // 首页前 5 条看类型/条目
      for (final it in data.take(5)) {
        final s = it is Map ? (it['subject'] as Map?) : null;
        print('  样本: type=${it is Map ? it['type'] : '?'} | ${s?['name_cn'] ?? s?['name'] ?? '?'} | id=${s?['id']}');
      }
      client.close();
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}
