// 一次性工具 (非 CI): 设置实查 — 白名单/镜像/跳过 ID 映射缓存。
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
    print('WL_EXTRA=[${GStorage.getSetting(SettingsKeys.proxyWhitelistExtra)}]');
    // ignore: avoid_print
    print('PC_MIRROR_BASE=[${GStorage.getSetting(SettingsKeys.skipMirrorBase)}]');
    final tk = GStorage.getSetting(SettingsKeys.skipMirrorToken);
    // ignore: avoid_print
    print('TOKEN_FP=[${tk.isEmpty ? "<empty>" : tk.substring(0, 4)}]');

    final raw = GStorage.getSetting(SettingsKeys.skipTimeIdMap).trim();
    // ignore: avoid_print
    print('IDMAP_LEN=[${raw.length}]');
    if (raw.isNotEmpty) {
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        m.forEach((k, v) {
          if (v.toString() == '38062') {
            // ignore: avoid_print
            print('>>> 错映射: [$k] -> 38062');
          }
        });
        final keys = m.keys.take(40).toList();
        // ignore: avoid_print
        print('缓存键样例: $keys');
        // ignore: avoid_print
        print('缓存条目总数: ${m.length}');
      } catch (e) {
        // ignore: avoid_print
        print('IDMAP 解析失败: $e');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
