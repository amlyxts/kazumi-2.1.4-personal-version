// 一次性工具 (非 CI): 插件同步诊断 — PC 侧开关状态 + 云端 plugins.json 实况。
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
  testWidgets('plugin sync diag', (WidgetTester tester) async {
    await tester.runAsync(() async {
      final staging = Directory.systemTemp.createTempSync('kazumi-psync-');
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
      final localPlugins = File(
          r'C:/Users\liuxuan/AppData/Roaming/com.example/kazumi/plugins/v2/plugins.json');
      if (localPlugins.existsSync()) {
        await localPlugins.copy(staging.path + '/local_plugins.json');
      }
      hive_flutter.Hive.init(dstHive.path);
      await GStorage.init();
      print('[stage] ready');

      // PC 侧开关 (键对象直读)
      // ignore: avoid_print
      print('FLAG webDavEnable = ${GStorage.getSetting(SettingsKeys.webDavEnable)}');
      // ignore: avoid_print
      print('FLAG webDavEnablePluginSync = ${GStorage.getSetting(SettingsKeys.webDavEnablePluginSync)}');
      // ignore: avoid_print
      print('FLAG webDavEnableHistory = ${GStorage.getSetting(SettingsKeys.webDavEnableHistory)}');
      // ignore: avoid_print
      print('FLAG webDavEnableSettingsSync = ${GStorage.getSetting(SettingsKeys.webDavEnableSettingsSync)}');
      // ignore: avoid_print
      print('webDavURL 非空 = ${GStorage.getSetting(SettingsKeys.webDavURL).trim().isNotEmpty}');

      // 云端 plugins.json 实况
      final url = GStorage.getSetting(SettingsKeys.webDavURL).trim();
      final user = GStorage.getSetting(SettingsKeys.webDavUsername).trim();
      final pass = GStorage.getSetting(SettingsKeys.webDavPassword).trim();
      if (url.isEmpty || user.isEmpty || pass.isEmpty) {
        print('CLOUD: 凭据不完整, 跳过云端检查');
        return;
      }
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..findProxy = (uri) =>
            Platform.environment['KAZUMI_NO_CLASH'] == '1'
                ? 'DIRECT'
                : 'PROXY 127.0.0.1:7897';
      client.userAgent = 'amlyxts/kazumi-maintenance';
      final base = url.endsWith('/') ? url : '$url/';
      // authtoken 基本认证
      final auth = base64Encode(utf8.encode('$user:$pass'));
      final rq = await client.openUrl(
          'GET', Uri.parse('${base}kazumiSync/plugins.json'));
      rq.headers.set('Authorization', 'Basic $auth');
      rq.headers.set('Accept', 'application/json');
      final rs = await rq.close().timeout(const Duration(seconds: 25));
      final text = await rs.transform(utf8.decoder).join();
      print('CLOUD plugins.json: HTTP ${rs.statusCode} | ${text.length}B');
      print('Last-Modified: ${rs.headers.value('last-modified') ?? '?'}');
      if (rs.statusCode != 200) {
        print('CLOUD 异常, 终止');
        client.close();
        return;
      }
      // 并集回灌: PC 本地 plugins.json ∪ 云端 → 上传
      final localFile = File(staging.path +
          '/local_plugins.json');
      final localRaw = localFile.readAsStringSync();
      final localList = (jsonDecode(localRaw) as List)
          .map((e) => (e as Map)['name'].toString())
          .toSet();
      final cloudList = <String>{};
      try {
        final cd = jsonDecode(text);
        final src = cd is Map ? (cd['plugins'] ?? cd) : cd;
        if (src is List) {
          for (final e in src) {
            cloudList.add((e as Map)['name'].toString());
          }
        }
      } catch (_) {}
      print('本地 ' + localList.length.toString() +
          ' | 云端 ' + cloudList.length.toString() +
          ' | 云端独有: ' + cloudList.difference(localList).toList().toString());
      final merged = jsonDecode(localRaw);
      // [探针] zzprobe 字段: iOS 拉取→导入→重传 会剥掉未知字段;
      // 字段仍在 = iOS 未触碰云端 (差分判定)
      for (final e in (merged as List)) {
        (e as Map)['zzprobe'] = 'v1';
      }
      try {
        final cd = jsonDecode(text);
        final src = cd is Map ? (cd['plugins'] ?? cd) : cd;
        if (src is List) {
          for (final e in src) {
            if (!localList.contains((e as Map)['name'])) {
              (merged as List).add(e);
            }
          }
        }
      } catch (_) {}
      final upReq = await client.openUrl('PUT',
          Uri.parse(base + 'kazumiSync/plugins.json'));
      upReq.headers.set('Authorization', 'Basic ' + auth);
      upReq.headers.set('Content-Type', 'application/json');
      upReq.add(utf8.encode(jsonEncode(merged)));
      final upRs = await upReq.close().timeout(const Duration(seconds: 30));
      print('回灌上传: HTTP ' + upRs.statusCode.toString() +
          ' | 最终条目 ' + (merged as List).length.toString());
      client.close();
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}
