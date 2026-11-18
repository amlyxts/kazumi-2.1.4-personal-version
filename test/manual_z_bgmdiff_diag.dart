// 一次性工具 (非 CI): bangumi 线差异对账 — PC 本地表番 id 集 vs API 全量 id 集。
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
  testWidgets('bgm diff diag', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final staging = Directory.systemTemp.createTempSync('kazumi-bgmdiff-');
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
      // PC 本地表番 id 集
      final localIds = <int>{};
      final localName = <int, String>{};
      for (final c in GStorage.collectibles.values) {
        if (c.section != 1) {
          localIds.add(c.bangumiItem.id);
          localName[c.bangumiItem.id] = c.bangumiItem.nameCn.isNotEmpty
              ? c.bangumiItem.nameCn
              : c.bangumiItem.name;
        }
      }
      print('PC 本地表番: ${localIds.length} 条');
      print('525141 在 PC 本地表番? ${localIds.contains(525141)}');
      // API 全量分页
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..findProxy = (uri) => 'DIRECT';
      client.userAgent = 'amlyxts/kazumi-maintenance';
      final username = '1227054';
      final remoteIds = <int>{};
      final remoteName = <int, String>{};
      final remoteType = <int, int>{};
      int offset = 0;
      while (true) {
        final rq = await client.openUrl('GET', Uri.parse(
            'https://api.bgmapi.com/v0/users/$username/collections?subject_type=2&limit=50&offset=$offset'));
        rq.headers.set('Authorization', 'Bearer $token');
        rq.headers.set('Accept', 'application/json');
        final rs = await rq.close().timeout(const Duration(seconds: 25));
        final text = await rs.transform(utf8.decoder).join();
        if (rs.statusCode != 200) {
          print('API 分页失败 offset=$offset HTTP ${rs.statusCode}');
          break;
        }
        final d = jsonDecode(text) as Map;
        final data = d['data'] as List;
        for (final it in data) {
          if (it is Map && it['subject'] is Map) {
            final s = it['subject'] as Map;
            final id = (s['id'] as num).toInt();
            remoteIds.add(id);
            remoteName[id] = (s['name_cn'] ?? s['name'] ?? '').toString();
            remoteType[id] = (it['type'] as num?)?.toInt() ?? 0;
          }
        }
        final total = (d['total'] as num?)?.toInt() ?? 0;
        offset += 50;
        if (offset >= total || data.isEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      print('API 远端: ${remoteIds.length} 条');
      final remoteOnly = remoteIds.difference(localIds);
      final localOnly = localIds.difference(remoteIds);
      print('远端有本地无: ${remoteOnly.length} 条');
      for (final id in remoteOnly.take(10)) {
        print('  + $id type=${remoteType[id]} ${remoteName[id]}');
      }
      print('本地有远端无: ${localOnly.length} 条');
      for (final id in localOnly.take(10)) {
        print('  - $id ${localName[id]}');
      }
      client.close();
    });
  }, timeout: const Timeout(Duration(minutes: 5)));
}
