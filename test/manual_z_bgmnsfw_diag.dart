// 一次性工具 (非 CI): bgm 收藏中 nsfw 条目清点 (API subject.nsfw 字段)。
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
  testWidgets('bgm nsfw count', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final staging = Directory.systemTemp.createTempSync('kazumi-bgmnsfw-');
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
      final nsfwItems = <Map<int, String>>{};
      final typeNames = {1: '想看', 2: '看过', 3: '在看', 4: '搁置', 5: '抛弃'};
      final nsfwTypes = <int, int>{};
      int offset = 0;
      int seen = 0;
      while (true) {
        Map? page;
        for (int attempt = 0; attempt < 2; attempt++) {
          try {
            final rq = await client.openUrl('GET', Uri.parse(
                'https://api.bgmapi.com/v0/users/1227054/collections?subject_type=2&limit=50&offset=$offset'));
            rq.headers.set('Authorization', 'Bearer $token');
            rq.headers.set('Accept', 'application/json');
            final rs = await rq.close().timeout(const Duration(seconds: 25));
            final text = await rs.transform(utf8.decoder).join();
            if (rs.statusCode == 200) {
              page = jsonDecode(text);
              break;
            }
            print('  页失败 offset=$offset HTTP ${rs.statusCode} (尝试 ${attempt + 1})');
          } catch (e) {
            print('  页异常 offset=$offset (尝试 ${attempt + 1}): ${e.toString().substring(0, 60)}');
          }
          await Future<void>.delayed(const Duration(seconds: 3));
        }
        if (page == null) {
          print('  offset=$offset 两轮失败, 跳过');
          offset += 50;
          if (offset >= 350) break;
          continue;
        }
        final d = page;
        final data = d['data'] as List;
        for (final it in data) {
          if (it is! Map) continue;
          seen++;
          final s = it['subject'];
          if (s is Map) {
            final name = ((s['name_cn'] ?? s['name']) ?? '').toString();
            final images = s['images'];
            final id = (s['id'] as num?)?.toInt() ?? 0;
            final stripped = name.isEmpty ||
                (images is Map && (images['common'] ?? '').toString().isEmpty);
            final t = (it['type'] as num?)?.toInt() ?? 0;
            if (stripped) {
              nsfwItems.add({id: '(脱敏) type=$t nsfw字段=${s['nsfw']} date=${it['updated_at'] ?? '?'}'});
            }
          }
        }
        final total = (d['total'] as num?)?.toInt() ?? 0;
        offset += 50;
        if (offset >= total || data.isEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
      print('bgm 收藏扫描: $seen 条 | 脱敏条目: ${nsfwItems.length} 条');
      print('nsfw 按收藏类型: ${nsfwTypes.map((k, v) => MapEntry(typeNames[k] ?? '$k', v))}');
      for (final m in nsfwItems) {
        m.forEach((id, name) => print('  nsfw: id=$id $name'));
      }
      client.close();
    });
  }, timeout: const Timeout(Duration(minutes: 5)));
}
