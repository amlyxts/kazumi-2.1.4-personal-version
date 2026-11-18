// 一次性工具 (非 CI): bgm 收藏写入端点对 nsfw 条目放行测试。
// POST 525141 用其当前状态 type=5 重写 (无实际变更), + subject 详情 nsfw 字段。
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
  testWidgets('bgm post nsfw test', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final staging = Directory.systemTemp.createTempSync('kazumi-bgmpost-');
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
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..findProxy = (uri) => 'DIRECT';
      client.userAgent = 'amlyxts/kazumi-maintenance';
      // 1) subject 详情 (未认证) — nsfw 字段
      final gq = await client.openUrl(
          'GET', Uri.parse('https://api.bgmapi.com/v0/subjects/525141'));
      gq.headers.set('Authorization', 'Bearer $token');
      gq.headers.set('Accept', 'application/json');
      final grs = await gq.close().timeout(const Duration(seconds: 25));
      final gtext = await grs.transform(utf8.decoder).join();
      if (grs.statusCode == 200) {
        final gd = jsonDecode(gtext) as Map;
        print('subject 详情: HTTP 200 | nsfw=${gd['nsfw']} | name=${gd['name']} | platform=${gd['platform']}');
      } else {
        print('subject 详情: HTTP ${grs.statusCode}');
      }
      // 2) 收藏写入 (状态不变重写 type=5) — 放行测试
      final pq = await client.openUrl(
          'POST', Uri.parse('https://api.bgmapi.com/v0/users/-/collections/525141'));
      pq.headers.set('Authorization', 'Bearer $token');
      pq.headers.set('Content-Type', 'application/json');
      pq.add(utf8.encode(jsonEncode({'type': 5})));
      final prs = await pq.close().timeout(const Duration(seconds: 25));
      final ptext = await prs.transform(utf8.decoder).join();
      print('收藏写入 POST: HTTP ${prs.statusCode} | ${ptext.isEmpty ? "(空)" : ptext.substring(0, ptext.length > 200 ? 200 : ptext.length)}');
      client.close();
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}
