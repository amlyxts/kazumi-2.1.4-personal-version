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

/// [my新增] curl 抓取结果 (含状态码/响应头/耗时), 供精确挑战判定与计时日志
class CurlFetchResult {
  CurlFetchResult({
    required this.body,
    required this.statusCode,
    required this.headers,
    required this.elapsedMs,
    this.fromCache = false,
  });

  final String body;
  final int statusCode;

  /// 键已小写
  final Map<String, String> headers;
  final int elapsedMs;
  final bool fromCache;
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

  // [my新增] FS 持久会话: 浏览器实例常驻不销毁, 求解不再冷启动
  // (T2 实测临时实例 10.2s/次)。会话创建时固定出口代理 (FS 的 session
  // 与 per-request proxy 互斥, README 明示), 请求级不再传 proxy。
  static const String _fsSession = 'kazumi';
  static bool _sessionReady = false;

  /// [my修复] 真销毁会话: 原重建只调 create, FS 对已存在会话回
  /// "Session already exists" 并继续复用原浏览器 —— 浏览器僵死后
  /// (实测连 example.com 都解不动) request.get 全部耗满 maxTimeout,
  /// "重建"形同空操作, 翻页只能等 60s×2 然后超时。
  static Future<void> _destroySession() async {
    final base = _baseUrl;
    if (base == null) return;
    try {
      final resp = await _dio.post('$base/v1', data: {
        'cmd': 'sessions.destroy',
        'session': _fsSession,
      });
      final data = resp.data;
      final ok = data is Map && data['status'] == 'ok';
      KazumiLogger().w(
          'FlareSolverr: 会话销毁 ${ok ? "成功" : "失败"} (${data is Map ? (data['message'] ?? '') : ""})');
    } catch (e) {
      KazumiLogger().w('FlareSolverr: 会话销毁异常: $e');
    }
    _sessionReady = false;
  }

  static Future<void> _ensureSession({bool force = false}) async {
    final base = _baseUrl;
    if (base == null) return;
    if (_sessionReady && !force) return;
    if (force) await _destroySession();
    final sw = Stopwatch()..start();
    try {
      final proxyUrl = _proxyUrl;
      final resp = await _dio.post('$base/v1', data: {
        'cmd': 'sessions.create',
        'session': _fsSession,
        if (proxyUrl != null) 'proxy': {'url': proxyUrl},
      });
      final data = resp.data;
      final ok = data is Map && data['status'] == 'ok';
      final msg = data is Map ? (data['message'] ?? '').toString() : '';
      // 会话已存在视作就绪 (重复 create 不算失败)
      _sessionReady = ok || msg.toLowerCase().contains('already');
      KazumiLogger().w(
          'FlareSolverr: 会话创建 ${_sessionReady ? "成功" : "失败"} (${sw.elapsedMilliseconds}ms) $msg');
    } catch (e) {
      _sessionReady = false;
      KazumiLogger().w(
          'FlareSolverr: 会话创建异常 (${sw.elapsedMilliseconds}ms): $e');
    }
  }

  static bool get _cooldownActive =>
      _solveCooldownUntil != null &&
      DateTime.now().isBefore(_solveCooldownUntil!);

  /// CF 挑战页判定: 挑战页体积很小 (~KB 级), 正常页 >100KB —
  /// 体积阈值比类名匹配通用 (列表页/播放页/取集页通吃)。
  static bool _looksChallenged(String html) =>
      html.contains('challenge-platform') && html.length < 20000;

  /// [my新增] 精确挑战判定 (Suwayomi 同款): 状态码 403/503 且
  /// (Server 含 cloudflare || cf-mitigated: challenge) → 挑战;
  /// 头不可判时退回体积启发式。200 页面仅用启发式兜底
  /// (正常页也可能含 challenge-platform 脚本, 单看内容会误判)。
  /// [my升级] 200 大页面带显性挑战文案 (Just a moment / Attention
  /// Required / cf-challenge) 也判挑战 —— 实测存在 >100KB 的挑战页,
  /// 体积启发式漏判。
  static bool isChallengeResponse(CurlFetchResult r) {
    if (r.statusCode == 403 || r.statusCode == 503) {
      final server = r.headers['server'] ?? '';
      if (server.contains('cloudflare') ||
          (r.headers['cf-mitigated']?.contains('challenge') ?? false)) {
        return true;
      }
      return _looksChallenged(r.body);
    }
    final body = r.body;
    if (body.contains('Just a moment') ||
        body.contains('Attention Required') ||
        body.contains('cf-challenge')) {
      return true;
    }
    return _looksChallenged(body);
  }

  /// [my新增] 仅凭响应体的挑战判定 (规则引擎 dio 路径拿到的是纯 HTML, 无
  /// 头部/状态码可用时用): CF 显性文案 + 雷池 (SafeLine) JS 壳签名 + 体积启发。
  /// 雷池壳 ~500B, 签名 = JS 跳转 URL 带 ch=1&js= JWT, 体积上限防误伤正常页。
  static bool isChallengeBody(String html) {
    if (html.contains('Just a moment') ||
        html.contains('Attention Required') ||
        html.contains('cf-challenge') ||
        html.contains('请稍候') ||
        html.contains('请等待') ||
        html.contains('验证您')) {
      return true;
    }
    if (html.contains('ch=1&js=') && html.length < 5000) {
      return true;
    }
    return _looksChallenged(html);
  }

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
        KazumiLogger().w('FlareSolverr: 复用刚刷新的 cookies (免求解)');
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
      KazumiLogger().i('FlareSolverr: 首次求解失败, 重建会话后重试一次');
      // [my新增] 二次尝试前强制重建会话 (FS 重启/会话失效场景)
      await _ensureSession(force: true);
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
      await _ensureSession();
      final sw = Stopwatch()..start();
      final resp = await _dio.post('$base/v1', data: {
        'cmd': 'request.get',
        'url': url,
        // [my新增] 持久会话: 会话创建时已固定出口代理, 请求级不再传
        // proxy (session 与 per-request proxy 互斥, FS README 明示)
        'session': _fsSession,
        'session_ttl_minutes': 30,
        // [my调整] 60s → 40s: 求解基线 ~10s, 40s 仍有 4× 余量; 失败更快
        // 交给自愈链路 (重建+重试), 最坏等待不再拉到 2 分钟
        'maxTimeout': 40000,
      });
      final elapsed = sw.elapsedMilliseconds;
      final data = resp.data;
      if (data is! Map || data['status'] != 'ok') {
        final msg = data is Map
            ? (data['message'] ?? 'bad response').toString()
            : 'bad response';
        KazumiLogger().w(
            'FlareSolverr: solve failed (${elapsed}ms): $msg');
        // 会话丢失 (FS 重启) → 标记待重建, 外层重试会先重建会话
        if (msg.toLowerCase().contains('session')) _sessionReady = false;
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
      KazumiLogger().w(
          'FlareSolverr: solve ok (${elapsed}ms), cookies=${result.cookies.length}, 页面=${result.html.length}');
      // 过盾产物落盘: 浏览页 dio 快速通道跨重启复用 (首屏免求解)。
      // cf_clearance 与 UA/IP 绑定, 恢复时一并带上; 失效由挑战检测兜底。
      await GStorage.putSetting(
          SettingsKeys.flareSolverrCookies, result.cookieString);
      await GStorage.putSetting(SettingsKeys.flareSolverrUA, result.userAgent);
      return result;
    } catch (e) {
      // [my修复] FS 错误响应体带真实原因 (如 "Error solving the challenge.
      // Timeout after 55.0 seconds"), 原 toString 只见 DioException 壳,
      // 500 的根因 (会话僵死/站点硬盾) 无从判断
      var msg = e.toString();
      if (e is DioException) {
        final d = e.response?.data;
        if (d is Map && d['message'] != null) msg = d['message'].toString();
      }
      KazumiLogger().w('FlareSolverr: request error: $msg');
      // 求解超时/会话异常 → 会话标记待重建 (外层重试会 force 真重建)
      if (msg.contains('Timeout') || msg.toLowerCase().contains('session')) {
        _sessionReady = false;
      }
      return null;
    }
  }

  /// [my提速] 系统 curl 直取 HTML。CF 按 TLS 指纹拦 dart 栈 (同 cookies/UA/
  /// 代理下 curl 200 / dart 403), Schannel 指纹可过; cookies/UA 取过盾持久化。
  /// 返回 null = 无持久化 cookies / curl 不可用 / 请求失败。
  /// 带 30s 结果缓存: 播放链路里取集与直链解析抓同一 watch 页, 第二次免网络。
  static final Map<String, (DateTime, CurlFetchResult)> _curlCache = {};

  /// [my优化] curl 抓取的复用工作目录 (固定名覆盖写, 免每请求建删目录)
  static Directory? _curlWorkDir;

  /// [my优化] 共享的 curl 参数构造 (service/页面两处的 代理/UA/Cookie
  /// 拼装原本三处手写, 改代理逻辑容易漏)
  static List<String> buildCurlArgs({
    required String url,
    required String cookies,
    String userAgent = '',
    List<String> extra = const [],
  }) {
    final ua = userAgent.isNotEmpty
        ? userAgent
        : 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)';
    final proxy = NetworkConfig.fromSettings().proxyForUri(Uri.parse(url));
    return [
      '-s',
      ...extra,
      if (proxy != null) ...['-x', 'http://${proxy.host}:${proxy.port}'],
      '-A',
      ua,
      '-H',
      'Cookie: $cookies',
      url,
    ];
  }

  static Future<String?> curlFetch(String url,
      {bool bypassCache = false}) async {
    final r = await curlFetchDetailed(url, bypassCache: bypassCache);
    return r?.body;
  }

  /// [my升级] 详细版: 记录状态码/响应头/耗时 (精确挑战判定 + 计时日志),
  /// 头与体经临时文件分离 (-D/-o), 避免混流解析。
  static Future<CurlFetchResult?> curlFetchDetailed(String url,
      {bool bypassCache = false}) async {
    if (!bypassCache) {
      final cached = _curlCache[url];
      if (cached != null) {
        if (DateTime.now().difference(cached.$1) < const Duration(seconds: 30)) {
          return CurlFetchResult(
            body: cached.$2.body,
            statusCode: cached.$2.statusCode,
            headers: cached.$2.headers,
            elapsedMs: 0,
            fromCache: true,
          );
        }
        _curlCache.remove(url);
      }
    }
    final cookies = GStorage.getSetting(SettingsKeys.flareSolverrCookies);
    if (cookies.isEmpty) return null;
    final ua = GStorage.getSetting(SettingsKeys.flareSolverrUA);
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final exe = '$root\\System32\\curl.exe';
    if (!File(exe).existsSync()) return null;
    // [my优化] 临时目录复用 (原每请求 createTemp + recursive delete,
    // 热路径两次目录系统调用; 固定名覆盖写即可)
    final tmp = _curlWorkDir ??=
        await Directory.systemTemp.createTemp('kazumi-curl-');
    try {
      final headFile = '${tmp.path}${Platform.pathSeparator}headers.txt';
      final bodyFile = '${tmp.path}${Platform.pathSeparator}body.html';
      final sw = Stopwatch()..start();
      final r = await Process.run(
        exe,
        buildCurlArgs(
          url: url,
          cookies: cookies,
          userAgent: ua,
          extra: [
            '--max-time',
            '20',
            '-D',
            headFile,
            '-o',
            bodyFile,
          ],
        ),
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      final elapsed = sw.elapsedMilliseconds;
      final headText = await File(headFile).readAsString();
      final body = await File(bodyFile).readAsString();
      final status = int.tryParse(RegExp(r'HTTP/[\d.]+\s+(\d{3})')
              .firstMatch(headText)
              ?.group(1) ??
          '') ??
      0;
      final headers = <String, String>{
        for (final line in headText.split('\n').skip(1))
          if (line.contains(':'))
            line.substring(0, line.indexOf(':')).trim().toLowerCase():
                line.substring(line.indexOf(':') + 1).trim(),
      };
      if (r.exitCode != 0 || body.isEmpty) {
        KazumiLogger().w(
            'FlareSolverr: curl fetch null | ${elapsed}ms exit=${r.exitCode} status=$status len=${body.length} stderr=${r.stderr.toString().trim()}');
        return null;
      }
      final result = CurlFetchResult(
        body: body,
        statusCode: status,
        headers: headers,
        elapsedMs: elapsed,
      );
      // 挑战页不进缓存: 否则 30s 内后续请求 (含求解后的复用) 会一直
      // 拿到挑战页误判
      if (!isChallengeResponse(result)) {
        _curlCache[url] = (DateTime.now(), result);
        if (_curlCache.length > 6) {
          _curlCache.remove(_curlCache.keys.first);
        }
      }
      final challenged = isChallengeResponse(result);
      // [my优化] 成功且未超阈值回 INFO (不进日志文件防膨胀);
      // 慢/挑战保持 WARNING 与 SLOW 日志口径一致
      if (challenged || elapsed > 1500) {
        KazumiLogger().w(
            'FlareSolverr: curl ${elapsed}ms status=$status len=${body.length} 挑战=$challenged');
      } else {
        KazumiLogger().i(
            'FlareSolverr: curl ${elapsed}ms status=$status len=${body.length} 挑战=$challenged');
      }
      return result;
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
    // [my新增] MacCMS 系播放页: player_aaaa = {...,"url":"https://...m3u8",...}
    // (encrypt=0 明文; \/ 转义需还原)
    if (srcs.isEmpty) {
      final macMatch = RegExp(r'player_aaaa\s*=\s*(\{.*?\})\s*[;<]',
              dotAll: true)
          .firstMatch(html);
      if (macMatch != null) {
        try {
          final raw = macMatch.group(1)!.replaceAll(r'\/', '/');
          final obj = jsonDecode(raw);
          final u = obj is Map ? obj['url']?.toString() ?? '' : '';
          if (u.startsWith('http')) {
            KazumiLogger()
                .i('FlareSolverr: 正片直链 (MacCMS) ${u.indexOf('?') < 0 ? u : u.substring(0, u.indexOf('?'))}');
            return VideoSource(url: u, offset: offset, type: VideoSourceType.online);
          }
        } catch (_) {}
      }
    }
    // 兜底: 播放器块无 source 标签时, 找全页直链 mp4/m3u8
    if (srcs.isEmpty) {
      srcs.addAll(RegExp(r'https?://[^\s"<>]+\.(?:mp4|m3u8)[^"\s<>]*')
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

  /// [my新增] 预热完成信号: 源直连页在预热未完成且无页面缓存时等待它,
  /// 避免进页撞上冷启动求解。
  static Completer<void>? _warmupDone;
  static Future<void>? get warmupFuture => _warmupDone?.future;

  /// [my新增/提速] 启动预热: 先建 FS 持久会话 (浏览器实例常驻), 再校验/
  /// 刷新过盾 cookies。cookies 仍有效时一次 curl 即完成 (~2s); 失效/缺失
  /// 时 solve 一次并落盘新 cookies —— 会话常驻后求解不再冷启动 (T2 实测
  /// 临时实例 10.2s/次)。幂等, 并发调用共享同一轮预热。
  static Future<void> warmupDirectSearch() async {
    if (_warmupDone != null) return _warmupDone!.future;
    final done = Completer<void>();
    _warmupDone = done;
    final sw = Stopwatch()..start();
    try {
      final site = GStorage.getSetting(SettingsKeys.directSearchSite).trim();
      if (site.isEmpty || !isConfigured) return;
      // [my修复] 预热无条件真重建会话: 跨运行继承的会话浏览器可能已
      // 僵死 (实测复发), 只验 cookies 不验会话会让第一次挑战陪旧会话
      // 耗满 maxTimeout 才触发重建 — 每次启动换新浏览器 (~3s 后台开销),
      // 换取挑战来临时直接用健康会话求解
      await _ensureSession(force: true);
      final url = '${site.replaceAll(RegExp(r'/+$'), '')}/search';
      final cookies =
          GStorage.getSetting(SettingsKeys.flareSolverrCookies);
      if (cookies.isEmpty) {
        KazumiLogger().i('FlareSolverr: 预热 — 无缓存 cookies, 后台求解');
        await solve(url);
        return;
      }
      final fetch = await curlFetchDetailed(url);
      // [my修改] 挑战判定统一走 isChallengeResponse (状态码+响应头精确
      // 判定, 体积启发式兜底), 替换原先独立的一套内容启发式
      final challenged = fetch == null || isChallengeResponse(fetch);
      if (challenged) {
        KazumiLogger().w(
            'FlareSolverr: 预热 — cookies 已失效 (状态=${fetch?.statusCode ?? "无"}), 后台刷新');
        await solve(url);
      } else {
        KazumiLogger().w(
            'FlareSolverr: 预热 — cookies 有效 (${fetch.statusCode}, ${fetch.elapsedMs}ms), 无需求解');
      }
    } catch (e) {
      KazumiLogger().w('FlareSolverr: warmup error: $e');
    } finally {
      KazumiLogger().w('FlareSolverr: 预热完成 (${sw.elapsedMilliseconds}ms)');
      done.complete();
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
