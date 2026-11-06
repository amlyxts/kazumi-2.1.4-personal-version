// 手动诊断工具 (非 CI): WebView 依赖源的自动化播放检测 —
// 无头 Edge + CDP 网络嗅探 (Edge 与 app 的 WebView 同为 Chromium 内核,
// 观看页 JS 正常执行并发起真实视频请求, CDP 捕获请求与响应状态)。
// 覆盖源: 8 个 WebView 依赖源 × 海贼王; 单 Edge 实例全轮复用。
// ⚠ 环境: tester.runAsync 包真实 IO; HttpOverrides=null 恢复真实网络;
// path_provider/connectivity mock; GStorage 用沙盒副本。
// 运行 (仓库根):
//   ../tools/flutter3477/bin/flutter.bat test --no-pub test/manual_playback_check_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart' as hive_flutter;
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/plugin/rule_engine.dart';
import 'package:kazumi/services/storage/storage.dart';

const edgePath =
    r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe';
const debugPort = 9333;
const ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';
const sniffWindow = Duration(seconds: 16);

const sources = [
  'DM84',
  'mgnacg',
  'xfdmnext',
  'moonci',
  'aafun',
  'ezdmw',
  '7sefun',
  'sorani',
];

bool isMediaUrl(String url) {
  final l = url.toLowerCase();
  return l.contains('.m3u8') || l.contains('.mp4');
}

void mark(String msg) {
  File(r'C:\Users\liuxuan\Downloads\Kazumi-2.1.4\镜像隧道\playback_sweep.log')
      .writeAsStringSync('[${DateTime.now().toIso8601String()}] $msg\n',
          mode: FileMode.append, flush: true);
}

void main() {
  testWidgets('WebView 依赖源自动化播放检测 (关键词=海贼王)',
      (WidgetTester tester) async {
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
    // [关键] flutter_test 默认 _MockHttpOverrides (所有 HttpClient 400) —
    // 置 null 恢复真实网络 (本测试搜索/章节也要真实出网)
    HttpOverrides.global = null;

    final out = <String>[];
    await tester.runAsync(() async {
      // GStorage 沙盒副本初始化 (必须在 runAsync 内! FakeAsync 区真实 IO
      // 的 Future 永不完成 — 本次挂死根因)
      final staging = Directory.systemTemp.createTempSync('kazumi-wvcheck-');
      final srcHive = Directory(
          r'C:\Users\liuxuan\AppData\Roaming\com.example\kazumi\hive');
      final dstHive = Directory('${staging.path}/hive');
      await dstHive.create(recursive: true);
      await for (final f in srcHive.list()) {
        if (f is File && !f.path.endsWith('.lock')) {
          await f.copy('${dstHive.path}/${f.uri.pathSegments.last}');
        }
      }
      hive_flutter.Hive.init(dstHive.path);
      await GStorage.init();

      final dio = Dio(BaseOptions(
        validateStatus: (_) => true,
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
      ));
      final adapter = dio.httpClientAdapter;
      try {
        (adapter as dynamic).findProxy = (uri) => 'PROXY 127.0.0.1:7897';
      } catch (_) {}

      final raw = File(
              r'C:\Users\liuxuan\AppData\Roaming\com.example\kazumi\plugins\v2\plugins.json')
          .readAsStringSync();
      final plugins = (jsonDecode(raw) as List)
          .map((e) => Plugin.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      final byName = {
        for (final p in plugins) p.name: p,
      };

      // ── 启动无头 Edge (独立 profile, 全轮复用) ──
      final edgeProfile =
          Directory.systemTemp.createTempSync('kazumi-edge-profile-');
      final edge = await Process.start(edgePath, [
        '--headless=new',
        '--remote-debugging-port=9333',
        '--user-data-dir=${edgeProfile.path}',
        '--no-first-run',
        '--disable-gpu',
        '--window-size=1280,720',
        // 无头环境无用户手势 — 放开自动播放限制, 页面播放器才会发起视频请求
        '--autoplay-policy=no-user-gesture-required',
        'about:blank',
      ]);

      WebSocket? ws;
      try {
        // 等 CDP 端点就绪 (最多 15s)
        String pageWsUrl = '';
        final cdpHttp = HttpClient();
        for (var i = 0; i < 15; i++) {
          try {
            final list = await cdpHttp
                .getUrl(Uri.parse('http://127.0.0.1:9333/json/list'))
                .then((r) => r.close())
                .timeout(const Duration(seconds: 2));
            final body =
                await list.transform(const Utf8Decoder(allowMalformed: true)).join();
            final targets = jsonDecode(body) as List;
            for (final t in targets) {
              if (t is Map && t['type'] == 'page') {
                pageWsUrl = t['webSocketDebuggerUrl'].toString();
                break;
              }
            }
            if (pageWsUrl.isNotEmpty) break;
          } catch (_) {}
          await Future.delayed(const Duration(seconds: 1));
        }
        if (pageWsUrl.isEmpty) throw 'Edge CDP 端点未就绪';
        out.add('Edge 无头实例就绪 (CDP :9333)');
        mark('Edge 无头实例就绪 (CDP :9333)');

        // WebSocket 附着 + CDP 捕获
        final ws = await WebSocket.connect(pageWsUrl);
        final mediaRequestUrl = <String, String>{};
        final mediaResponseStatus = <String, String>{};
        var msgId = 0;
        void send(String method, [Map<String, dynamic>? params]) {
          msgId++;
          ws.add(jsonEncode({
            'id': msgId,
            'method': method,
            if (params != null) 'params': params,
          }));
        }

        ws.listen((data) {
          if (data is! String) return;
          try {
            final msg = jsonDecode(data);
            if (msg is! Map || !msg.containsKey('method')) return;
            final params = msg['params'];
            if (params is! Map) return;
            final rid = params['requestId']?.toString();
            if (rid == null) return;
            if (msg['method'] == 'Network.requestWillBeSent') {
              final url = params['request']?['url']?.toString() ?? '';
              if (isMediaUrl(url)) mediaRequestUrl[rid] = url;
            } else if (msg['method'] == 'Network.responseReceived') {
              if (mediaRequestUrl.containsKey(rid)) {
                mediaResponseStatus[rid] =
                    params['response']?['status']?.toString() ?? '?';
              }
            } else if (msg['method'] == 'Network.loadingFailed') {
              if (mediaRequestUrl.containsKey(rid) &&
                  !mediaResponseStatus.containsKey(rid)) {
                mediaResponseStatus[rid] =
                    '失败(${params['errorText'] ?? '未知'})';
              }
            }
          } catch (_) {}
        });

        send('Network.enable');
        send('Page.enable');
        await Future.delayed(const Duration(milliseconds: 300));

        // ── 逐源: 搜索 → 章节 → CDP 嗅探第一集 ──
        const title = '海贼王';
        final engine = RuleEngine();

        for (final name in sources) {
          final plugin = byName[name];
          if (plugin == null) {
            out.add('[$name] 插件不存在, 跳过');
            continue;
          }
          final sb = StringBuffer('===== $name ($title) =====\n${plugin.baseUrl}');
          try {
            final trace = await engine
                .search(plugin.healthConfig, title)
                .timeout(const Duration(seconds: 30));
            if (trace.response.data.isEmpty) {
              sb.write('\n搜索: 0 条 → 无法继续');
              out.add(sb.toString());
              mark('[$name] 搜索 0 条');
              continue;
            }
            var best = trace.response.data.first;
            for (final hit in trace.response.data) {
              if (hit.name.contains(title) || title.contains(hit.name)) {
                best = hit;
                break;
              }
            }
            sb.write('\n搜索: ${trace.response.data.length} 条, 命中=${best.name}');
            final chapterTrace = await engine
                .queryChapters(plugin.healthConfig, best.src)
                .timeout(const Duration(seconds: 30));
            var epCount = 0;
            String? firstEp;
            for (final r in chapterTrace.roads) {
              epCount += r.data.length;
              firstEp ??= r.data.isNotEmpty ? r.data.first : null;
            }
            sb.write('\n章节: ${chapterTrace.roads.length} 线路 / $epCount 集');
            if (firstEp == null) {
              sb.write('\n第一集链接缺失');
              out.add(sb.toString());
              mark('[$name] 无集链接');
              continue;
            }
            var pageUrl = firstEp!;
            if (pageUrl.startsWith('/')) pageUrl = '${plugin.baseUrl}$pageUrl';
            if (!pageUrl.startsWith('http')) {
              pageUrl = '${plugin.baseUrl}/$pageUrl';
            }
            sb.write('\n第一集: $pageUrl');

            // CDP 嗅探窗口: 回空白页停掉上一源播放, 清空捕获, 导航目标, 等待
            send('Page.navigate', {'url': 'about:blank'});
            await Future.delayed(const Duration(milliseconds: 1500));
            mediaRequestUrl.clear();
            mediaResponseStatus.clear();
            send('Page.navigate', {'url': pageUrl});
            mark('[$name] 嗅探中 ($pageUrl)');
            await Future.delayed(sniffWindow);

            if (mediaRequestUrl.isEmpty) {
              sb.write(
                  '\n嗅探: ${sniffWindow.inSeconds}s 内无视频请求 (解析超时同源症状)');
              out.add(sb.toString());
              mark('[$name] 无视频请求');
              continue;
            }
            sb.write('\n嗅探: ${mediaRequestUrl.length} 个视频请求');
            var playable = 0;
            for (final rid in mediaRequestUrl.keys) {
              final url = mediaRequestUrl[rid]!;
              final status = mediaResponseStatus[rid] ?? '无响应';
              sb.write(
                  '\n  [$status] ${url.length > 110 ? url.substring(0, 110) : url}');
              if (status == '200') playable++;
            }
            sb.write(playable > 0
                ? '\n判定: ✓ 可播 ($playable 个请求 200)'
                : '\n判定: ✗ 视频请求全部未成功');
            out.add(sb.toString());
            mark(
                '[$name] 判定: ${playable > 0 ? "可播 ($playable 个 200)" : "不可播"}');
          } catch (e, st) {
            final s = e.toString().replaceAll('\n', ' ');
            sb.write('\n!! 该源失败: ${s.substring(0, s.length.clamp(0, 90))}');
            out.add(sb.toString());
            mark('[$name] 失败: ${s.substring(0, s.length.clamp(0, 60))}');
            if (st.toString().contains('Handshake')) {}
          }
        }
      } catch (e) {
        out.add('!! 运行异常: $e');
      } finally {
        ws?.close();
        edge.kill();
        try {
          edgeProfile.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    var goodCount = 0;
    for (final line in out) {
      // ignore: avoid_print
      print(line);
      if (line.contains('判定: ✓')) goodCount++;
    }
    // ignore: avoid_print
    print('统计: ✓ 可播 $goodCount / ${sources.length}');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
