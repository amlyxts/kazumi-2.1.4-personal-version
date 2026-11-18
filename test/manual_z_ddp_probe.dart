// 一次性探针: dandanplay 弹幕库访问验证 (同 app 签名链)。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/utils/crypto.dart';
import 'package:kazumi/utils/dandan_credentials.dart';

Future<String> ddpGet(String path) async {
  final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final sig = generateDandanSignature(path, timestamp);
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 12);
  client.findProxy = (uri) =>
      Platform.environment['KAZUMI_NO_CLASH'] == '1'
          ? 'DIRECT'
          : 'PROXY 127.0.0.1:7897';
  client.userAgent = 'amlyxts/kazumi-maintenance';
  final rq = await client.openUrl(
      'GET', Uri.parse('https://api.dandanplay.net$path'));
  rq.headers.set('X-Auth', '1');
  rq.headers.set('X-AppId', dandanCredentials['id']!);
  rq.headers.set('X-Timestamp', timestamp.toString());
  rq.headers.set('X-Signature', sig);
  rq.headers.set('Accept', 'application/json');
  final rs = await rq.close().timeout(const Duration(seconds: 20));
  final text = await rs.transform(utf8.decoder).join();
  client.close();
  return text;
}

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('ddp probe', (WidgetTester tester) async {
    HttpOverrides.global = null;
    await tester.runAsync(() async {
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    return r'C:\Users\liuxuan\AppData\Roaming\com.example\kazumi';
  });
  // 1) match: 找一个真实 episodeId (热门番 第一集)
  final matchBody = jsonEncode({
    'fileName': '[SubGroup] 葬送的芙莉莲 01 [1080p]',
    'fileSize': 734003200,
    'fileHash': '',
    'matchMode': 'keyword',
  });
  final mc = HttpClient();
  mc.connectionTimeout = const Duration(seconds: 12);
  mc.findProxy = (uri) => 'PROXY 127.0.0.1:7897';
  final mts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final mpath = '/api/v2/match';
  final mrq = await mc.openUrl(
      'POST', Uri.parse('https://api.dandanplay.net$mpath'));
  mrq.headers.set('Content-Type', 'application/json');
  mrq.headers.set('X-Auth', '1');
  mrq.headers.set('X-AppId', dandanCredentials['id']!);
  mrq.headers.set('X-Timestamp', mts.toString());
  mrq.headers.set('X-Signature', generateDandanSignature(mpath, mts));
  mrq.add(utf8.encode(matchBody));
  final mrs = await mrq.close().timeout(const Duration(seconds: 20));
  final mtext = await mrs.transform(utf8.decoder).join();
  mc.close();
  final m = jsonDecode(mtext);
  final matches = (m['matches'] ?? []) as List;
  print('match 命中: ${m['isMatched']} | 候选 ${matches.length}');
  if (matches.isEmpty) {
    print('match 原始: ${mtext.substring(0, mtext.length > 200 ? 200 : mtext.length)}');
    return;
  }
  final epId = matches.first['episodeId'];
  print('episodeId: $epId (${matches.first['animeTitle']} ${matches.first['episodeTitle']})');
  // 2) 拉弹幕
  final text = await ddpGet('/api/v2/comment/$epId?withRelated=true&chConvert=1');
  final d = jsonDecode(text);
  final comments = (d['comments'] ?? []) as List;
  print('弹幕 ${comments.length} 条');
  if (comments.isNotEmpty) {
    print('样例 p: ${(comments.first)['p']}');
    print('样例 p 解析: time/mode/color/userId = ${(comments.first)['p'].split(',').take(4).join(" / ")}');
  }
    });
  }, timeout: const Timeout(Duration(minutes: 2)));
}
