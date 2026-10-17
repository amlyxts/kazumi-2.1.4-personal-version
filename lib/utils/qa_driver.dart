// [qa修改] 路线② 画质测试驱动入口 (与 tools/rule_qa 测试器联动)
// 用法: kazumi.exe --qa-play <规则名> <番名关键词> [--qa-output <json路径>]
//       [--qa-search-index n] [--qa-road n] [--qa-episode n] [--qa-timeout 秒]
// 无 UI 无头执行: 加载规则 → 规则站搜索 → 取集 → WebView 嗅探直链
// (与应用播放完全同一条解析链路, Windows 上 WebView 本就是 HeadlessWebview)
// → 结果 JSON 打到 stdout(QA_RESULT_JSON 前缀行)并可选落盘 → 自动退出
// 退出码: 0=成功拿到直链, 1=失败(见 JSON stage/error), 2=命令行用法错误
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/plugin/plugin_cookie_manager.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/video_source/video_source_service.dart';
import 'package:kazumi/services/video_source/webview_video_source_service.dart';
import 'package:kazumi/utils/http_headers.dart';
import 'package:path_provider/path_provider.dart';

const int qaExitOk = 0;
const int qaExitFailed = 1;
const int qaExitUsage = 2;

class _QaOptions {
  String pluginName = '';
  String keyword = '';
  String? outputPath;
  String? cookiesPath;
  int searchIndex = 1;
  int roadIndex = 1;
  int episodeIndex = 1;
  int resolveTimeoutSeconds = 30;
}

/// main() 入口调用: 检测 --qa-play 并接管进程 (调用方直接 return, 不再 runApp)
Future<void> runQaDriver(List<String> args) async {
  final stopwatch = Stopwatch()..start();
  final options = _parseArgs(args);
  Map<String, dynamic> result;
  var exitCode = qaExitFailed;
  if (options == null) {
    result = {
      'ok': false,
      'stage': 'usage',
      'error': '用法: kazumi.exe --qa-play <规则名> <番名关键词> '
          '[--qa-output <json路径>] [--qa-search-index n] [--qa-road n] '
          '[--qa-episode n] [--qa-timeout 秒]',
    };
    exitCode = qaExitUsage;
  } else {
    try {
      final r = await _runQa(options, stopwatch);
      result = r.$1;
      exitCode = r.$2;
    } catch (e) {
      result = _fail('unknown', '未预期异常: $e');
    }
  }
  result['durationMs'] = stopwatch.elapsedMilliseconds;
  await _emit(result, options?.outputPath);
  await stdout.flush();
  await stderr.flush();
  exit(exitCode);
}

Future<(Map<String, dynamic>, int)> _runQa(
  _QaOptions options,
  Stopwatch stopwatch,
) async {
  // QA 需独占 Hive 存储; 常驻实例在跑时快速失败并给出明确指引 (而非等 Hive 锁报错)
  final runningPid = await _detectRunningKazumi();
  if (runningPid != null) {
    return (
      _fail('kazumi-running',
          '检测到 Kazumi 正在运行 (PID $runningPid)。--qa-play 需独占存储, 请先手动关闭 Kazumi 再测'),
      qaExitFailed,
    );
  }

  // 存储初始化 (与 main.dart 相同的 hive 路径约定; QA 模式只读设置与规则, 不写)
  try {
    final hivePath = '${(await getApplicationSupportDirectory()).path}/hive';
    await Hive.initFlutter(hivePath);
    await GStorage.init();
  } catch (e) {
    // Hive 盒子文件锁被常驻实例持有时 (errno 33), QA 无法并发开库
    final msg = e.toString();
    final lockHint = msg.contains('errno = 33') || msg.contains('锁定')
        ? ' (Kazumi 正在运行? QA 驱动需独占存储, 请先关闭 Kazumi 再测)'
        : '';
    return (_fail('init', '存储初始化失败$lockHint: $e'), qaExitFailed);
  }

  final pluginsController = PluginsController();
  await pluginsController.init();
  Plugin? plugin;
  for (final candidate in pluginsController.pluginList) {
    if (pluginNameKey(candidate.name) == pluginNameKey(options.pluginName)) {
      plugin = candidate;
      break;
    }
  }
  if (plugin == null) {
    final installed = pluginsController.pluginList.map((p) => p.name).join(', ');
    return (
      _fail('plugin-not-found',
          '应用内未安装规则「${options.pluginName}」(已安装: $installed)'),
      qaExitFailed,
    );
  }

  // Cookie 注入桥: 测试器 (OCR 过码) 传来的 Cookie 喂给规则引擎, 免应用内验证码
  await _injectTesterCookies(options.cookiesPath, plugin);

  // 规则站搜索 (与应用 source_sheet 同一规则引擎)
  PluginSearchResponse response;
  try {
    response = await plugin
        .queryBangumi(options.keyword, shouldRethrow: true)
        .timeout(const Duration(seconds: 60));
  } on CaptchaRequiredException {
    return (
      _fail('captcha', '搜索触发验证码 (需先在应用内人工过一次验证)'),
      qaExitFailed,
    );
  } on NoResultException {
    return (_fail('no-result', '规则站搜索无结果'), qaExitFailed);
  } on TimeoutException {
    return (_fail('search-timeout', '搜索超时 (60s)'), qaExitFailed);
  } catch (e) {
    return (_fail('search', '搜索失败: $e'), qaExitFailed);
  }
  if (response.data.isEmpty) {
    return (_fail('no-result', '规则站搜索无结果'), qaExitFailed);
  }
  if (options.searchIndex < 1 || options.searchIndex > response.data.length) {
    return (
      _fail('search-index', '搜索序号越界 (共 ${response.data.length} 条)'),
      qaExitFailed,
    );
  }
  final searchItem = response.data[options.searchIndex - 1];

  // 取集 (与应用播放列表同一路径)
  List<Road> roads;
  try {
    roads = await plugin
        .queryChapterRoads(searchItem.src)
        .timeout(const Duration(seconds: 60));
  } on TimeoutException {
    return (_fail('chapters-timeout', '取集超时 (60s)'), qaExitFailed);
  } catch (e) {
    return (_fail('chapters', '取集失败: $e'), qaExitFailed);
  }
  if (roads.isEmpty) {
    return (_fail('no-chapters', '未取到任何线路'), qaExitFailed);
  }
  if (options.roadIndex < 1 || options.roadIndex > roads.length) {
    return (
      _fail('road-index', '线路序号越界 (共 ${roads.length} 条)'),
      qaExitFailed,
    );
  }
  final road = roads[options.roadIndex - 1];
  if (options.episodeIndex < 1 || options.episodeIndex > road.data.length) {
    return (
      _fail('episode-index', '集数序号越界 (线路「${road.name}」共 ${road.data.length} 话)'),
      qaExitFailed,
    );
  }
  final episodeTitle =
      options.episodeIndex <= road.identifier.length &&
              road.identifier[options.episodeIndex - 1].isNotEmpty
          ? road.identifier[options.episodeIndex - 1]
          : '第${options.episodeIndex}话';
  final episodeUrl = plugin.buildFullUrl(road.data[options.episodeIndex - 1]);

  // 直链嗅探 (与应用播放同一条 WebView 解析链路)
  final service = WebViewVideoSourceService();
  // [诊断] WebView 内部事件透传到 stdout (--qa-webview-log 常开, 便于定位解析卡点)
  final logSub = service.onLog.listen((log) {
    stdout.writeln('  [WebView] $log');
  });
  VideoSource source;
  try {
    source = await service.resolve(
      episodeUrl,
      useLegacyParser: plugin.useLegacyParser,
      timeout: Duration(seconds: options.resolveTimeoutSeconds),
    );
  } on VideoSourceTimeoutException {
    return (
      _fail('resolve-timeout', '直链嗅探超时 (${options.resolveTimeoutSeconds}s)'),
      qaExitFailed,
    );
  } catch (e) {
    return (_fail('resolve', '直链嗅探失败: $e'), qaExitFailed);
  } finally {
    await logSub.cancel();
    // 结果已确定, WebView 销毁不阻塞交付; exit() 兜底硬退出
    unawaited(
      service.dispose().timeout(const Duration(seconds: 5), onTimeout: () {}),
    );
  }

  final okResult = <String, dynamic>{
    'ok': true,
    'stage': 'resolved',
    'plugin': plugin.name,
    'keyword': options.keyword,
    'searchIndex': options.searchIndex,
    'matchedTitle': searchItem.name,
    'src': searchItem.src,
    'roadIndex': options.roadIndex,
    'roadName': road.name,
    'episodeIndex': options.episodeIndex,
    'episodeTitle': episodeTitle,
    'episodeUrl': episodeUrl,
    'videoUrl': source.url,
    'offset': source.offset,
    'format': source.format.name,
    'userAgent': plugin.userAgent.isEmpty ? getRandomUA() : plugin.userAgent,
    'referer': plugin.referer,
  };
  return (okResult, qaExitOk);
}

Map<String, dynamic> _fail(String stage, String error) {
  return {'ok': false, 'stage': stage, 'error': error};
}

/// Cookie 注入桥: 读取测试器传来的 Cookie 桥文件并注入 PluginCookieManager,
/// 让应用内搜索带上 OCR 过码会话, 免验证码
/// 文件格式: {"userAgent": "...", "cookies": {"domain": "k=v; k2=v2", ...}}
Future<void> _injectTesterCookies(String? path, Plugin plugin) async {
  if (path == null || path.isEmpty) return;
  try {
    final f = File(path);
    if (!f.existsSync()) {
      stdout.writeln('QA_COOKIE_BRIDGE: 文件不存在 $path');
      return;
    }
    final data = jsonDecode(f.readAsStringSync());
    if (data is! Map) return;
    final cookies = data['cookies'];
    if (cookies is! Map || cookies.isEmpty) return;
    final host = Uri.tryParse(plugin.baseUrl)?.host ?? '';
    if (host.isEmpty) {
      stdout.writeln('QA_COOKIE_BRIDGE: ${plugin.name} baseUrl 无效');
      return;
    }
    final matched = <String>[];
    cookies.forEach((domain, value) {
      final d = (domain as String?) ?? '';
      final v = (value as String?) ?? '';
      if (d.isEmpty || v.isEmpty) return;
      if (host == d || host.endsWith('.$d') || d.endsWith('.$host')) {
        matched.add(v);
      }
    });
    if (matched.isEmpty) {
      stdout.writeln(
          'QA_COOKIE_BRIDGE: ${plugin.name} 域($host)无匹配 Cookie (不注入)');
      return;
    }
    await PluginCookieManager.instance.saveFromWebView(
      plugin.name,
      plugin.baseUrl,
      matched.join('; '),
      userAgent: ((data['userAgent'] as String?) ?? '').trim(),
    );
    stdout.writeln(
        'QA_COOKIE_BRIDGE: 已为 ${plugin.name} 注入 ${matched.length} 段 Cookie ($host)');
  } catch (e) {
    stdout.writeln('QA_COOKIE_BRIDGE: 注入失败 $e');
  }
}

/// 检测是否有其他 kazumi.exe 进程在跑 (排除自身); tasklist 不可用时返回 null 放行
Future<String?> _detectRunningKazumi() async {
  try {
    final r = await Process.run('tasklist', [
      '/FO',
      'CSV',
      '/NH',
      '/FI',
      'IMAGENAME eq kazumi.exe',
    ]);
    for (final line in (r.stdout as String).split('\n')) {
      // CSV 行: "kazumi.exe","1234","Console","1","161,496 K"
      if (!line.contains('kazumi.exe')) continue;
      final cols = line.split('","');
      if (cols.length < 2) continue;
      final p = int.tryParse(cols[1].replaceAll('"', '').trim());
      if (p != null && p != pid) {
        return p.toString();
      }
    }
  } catch (_) {
    // 预检失败不阻塞, 交给存储初始化的锁错误兜底
  }
  return null;
}

/// 解析 --qa-play 之后的参数: 前两个位置参数为规则名与关键词, 其余为命名选项
_QaOptions? _parseArgs(List<String> args) {
  final idx = args.indexOf('--qa-play');
  if (idx < 0 || idx + 1 >= args.length) return null;
  final options = _QaOptions();
  final positional = <String>[];
  var i = idx + 1;
  while (i < args.length) {
    final arg = args[i];
    if (arg == '--qa-output' ||
        arg == '--qa-search-index' ||
        arg == '--qa-road' ||
        arg == '--qa-episode' ||
        arg == '--qa-timeout' ||
        arg == '--qa-cookies') {
      if (i + 1 >= args.length) return null;
      final value = args[i + 1];
      if (arg == '--qa-output') {
        options.outputPath = value;
      } else if (arg == '--qa-cookies') {
        options.cookiesPath = value;
      } else if (arg == '--qa-search-index') {
        options.searchIndex = int.tryParse(value) ?? 0;
      } else if (arg == '--qa-road') {
        options.roadIndex = int.tryParse(value) ?? 0;
      } else if (arg == '--qa-episode') {
        options.episodeIndex = int.tryParse(value) ?? 0;
      } else {
        options.resolveTimeoutSeconds = int.tryParse(value) ?? 0;
      }
      i += 2;
    } else {
      positional.add(arg);
      i++;
    }
  }
  if (positional.length < 2) return null;
  options.pluginName = positional[0];
  options.keyword = positional.sublist(1).join(' ');
  if (options.resolveTimeoutSeconds <= 0) {
    options.resolveTimeoutSeconds = 30;
  }
  return options;
}

Future<void> _emit(Map<String, dynamic> result, String? outputPath) async {
  stdout.writeln('QA_RESULT_JSON: ${jsonEncode(result)}');
  if (outputPath == null) return;
  try {
    const encoder = JsonEncoder.withIndent('  ');
    await File(outputPath).writeAsString(encoder.convert(result));
  } catch (e) {
    stdout.writeln('QA_RESULT_WRITE_ERROR: $e');
  }
}
