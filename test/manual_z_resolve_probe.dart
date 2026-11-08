// 一次性工具 (非 CI): bgm 错挂校验复现 — 103010 (赛博格クロちゃん) 应被
// 识别并重定位到 薬屋のひとりごと 的正确 AniList id。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart' as hive_flutter;
import 'package:kazumi/services/skip/skip_time_service.dart';
import 'package:kazumi/services/storage/storage.dart';

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    return r'C:\Users\liuxuan\AppData\Roaming\com.example\kazumi';
  });
  HttpOverrides.global = null;
  test('bgm 错挂重定位', () async {
    final staging = Directory.systemTemp.createTempSync('kazumi-resolve-');
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
    final malId = await SkipTimeService.resolveMalIdForSubject(
      isBgmSubject: true,
      subjectId: 103010,
      fallbackName: 'サイボーグクロちゃん',
      itemTitleCn: '药屋少女的呢喃第三季',
    );
    // ignore: avoid_print
    print('RESOLVED malId = $malId (期望: 薬屋S3 的正确 id, 绝不是 38062)');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
