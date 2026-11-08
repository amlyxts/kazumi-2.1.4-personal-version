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

  /// 表单登录: GET /login 取 formhash → POST /FollowTheRabbit → 捕获 cookie。
  /// 返回新 cookie 串; 失败抛异常 (验证码触发时异常信息注明)。
  static Future<String> webLogin(String email, String password) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12)
      ..findProxy = (uri) =>
          Platform.environment['KAZUMI_NO_CLASH'] == '1'
              ? 'DIRECT'
              : 'PROXY 127.0.0.1:7897';
    client.userAgent =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';
    try {
      // 1) GET /login 取 formhash
      final loginPage = await client.getUrl(Uri.parse('https://bgm.tv/login'));
      loginPage.headers.set('Accept', 'text/html');
      final lrs = await loginPage.close().timeout(const Duration(seconds: 20));
      final loginHtml =
          await lrs.transform(const Utf8Decoder(allowMalformed: true)).join();
      final formhash = RegExp(r'name="formhash"[^>]*value="([^"]*)"')
              .firstMatch(loginHtml)
              ?.group(1) ??
          '';
      // 2) POST /FollowTheRabbit (重定向关闭, 手动捕 Set-Cookie)
      final post = await client.postUrl(Uri.parse('https://bgm.tv/FollowTheRabbit'));
      post.followRedirects = false;
      post.headers.set('Content-Type', 'application/x-www-form-urlencoded');
      final fields = {
        'formhash': formhash,
        'referer': '',
        'dreferer': '',
        'email': email,
        'password': password,
        'cookietime': '2592000',
        'loginsubmit': '登录',
      };
      post.add(utf8.encode(fields.entries
          .map((e) =>
              '${e.key}=${Uri.encodeQueryComponent(e.value)}')
          .join('&')));
      final prs = await post.close().timeout(const Duration(seconds: 25));
      final cookies = <String>[];
      for (final set in prs.headers['set-cookie'] ?? const <String>[]) {
        cookies.add(set.split(';').first);
      }
      final cookieStr = cookies.join('; ');
      if (cookieStr.isEmpty || prs.statusCode >= 400) {
        final errBody = await prs.transform(const Utf8Decoder(allowMalformed: true)).join();
        final needCaptcha = errBody.contains('captcha') &&
            !errBody.contains('display:none');
        throw Exception(
            '登录失败 (HTTP ${prs.statusCode}${needCaptcha ? ', 需要验证码' : ''})');
      }
      return cookieStr;
    } finally {
      client.close();
    }
  }

  /// [核心] 使用前自动检查: cookie 空/失效 → 用存储的账号自动重登。
  /// 账号未配置时抛异常 (调用方引导填写)。返回可用 cookie。
  static Future<String> ensureCookie() async {
    final cookie = _cookie;
    if (cookie.isNotEmpty) {
      try {
        final ok = (await _fetchSearch('bangumi')).isNotEmpty;
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

  static String get _cookie =>
      _cookieOverride ??
      GStorage.getSetting(SettingsKeys.bgmWebCookie).trim();

  /// 网页搜索: 返回候选条目 (id + 展示名)。空列表 = 无结果或 cookie 失效。
  static Future<List<BgmWebSubject>> search(String keyword,
      {String? cookieOverride}) async {
    final cookie = cookieOverride ?? _cookie;
    if (cookie.isEmpty) {
      throw Exception('bgm 网页 cookie 未配置 (设置→里番收藏→bgm 关联设置)');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12)
      ..findProxy = (uri) =>
          Platform.environment['KAZUMI_NO_CLASH'] == '1'
              ? 'DIRECT'
              : 'PROXY 127.0.0.1:7897';
    client.userAgent =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';
    try {
      final encoded = Uri.encodeComponent(keyword);
      final rq = await client.getUrl(Uri.parse(
          'https://bgm.tv/subject_search/$encoded?cat=2'));
      rq.headers.set('Cookie', cookie);
      rq.headers.set('Accept', 'text/html,application/xhtml+xml');
      rq.followRedirects = true;
      rq.maxRedirects = 5;
      final rs = await rq.close().timeout(const Duration(seconds: 25));
      final html = await rs.transform(const Utf8Decoder(allowMalformed: true)).join();

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
        final title =
            RegExp(r'<a[^>]*href="/subject/\d+"[^>]*title="([^"]*)"')
                    .firstMatch(block)
                    ?.group(1) ??
                RegExp(r'<h3[^>]*>\s*<a[^>]*>([^<]+)</a>').firstMatch(block)?.group(1) ??
                '';
        if (title.trim().isEmpty) continue;
        out.add(BgmWebSubject(id: id, name: title.trim()));
      }
      return out;
    } finally {
      client.close();
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
