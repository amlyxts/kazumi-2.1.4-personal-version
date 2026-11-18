// [my新增] bgm.tv 网页搜索服务 — 里番收藏 bgm 关联的自动找 ID 通道。
//
// 背景: bgm API 搜索端点对 nsfw 条目硬过滤 (合规, 认证无效, 实测搜索/
// 收藏列表双端一致), 但网页版登录态搜索放行 — 用用户提供的网页 cookie
// 模仿浏览器搜索, 按 ID 直取端点拉全量元数据 (按 ID 未认证即放行, 实测)。
//
// 解析 = bgm 网页搜索是服务端渲染 HTML, 结构稳定多年:
//   多结果: <li id="item_{id}" class="item"> 内含 <a href="/subject/{id}" title="名">
//   单结果: 302 直达 /subject/{id} (整页为条目页, 无 item 块)
// 挑战/未登录: 返回页无结果块 → 空列表 (调用方提示 cookie 失效)。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kazumi/services/plugin/captcha_ocr_service.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/plugin/webview_page_fetch_service.dart';
import 'package:kazumi/services/storage/storage.dart';

class BgmWebSubject {
  const BgmWebSubject({required this.id, required this.name});
  final int id;
  final String name; // 页面展示名 (日文原名或中文, 用于相似度匹配)
}

class BgmWebService {
  BgmWebService._();


  static bool get isConfigured => _cookie.isNotEmpty;

  // —— [my新增] 自动登录 (bgm 表单 POST, 验证码默认不触发) ——

  /// 会话探针: 当前 cookie 是否有效 (搜一个常用词看有无结果块)。
  static Future<bool> cookieValid() async {
    if (_cookie.isEmpty) return false;
    try {
      final subjects = await search('bangumi');
      return subjects.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// 表单登录: GET /login (formhash + cookie jar) → POST /FollowTheRabbit。
  /// bgm 2026-11 起登录必带验证码 (captcha_challenge_field 必填): 首轮
  /// 裸 POST 必被 "验证码错误" 拒, 从失败响应页提取验证码图 src → OCR →
  /// 重试 (最多 3 轮)。成功 = 302 且 Set-Cookie 含登录态。
  /// 返回完整 cookie 串; 失败抛异常 (信息含原因)。
  static Future<String> webLogin(String email, String password) async {
    final jar = <String, String>{};
    String cookieHeader() =>
        jar.entries.map((e) => '${e.key}=${e.value}').join('; ');
    void eat(List<String> setCookies) {
      for (final set in setCookies) {
        final pair = set.split(';').first;
        final i = pair.indexOf('=');
        if (i > 0) jar[pair.substring(0, i)] = pair.substring(i + 1);
      }
    }

    // [my发现] bgm 主 JS (min/g=js) 内 chiiLib.login.genCaptcha: 注入
    // img src='/signup/captcha?<时间戳>' — 验证码图唯一来源; 服务端强制
    // captcha_challenge_field (缺 = "验证码错误"), 每次登录都必须取图。
    for (var attempt = 1; attempt <= 5; attempt++) {
      // 1) GET /login: formhash + 会话 cookie
      final lr = await _curlRequest('GET', 'https://bgm.tv/login',
          cookie: cookieHeader());
      eat(lr.setCookies);
      final formhash = RegExp(r'name="formhash"[^>]*value="([^"]*)"')
              .firstMatch(lr.body)
              ?.group(1) ??
          '';
      if (formhash.isEmpty) {
        throw Exception(
            'bgm 登录页不可达 (HTTP ${lr.statusCode}, 疑似限流, 请稍后再试)');
      }
      // 2) 取验证码图 → OCR (每轮新图)
      final captchaUrl =
          'https://bgm.tv/signup/captcha?${DateTime.now().millisecondsSinceEpoch}';
      final ir = await _curlRequest('GET', captchaUrl, cookie: cookieHeader());
      KazumiLogger().i(
          'BgmLogin: captcha HTTP ${ir.statusCode} ${ir.bytes.length}B');
      if (ir.statusCode != 200 || ir.bytes.isEmpty) {
        throw Exception('bgm 验证码获取失败 (HTTP ${ir.statusCode})');
      }
      final captchaAnswer = await CaptchaOcrService.solve(ir.bytes);
      KazumiLogger().i(
          'BgmLogin: OCR result=${captchaAnswer == null ? "null" : captchaAnswer}');
      if (captchaAnswer == null || captchaAnswer.trim().isEmpty) {
        throw Exception('bgm 登录验证码识别失败 (检查 OCR 渠道配置)');
      }
      // 3) POST /FollowTheRabbit
      final fields = <String, String>{
        'formhash': formhash,
        'referer': '',
        'dreferer': '',
        'email': email,
        'password': password,
        'captcha_challenge_field': captchaAnswer.trim(),
        'cookietime': '2592000',
        'loginsubmit': '登录',
      };
      final pr = await _curlRequest('POST', 'https://bgm.tv/FollowTheRabbit',
          cookie: cookieHeader(), formFields: fields);
      eat(pr.setCookies);
      // 成功 = 302 (且 Set-Cookie 发了记忆登录态)
      if (pr.statusCode == 302 &&
          (jar['chii_sec_id'] ?? '').isNotEmpty &&
          !(jar['chii_sec_id'] ?? '').startsWith('deleted')) {
        return cookieHeader();
      }
      final errText = RegExp(
              r'(验证码错误|密码错误|邮箱或密码|账号不存在|过于频繁|已停用|已删除)[^<]{0,40}')
          .firstMatch(pr.body)
          ?.group(0);
      KazumiLogger().w(
          'BgmLogin: attempt $attempt failed (HTTP ${pr.statusCode}) err=$errText');
    }
    throw Exception(
        '登录失败: 5 次尝试后仍未成功 (bgm 对非浏览器指纹强制验证码; 请改用手动贴 cookie: F12 → 网络 → 复制 Cookie 头)');
  }

  /// [核心] 使用前自动检查: cookie 空/失效 → 用存储的账号自动重登。
  /// 账号未配置时抛异常 (调用方引导填写)。返回可用 cookie。
  static Future<String> ensureCookie() async {
    // [my方案] Windows 搜索走 WebView 共享登录会话, 无需 cookie;
    // 自动登录 (webLogin) 被 bgm 指纹反爬封死, 保留给非 Windows
    if (Platform.isWindows) return '';
    final cookie = _cookie;
    if (cookie.isNotEmpty) {
      try {
        final ok = (await search('bangumi')).isNotEmpty;
        if (ok) return cookie;
      } catch (_) {}
    }
    final email = GStorage.getSetting(SettingsKeys.bgmAccountEmail).trim();
    final password =
        GStorage.getSetting(SettingsKeys.bgmAccountPassword).trim();
    if (email.isEmpty || password.isEmpty) {
      throw Exception('bgm 网页 cookie 缺失且未配置自动登录账号');
    }
    final fresh = await webLogin(email, password);
    GStorage.putSetting(SettingsKeys.bgmWebCookie, fresh);
    _cookieOverride = fresh;
    return fresh;
  }

  static String? _cookieOverride;

  /// [my新增] 手动保存 cookie 后调用: 清内存 override, 下次读设置里的新值
  static void resetCookieOverride() {
    _cookieOverride = null;
  }

  static String get _cookie =>
      _cookieOverride ??
      GStorage.getSetting(SettingsKeys.bgmWebCookie).trim();

  // —— [my新增] curl 传输层 — bgm 边缘按 TLS/HTTP 指纹拦 dart 栈
  // (实测同 UA/代理/参数: dart HttpClient 400, 系统 curl 200; 与
  // direct_search 的 CF 拦截同型, 系统 curl 走 Schannel 指纹可过)。
  static String? get _curlExe {
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final exe = '$root\\System32\\curl.exe';
    return File(exe).existsSync() ? exe : null;
  }

  static Directory? _curlWorkDir;

  static Future<_BgmCurlResponse> _curlRequest(String method, String url,
      {String cookie = '',
      bool followRedirects = false,
      Map<String, String>? formFields}) async {
    final exe = _curlExe;
    if (exe == null) {
      throw Exception('curl.exe 不可用 — bgm 网页线依赖系统 curl 传输');
    }
    final tmp =
        _curlWorkDir ??= await Directory.systemTemp.createTemp('kazumi-bgm-');
    final headFile = '${tmp.path}${Platform.pathSeparator}h.txt';
    final bodyFile = '${tmp.path}${Platform.pathSeparator}b.txt';
    // 代理语义与原 dart 栈一致: 默认走 Clash, KAZUMI_NO_CLASH=1 直连
    final proxy = Platform.environment['KAZUMI_NO_CLASH'] == '1'
        ? null
        : const ['--proxy', 'http://127.0.0.1:7897'];
    final args = <String>[
      '-s',
      '--max-time',
      '25',
      '-D',
      headFile,
      '-o',
      bodyFile,
      ...?proxy,
      '-A',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36',
      if (cookie.isNotEmpty) ...['-H', 'Cookie: $cookie'],
      if (method == 'POST') ...[
        '-X',
        'POST',
        '-H',
        'Content-Type: application/x-www-form-urlencoded',
        '--data-raw',
        (formFields ?? const {}).entries
            .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
            .join('&'),
      ],
      if (followRedirects) '-L',
      url,
    ];
    final r = await Process.run(exe, args);
    if (r.exitCode != 0) {
      throw Exception('curl 传输失败 (exit ${r.exitCode})');
    }
    final headText = await File(headFile).readAsString();
    final bytes = await File(bodyFile).readAsBytes();
    var statusCode = 0;
    final setCookies = <String>[];
    String? location;
    for (final rawLine in headText.split('\n')) {
      final line = rawLine.trim();
      final m = RegExp(r'^HTTP/[\d.]+\s+(\d{3})').firstMatch(line);
      if (m != null) {
        statusCode = int.parse(m.group(1)!);
        continue;
      }
      final i = line.indexOf(':');
      if (i <= 0) continue;
      final name = line.substring(0, i).toLowerCase();
      final value = line.substring(i + 1).trim();
      if (name == 'set-cookie') setCookies.add(value);
      if (name == 'location') location = value;
    }
    KazumiLogger().i(
        'BgmCurl: $method ${Uri.parse(url).host}${Uri.parse(url).path} -> $statusCode, ${bytes.length}B, redirects=${followRedirects ? "on" : "off"}, loc=${location ?? "-"}');
    return _BgmCurlResponse(
      statusCode: statusCode,
      setCookies: setCookies,
      location: location,
      body: utf8.decode(bytes, allowMalformed: true),
      bytes: bytes,
    );
  }

  /// 网页搜索: 返回候选条目 (id + 展示名)。空列表 = 无结果或未登录。
  ///
  /// [my方案] Windows 走 app 内嵌 WebView 抓取: bgm 边缘按 TLS 指纹给
  /// 降级会话 (curl/dart 带有效登录 cookie 也按未登录处理 — R18 过滤、
  /// 登录 POST 恒拒, 2026-11-20 全链实测), WebView 与登录页共享
  /// WebView2 用户数据目录 = 登录态 + 真指纹, nsfw 结果可见。
  /// 其余平台回落 curl cookie 线。
  static Future<List<BgmWebSubject>> search(String keyword,
      {String? cookieOverride}) async {
    final encoded = Uri.encodeComponent(keyword);
    final url = 'https://bgm.tv/subject_search/$encoded?cat=2';
    String html;
    if (Platform.isWindows) {
      html = await WebviewPageFetchService.instance.fetchHtml(url);
    } else {
      final cookie = cookieOverride ?? _cookie;
      if (cookie.isEmpty) {
        throw Exception('bgm 网页 cookie 未配置 (设置→里番收藏→bgm 关联设置)');
      }
      final rs = await _curlRequest('GET', url,
          cookie: cookie, followRedirects: true);
      html = rs.body;
    }

    KazumiLogger().i(
        'BgmWeb: parse ${html.length}B, containsItem=${html.contains('id="item_')}, containsLi=${html.contains('<li')}');
    // 单结果重定向: 最终落在条目页 (无 item 块, 有 nameSingle)
    if (!html.contains('id="item_')) {
      final single =
          RegExp(r'class="nameSingle"[^>]*>.*?href="/subject/(\d+)"', dotAll: true)
              .firstMatch(html);
      if (single != null) {
        final name =
            RegExp(r'<h1[^>]*title="([^"]*)"').firstMatch(html)?.group(1) ??
                RegExp(r'<h1[^>]*>([^<]+)</h1>').firstMatch(html)?.group(1) ??
                '';
        return [BgmWebSubject(id: int.parse(single.group(1)!), name: name)];
      }
      return const [];
    }

    // 多结果: 逐个 item 块解析
    final out = <BgmWebSubject>[];
    final itemSpans =
        RegExp(r'<li id="item_(\d+)"').allMatches(html).toList();
    for (var i = 0; i < itemSpans.length; i++) {
      final start = itemSpans[i].end;
      final end = i + 1 < itemSpans.length
          ? itemSpans[i + 1].start
          : html.length;
      final block = html.substring(start, end);
      final id = int.parse(itemSpans[i].group(1)!);
      // [my修复] 标题提取适配真实标记 (2026-11 实测 bgm 搜索结果块:
      // 封面锚点无文字 + <a href class="l">标题</a>, 无 title 属性也无
      // h3 — 原两种形状都不匹配, 全部条目被空标题丢弃 → 恒 0 条,
      // 搜索线自上线从未真正工作过)
      var title = '';
      for (final a in RegExp(
              r'<a[^>]*href="/subject/\d+"[^>]*>([^<]{2,120})</a>')
          .allMatches(block)) {
        final t = a.group(1)!.trim();
        if (t.isNotEmpty) {
          title = t;
          break;
        }
      }
      if (title.isEmpty) {
        title = RegExp(r'<a[^>]*href="/subject/\d+"[^>]*title="([^"]*)"')
                .firstMatch(block)
                ?.group(1) ??
            RegExp(r'<h3[^>]*>\s*<a[^>]*>([^<]+)</a>')
                .firstMatch(block)
                ?.group(1) ??
            '';
      }
      if (title.trim().isEmpty) continue;
      out.add(BgmWebSubject(id: id, name: title.trim()));
    }
    return out;
  }

  /// [my新增] webview 删除 bgm 收藏 — bgm 官方 API 无删除端点 (实测
  /// DELETE 405/404), 网页端删除 = GET /subject/{id}/remove?gh={formhash}
  /// (eraseSubjectCollect JS 复刻; GET 不触发指纹墙)。gh 从条目页
  /// interest/update?gh= 参数提取。返回是否成功。
  static Future<bool> removeSubjectCollectWeb(int subjectId) async {
    try {
      final html = await WebviewPageFetchService.instance
          .fetchHtml('https://bgm.tv/subject/$subjectId');
      final gh = RegExp(r'interest/update\?gh=([0-9a-f]+)')
              .firstMatch(html)
              ?.group(1) ??
          RegExp(r'name="formhash"[^>]*value="([0-9a-f]+)"')
              .firstMatch(html)
              ?.group(1);
      if (gh == null || gh.isEmpty) {
        KazumiLogger().w('BgmRemove: gh 提取失败 (subject $subjectId)');
        return false;
      }
      final after = await WebviewPageFetchService.instance.fetchHtml(
          'https://bgm.tv/subject/$subjectId/remove?gh=$gh');
      // 校验: 已收藏态的收藏框含"修改"内联窗链接; 移除后消失
      final stillCollected =
          after.contains('#TB_inline') && after.contains('修改');
      KazumiLogger().i(
          'BgmRemove: subject $subjectId remove done, stillCollected=$stillCollected');
      return !stillCollected;
    } catch (e) {
      KazumiLogger().w('BgmRemove: remove failed', error: e);
      return false;
    }
  }

  // —— 里番 bgm 关联映射 (JSON 持久: 收藏键 → 元数据) ——

  static Map<String, Map<String, dynamic>>? _mapCache;

  static Map<String, Map<String, dynamic>> loadMap() {
    if (_mapCache != null) return _mapCache!;
    final raw = GStorage.getSetting(SettingsKeys.adultBgmMap).trim();
    final parsed = <String, Map<String, dynamic>>{};
    if (raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((k, v) {
            if (v is Map) parsed[k.toString()] = Map<String, dynamic>.from(v);
          });
        }
      } catch (_) {}
    }
    return _mapCache = parsed;
  }

  static void saveMap() {
    _mapCache ??= {};
    GStorage.putSetting(SettingsKeys.adultBgmMap, jsonEncode(_mapCache));
  }

  /// 关联一条收藏 (键 = CollectedBangumi.key)
  static void associate(String collectKey,
      {required int bgmId,
      required String nameCn,
      required String name,
      required double score,
      required String coverUrl}) {
    final m = loadMap();
    m[collectKey] = {
      'bgmId': bgmId,
      'nameCn': nameCn,
      'name': name,
      'score': score,
      'coverUrl': coverUrl,
    };
    saveMap();
  }

  static void removeAssociation(String collectKey) {
    final m = loadMap();
    m.remove(collectKey);
    saveMap();
  }
}

/// curl 请求结果 (状态码 + set-cookie 列表 + 二进制体)
class _BgmCurlResponse {
  _BgmCurlResponse({
    required this.statusCode,
    required this.setCookies,
    required this.location,
    required this.body,
    required this.bytes,
  });

  final int statusCode;
  final List<String> setCookies;
  final String? location;
  final String body;
  final Uint8List bytes;
}
