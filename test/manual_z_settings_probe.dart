// 一次性工具 (非 CI): 白名单实查 — 沙盒副本读 proxyWhitelistExtra。
// 运行 (仓库根): ../tools/flutter3477/bin/flutter.bat test --no-pub test/manual_z_settings_probe.dart
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart' as hive_flutter;
import 'package:kazumi/services/storage/storage.dart';

void main() {
  testWidgets('settings probe', (WidgetTester tester) async {
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

    await tester.runAsync(() async {
      final staging = Directory.systemTemp.createTempSync('kazumi-wlprobe-');
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
      final tk = GStorage.getSetting(SettingsKeys.skipMirrorToken);
      print('PC_TOKEN_FP=[${tk.isEmpty ? '<empty>' : tk.substring(0, 4)}] len=${tk.length}');
      print('PC_MIRROR_BASE=[${GStorage.getSetting(SettingsKeys.skipMirrorBase)}]');
      // ignore: avoid_print
      print('DS_SITE=[${GStorage.getSetting(SettingsKeys.directSearchSite)}]');
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}
