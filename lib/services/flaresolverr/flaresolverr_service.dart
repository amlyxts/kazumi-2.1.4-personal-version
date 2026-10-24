// [my修改] FlareSolverr 客户端: 本地 CF 挑战求解服务 (无头浏览器渲染目标页,
// 返回过盾后的 HTML + cookies + UA)。
// 配置: 设置 → 网络 → FlareSolverr (地址留空 = 功能关闭)。
// 出口一致性: FlareSolverr 需与应用走同一代理出口 (配置代理地址指向 Clash),
// 否则求解得到的 cf_clearance 因 IP 不匹配对应用请求无效。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/video_source/video_source_service.dart';

class FlareSolverrSolution {
  FlareSolverrSolution({
    required this.html,
    required this.cookies,
    required this.userAgent,
  });

  final String html;
  final List<Map<String, dynamic>> cookies;
  final String userAgent;

  String get cookieString =>
      cookies.map((c) => '${c['name']}=${c['value']}').join('; ');
}

class FlareSolverrService {
  FlareSolverrService._();

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: Duration(seconds: 10),
    receiveTimeout: Duration(seconds: 90),
  ));

  // 环境变量优先 (QA 无头驱动用), 其次应用设置。
  static String? get _baseUrl {
    final env = Platform.environment['KAZUMI_FLARESOLVERR_URL'];
    if (env != null && env.trim().isNotEmpty) {
      return env.trim().replaceAll(RegExp(r'/+$'), '');
    }
    final raw = GStorage.getSetting(SettingsKeys.flareSolverrUrl).trim();
    if (raw.isEmpty) return null;
    return raw.replaceAll(RegExp(r'/+$'), '');
  }

  static String? get _proxyUrl {
    final env = Platform.environment['KAZUMI_FLARESOLVERR_PROXY'];
    if (env != null && env.trim().isNotEmpty) return env.trim();
    final raw = GStorage.getSetting(SettingsKeys.flareSolverrProxy).trim();
    return raw.isEmpty ? null : raw;
  }

  static bool get isConfigured => _baseUrl != null;

  // [my修改] 求解串行闸: 同一时间只跑一次求解; 排队者在当前求解完成后
  // 先用刷新的 cookies 重试快速通道, 能过就不再求解 (并发需求被一次
  // 求解吸收 — 下载队列并行解析/连点场景不再连环起浏览器)。
  static bool _solving = false;
  static Completer<void>? _solvingDone;
  // [my修改] 失败冷却: 求解失败 (FS 不可达/挑战过不去) 后 30s 内直接
  // 快速失败, 不连环陪等超时。
  static DateTime? _solveCooldownUntil;

  static bool get _cooldownActive =>
      _solveCooldownUntil != null &&
      DateTime.now().isBefore(_solveCooldownUntil!);

  /// CF 挑战页判定: 挑战页体积很小 (~KB 级), 正常页 >100KB —
  /// 体积阈值比类名匹配通用 (列表页/播放页/取集页通吃)。
  static bool _looksChallenged(String html) =>
      html.contains('challenge-platform') && html.length < 20000;

  /// 用持久化 cookies/UA 构造合成 solution (串行闸排队者快速通道
  /// 复用路径): html 为 curl 直取的正页。
  static FlareSolverrSolution _solutionFromCurl(String html) {
    final ck = GStorage.getSetting(SettingsKeys.flareSolverrCookies);
    final ua = GStorage.getSetting(SettingsKeys.flareSolverrUA);
    final cookies = <Map<String, dynamic>>[];
    for (final pair in ck.split(';')) {
      final i = pair.indexOf('=');
      if (i > 0) {
        cookies.add({
          'name': pair.substring(0, i).trim(),
          'value': pair.substring(i + 1),
        });
      }
    }
    return FlareSolverrSolution(html: html, cookies: cookies, userAgent: ua);
  }

  /// 求解 (带一次自动重试 + 串行闸 + 失败冷却)。
  static Future<FlareSolverrSolution?> solve(String url) async {
    if (_cooldownActive) return null;
    if (_solving) {
      await _solvingDone?.future;
      // 别人的求解刚刷新了 cookies: 快速通道先试, 过了就不排队求解
      final quick = await curlFetch(url, bypassCache: true);
      if (quick != null && !_looksChallenged(quick)) {
        KazumiLogger().i('FlareSolverr: 复用刚刷新的 cookies (免求解)');
        return _solutionFromCurl(quick);
      }
      if (_cooldownActive) return null;
      return solve(url); // 仍被挑战: 再等一轮 (现实中有界)
    }
    _solving = true;
    _solvingDone = Completer<void>();
    try {
      final first = await _solveOnce(url);
      if (first != null) {
        _solveCooldownUntil = null;
        return first;
      }
      await Future.delayed(const Duration(seconds: 2));
      KazumiLogger().i('FlareSolverr: 首次求解失败, 重试一次');
      final second = await _solveOnce(url);
      _solveCooldownUntil = second == null
          ? DateTime.now().add(const Duration(seconds: 30))
          : null;
      return second;
    } finally {
      _solving = false;
      _solvingDone?.complete();
      _solvingDone = null;
    }
  }

  static Future<FlareSolverrSolution?> _solveOnce(String url) async {
    final base = _baseUrl;
    if (base == null) return null;
    try {
      final proxyUrl = _proxyUrl;
      final resp = await _dio.post('$base/v1', data: {
        'cmd': 'request.get',
        'url': url,
        'maxTimeout': 60000,
        if (proxyUrl != null) 'proxy': {'url': proxyUrl},
      });
      final data = resp.data;
      if (data is! Map || data['status'] != 'ok') {
        KazumiLogger().w(
            'FlareSolverr: solve failed: ${data is Map ? data['message'] : 'bad response'}');
        return null;
      }
      final solution = data['solution'];
      if (solution is! Map || solution['response'] == null) return null;
      final result = FlareSolverrSolution(
        html: solution['response'].toString(),
        cookies: (solution['cookies'] as List? ?? [])
            .whereType<Map>()
            .map((c) => Map<String, dynamic>.from(c))
            .toList(),
        userAgent: (solution['userAgent'] ?? '').toString(),
      );
      // 过盾产物落盘: 浏览页 dio 快速通道跨重启复用 (首屏免求解)。
      // cf_clearance 与 UA/IP 绑定, 恢复时一并带上; 失效由挑战检测兜底。
      await GStorage.putSetting(
          SettingsKeys.flareSolverrCookies, result.cookieString);
      await GStorage.putSetting(SettingsKeys.flareSolverrUA, result.userAgent);
      return result;
    } catch (e) {
      KazumiLogger().w('FlareSolverr: request error: $e');
      return null;
    }
  }

  /// [my提速] 系统 curl 直取 HTML。CF 按 TLS 指纹拦 dart 栈 (同 cookies/UA/
  /// 代理下 curl 200 / dart 403), Schannel 指纹可过; cookies/UA 取过盾持久化。
  /// 返回 null = 无持久化 cookies / curl 不可用 / 请求失败。
  /// 带 30s 结果缓存: 播放链路里取集与直链解析抓同一 watch 页, 第二次免网络。
  static final Map<String, (DateTime, String)> _curlCache = {};

  static Future<String?> curlFetch(String url,
      {bool bypassCache = false}) async {
    if (!bypassCache) {
    final cached = _curlCache[url];
    if (cached != null) {
      if (DateTime.now().difference(cached.$1) < const Duration(seconds: 30)) {
        return cached.$2;
      }
      _curlCache.remove(url);
    }
    }
    final cookies = GStorage.getSetting(SettingsKeys.flareSolverrCookies);
    if (cookies.isEmpty) return null;
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final exe = '$root\\System32\\curl.exe';
    if (!File(exe).existsSync()) return null;
    try {
      final proxy = NetworkConfig.fromSettings().proxyForUri(Uri.parse(url));
      final ua = GStorage.getSetting(SettingsKeys.flareSolverrUA);
      final r = await Process.run(exe, [
        '-s',
        '--max-time',
        '20',
        if (proxy != null) ...['-x', 'http://${proxy.host}:${proxy.port}'],
        '-A',
        ua.isNotEmpty ? ua : 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
        '-H',
        'Cookie: $cookies',
        url,
      ], stdoutEncoding: utf8, stderrEncoding: utf8);
      final body = r.stdout.toString();
      if (r.exitCode != 0 || body.isEmpty) {
        KazumiLogger().w(
            'FlareSolverr: curl fetch null | exit=${r.exitCode} len=${body.length} stderr=${r.stderr.toString().trim()}');
        return null;
      }
      // 挑战页不进缓存: 否则 30s 内后续请求 (含求解后的复用) 会一直
      // 拿到挑战页误判
      if (!_looksChallenged(body)) {
        _curlCache[url] = (DateTime.now(), body);
        if (_curlCache.length > 6) {
          _curlCache.remove(_curlCache.keys.first);
        }
      }
      return body;
    } catch (e) {
      KazumiLogger().w('FlareSolverr: curl fetch error: $e');
      return null;
    }
  }

  /// 从播放页 HTML 提取主播放器正片直链 (质量取最高)。
  /// 该站页面为服务端渲染, 正片 mp4 直链写在 HTML 里; 页面上混有广告视频
  /// (动态注入), 嗅探会误抓 —— 直取直链从机制上规避广告。
  /// 返回 null = 页面里没有正片直链 (调用方回退嗅探)。
  static VideoSource? extractVideoFromHtml(String html, {int offset = 0}) {
    // 主播放器: <video id="player"> 内的 <source src="...">。CDN 域名会轮换
    // (实测 vdownload.hembed / cdn.emberglade 等), 按 id 定位而非域名。
    final playerMatch = RegExp(r'<video[^>]*id="player"[^>]*>(.*?)</video>',
            dotAll: true)
        .firstMatch(html);
    final block = playerMatch?.group(1) ?? '';
    final srcs = <String>{
      for (final m in RegExp(r'<source[^>]*src="([^"]+)"')
          .allMatches(block))
        m.group(1)!.replaceAll('&amp;', '&'),
    };
    // 兜底: 播放器块无 source 标签时, 找全页直链 mp4
    if (srcs.isEmpty) {
      srcs.addAll(RegExp(r'https?://[^\s"<>]+\.mp4\?[^"\s<>]+')
          .allMatches(html)
          .map((m) => m.group(0)!.replaceAll('&amp;', '&')));
    }
    // 质量取最高 (-NNNNp 命名)
    String? best;
    var bestQuality = -1;
    for (final src in srcs) {
      final quality = int.tryParse(
              RegExp(r'-(\d{3,4})p').firstMatch(src)?.group(1) ?? '') ??
          0;
      if (quality > bestQuality) {
        bestQuality = quality;
        best = src;
      }
    }
    if (best == null) {
      KazumiLogger().w('FlareSolverr: 播放页未解析出正片直链');
      return null;
    }
    // [my修复] 日志截断只认 ?secure=: CDN 轮换后直链带 ?token= 等参数时
    // indexOf 返回 -1, substring 抛 RangeError, 把成功的解析整个炸掉回退嗅探。
    final q = best.indexOf('?');
    KazumiLogger().i(
        'FlareSolverr: 正片直链 (${bestQuality}p) ${q < 0 ? best : best.substring(0, q)}');
    return VideoSource(
      url: best,
      offset: offset,
      type: VideoSourceType.online,
    );
  }

  /// [my新增] 启动预热: 校验/刷新过盾 cookies, 首次进入源直连浏览页
  /// 免过盾等待 (~11s)。cookies 仍有效时一次 curl 即完成 (~2s);
  /// 失效/缺失时后台 solve 一次并落盘新 cookies。幂等, 每次启动至多
  /// 一次 solve。
  static Future<void> warmupDirectSearch() async {
    try {
      final site = GStorage.getSetting(SettingsKeys.directSearchSite).trim();
      if (site.isEmpty || !isConfigured) return;
      final url = '${site.replaceAll(RegExp(r'/+$'), '')}/search';
      final cookies =
          GStorage.getSetting(SettingsKeys.flareSolverrCookies);
      if (cookies.isEmpty) {
        KazumiLogger().i('FlareSolverr: 预热 — 无缓存 cookies, 后台求解');
        await solve(url);
        return;
      }
      final html = await curlFetch(url);
      final challenged = html != null &&
          html.contains('challenge-platform') &&
          !html.contains('video-item-container');
      if (challenged) {
        KazumiLogger().i('FlareSolverr: 预热 — cookies 已失效, 后台刷新');
        await solve(url);
      } else if (html == null) {
        // curl 不可用/失败 (如代理未开): 用 solve 试一次, 成功同样落盘
        KazumiLogger().i('FlareSolverr: 预热 — curl 探测失败, 尝试求解');
        await solve(url);
      } else {
        KazumiLogger().i('FlareSolverr: 预热 — cookies 有效, 无需求解');
      }
    } catch (e) {
      KazumiLogger().w('FlareSolverr: warmup error: $e');
    }
  }

  /// 渲染播放页并提取主播放器正片直链。
  /// [my提速] curl 直取 (~2s) 优先; cookies 失效/被挑战时提取不到直链,
  /// 落回 FS 起浏览器求解 (~11s, 同时刷新持久化 cookies 供下次直取)。
  /// 返回 null = 未配置/求解失败/页面里没有正片直链 (调用方回退嗅探)。
  static Future<VideoSource?> resolveVideo(String url, {int offset = 0}) async {
    final viaCurlHtml = await curlFetch(url);
    if (viaCurlHtml != null) {
      final viaCurl = extractVideoFromHtml(viaCurlHtml, offset: offset);
      if (viaCurl != null) return viaCurl;
      KazumiLogger().i('FlareSolverr: curl 直取未提取到直链 (挑战页?), 落回 FS 求解');
    }
    final solution = await solve(url);
    if (solution == null) return null;
    return extractVideoFromHtml(solution.html, offset: offset);
  }
}
