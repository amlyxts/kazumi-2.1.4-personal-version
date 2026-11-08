// 一次性工具 (非 CI): bgm 收藏端点 nsfw 行为验证 — 带认证拉取用户收藏,
// 统计 nsfw=True 条目是否存在 (决定里番统一方案的成败)。
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
  testWidgets('bgm collections nsfw probe', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final staging = Directory.systemTemp.createTempSync('kazumi-bgmcol-');
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
      final token =
          GStorage.getSetting(SettingsKeys.bangumiAccessToken).trim();
      print('[token] ${token.isEmpty ? "<未配置>" : "len=${token.length}"}');
      if (token.isEmpty) {
        print('VERDICT: 无 bgm token — app 内未授权 Bangumi');
        return;
      }

      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 12)
        ..findProxy = (uri) => 'PROXY 127.0.0.1:7897';
      client.userAgent = 'amlyxts/kazumi-maintenance';
      // 先取用户名 (collections 端点不支持 '-' 简写)
      final meRq = await client.openUrl(
          'GET', Uri.parse('https://api.bgm.tv/v0/me'));
      meRq.headers.set('Accept', 'application/json');
      meRq.headers.set('Authorization', 'Bearer ' + token);
      final meRs = await meRq.close().timeout(const Duration(seconds: 20));
      final meText = await meRs.transform(utf8.decoder).join();
      final me = jsonDecode(meText);
      final username = (me['username'] ?? '').toString();
      print('[me] username=$username');
      // 收藏列表 (want=1)
      var nsfwCount = 0;
      var totalCount = 0;
      final nsfwSamples = <String>[];
      for (final offset in [0, 100, 200, 300, 400]) {
        final rq = await client.openUrl('GET',
            Uri.parse('https://api.bgm.tv/v0/users/$username/collections?limit=100&offset=$offset'));
        rq.headers.set('Accept', 'application/json');
        rq.headers.set('Authorization', 'Bearer ' + token);
        final rs = await rq.close().timeout(const Duration(seconds: 25));
        final text = await rs.transform(utf8.decoder).join();
        print('[collections offset=$offset] HTTP ${rs.statusCode}');
        if (rs.statusCode != 200) {
          print('body: ${text.substring(0, text.length > 150 ? 150 : text.length)}');
          continue;
        }
        final d = jsonDecode(text);
        final data = (d['data'] ?? []) as List;
        totalCount = d['total'] ?? totalCount;
        print('[total 字段] ${d['total']} | 本页 ${data.length} 条 | 全部 ID: ' +
            data.map((c) {
              final subj = c['subject'];
              return subj == null ? '?' : '${subj['id']}(${c['type']})';
            }).join(','));
        for (final c in data) {
          final subject = c['subject'];
          if (subject == null) continue;
          final nsfw = subject['nsfw'] == true;
          if (nsfw) {
            nsfwCount++;
            if (nsfwSamples.length < 5) {
              nsfwSamples.add(
                  '${subject['id']} ${(subject['name_cn'] ?? subject['name'] ?? '').toString().substring(0, (subject['name_cn'] ?? subject['name'] ?? '').toString().length > 20 ? 20 : (subject['name_cn'] ?? subject['name'] ?? '').toString().length)}');
            }
          }
        }
        print('[collections] 本页 ${data.length} 条 | nsfw=True: $nsfwCount');
        print('[total 字段] ${d['total']}');
      }
      print('VERDICT: 收藏端点返回 nsfw 条目 = ${nsfwCount > 0 ? "是 (同步路线成立)" : "本页未见 (需在 bgm 网页先标一部里番想看再复测)"}');
      if (nsfwSamples.isNotEmpty) print('nsfw 样例: $nsfwSamples');
      client.close();
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}
