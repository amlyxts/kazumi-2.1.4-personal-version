// [my新增] 源站评论服务 — 里番播放页评论 Tab 的只读数据源。
// 端点 (实测 200): GET /loadComment?id=<videoId>&type=video
//   &content=comment-tabcontent-loaded
// 返回 JSON {"comments": "<整段评论 HTML>", "content": ...}
// 单条评论特征 (样本已采): comment-index-text (楼层) / img-circle (头像,
// alt=用户名) / report-btn-wrapper (条目边界) / thumb_up+数字 (点赞) /
// load-replies-btn (回复懒加载按钮, 初版只显示计数)。
// 通道: 系统 curl 快速通道 (cookies/UA/白名单代理复用), 挑战页回落由
// 调用方提示手动刷新。只读 — 不登录不发评不点赞。
import 'dart:convert';
import 'dart:io';

import 'package:kazumi/request/core/network_config.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';

class SiteCommentItem {
  const SiteCommentItem({
    required this.user,
    required this.timeText,
    required this.content,
    this.likes = 0,
    this.replyCount = 0,
  });

  final String user;
  final String timeText;
  final String content;
  final int likes;
  final int replyCount;
}

class SiteCommentService {
  SiteCommentService._();

  static final SiteCommentService instance = SiteCommentService._();

  /// 从播放页地址提取视频 id (watch?v=<数字>)
  static String? videoIdFromUrl(String pageUrl) {
    final m = RegExp(r'watch\?v=(\d+)').firstMatch(pageUrl);
    return m?.group(1);
  }

  String? get _curlExe {
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final exe = '$root\\System32\\curl.exe';
    return File(exe).existsSync() ? exe : null;
  }

  /// 拉取并解析评论列表。失败/无评论返回空表 (调用方展示空态)。
  Future<List<SiteCommentItem>> loadComments(String pageUrl) async {
    final videoId = videoIdFromUrl(pageUrl);
    if (videoId == null) return const [];
    final cookies =
        GStorage.getSetting(SettingsKeys.flareSolverrCookies);
    if (cookies.isEmpty) return const [];
    final exe = _curlExe;
    if (exe == null) return const [];
    try {
      final url = 'https://hanime1.me/loadComment'
          '?id=$videoId&type=video&content=comment-tabcontent-loaded';
      final proxy =
          NetworkConfig.fromSettings().proxyForUri(Uri.parse(url));
      final ua = GStorage.getSetting(SettingsKeys.flareSolverrUA);
      final r = await Process.run(exe, [
        '-s',
        '--max-time',
        '25',
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
            'SiteComment: load null | exit=${r.exitCode} len=${body.length}');
        return const [];
      }
      final decoded = jsonDecode(body);
      if (decoded is! Map || decoded['comments'] is! String) {
        return const [];
      }
      return parseCommentsHtml(decoded['comments'] as String);
    } catch (e) {
      KazumiLogger().w('SiteComment: load failed: $e');
      return const [];
    }
  }

  /// 解析评论 HTML。comment-index-text (用户名+时间的头行) 是每个
  /// 条目的锚点; 条目正文为其后到下一锚点之间。回复懒加载按钮计数。
  static List<SiteCommentItem> parseCommentsHtml(String html) {
    final items = <SiteCommentItem>[];
    // [my修复] 分条容器 = report-btn-wrapper (66 组, 每组 = 头行+内容+
    // 回复区)。曾误用 comment-index-text (132 个: 66 主楼 + 66 回复者
    // 头行), 回复者头行被当新评论 → 主楼段被腰斩、内容全空 (字段二次
    // 错位的根因)。容器内头行/内容/回复由 _parseOne 处理。
    final anchor = RegExp(r'report-btn-wrapper');
    final matches = anchor.allMatches(html).toList();
    for (var i = 0; i < matches.length; i++) {
      final start = matches[i].start;
      final end = i + 1 < matches.length
          ? matches[i + 1].start
          : html.length;
      try {
        final item = _parseOne(html.substring(start, end));
        if (item.content.isNotEmpty) items.add(item);
      } catch (_) {}
    }
    return items;
  }

  static SiteCommentItem _parseOne(String seg) {
    // [my修复] 响应是 JSON 字符串: </div> 写作 <\/div> (字面反斜杠),
    // 中文是 \uXXXX 转义 — 提取前先 JSON 解码, 尾锚用 RegExp.escape
    // 匹配字面形态 (验证脚本按真实样本逐步确认)。
    final decoded = _jsonUnescape(seg);
    final closeDiv = RegExp.escape('</div>');
    final headMatch = RegExp(
            'comment-index-text[^>]*>(.*?)$closeDiv',
            dotAll: true)
        .firstMatch(decoded);
    final headPlain = _plainText(headMatch?.group(1) ?? decoded).trim();
    // 头行拆分: 用户名在前, 时间 (相对/日期) 在后
    final timeMatch = RegExp(
            r'(\d+\s*[天小时分钟周月秒]{1,3}前|\d{4}-\d{2}-\d{2}[^ ]{0,5})')
        .firstMatch(headPlain);
    final timeText = timeMatch?.group(1) ?? '';
    final user = headPlain
        .replaceAll(timeText, '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    // 内容: 头行结束后到回复区/操作条之前 (回复区先截 — thumb_up 在
    // more_vert 之后, 只截操作条会把点赞数字带进内容)
    final bodyStart = headMatch?.end ?? 0;
    var content = '';
    if (bodyStart > 0) {
      final bodySeg = decoded.substring(bodyStart);
      final mainZone = bodySeg.split('reply-section-wrapper').first;
      final mainCut = mainZone.split('more_vert').first;
      content = _plainText(mainCut)
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }

    // 点赞数: thumb_up 后的数字 (全段抓取取最大, 含回复区内的)
    final plain = _plainText(decoded);
    var likes = 0;
    for (final m in RegExp(r'thumb_up\D{0,40}?(\d{1,6})').allMatches(plain)) {
      final v = int.tryParse(m.group(1)!) ?? 0;
      if (v > likes) likes = v;
    }

    // 回复数: load-replies-btn 计数
    final replyCount =
        RegExp(r'load-replies-btn').allMatches(decoded).length;

    return SiteCommentItem(
      user: user.isEmpty ? '匿名' : user,
      timeText: timeText,
      content: content,
      likes: likes,
      replyCount: replyCount,
    );
  }

  /// JSON 字符串体解码: \uXXXX (中文) / \n / \" / <\/div> 转义还原。
  /// [my新增] 响应整段是 JSON 字符串值, 未解码则中文与转义标记会污染
  /// 所有下游解析 (字段错位根因之一)。
  static String _jsonUnescape(String raw) {
    try {
      // 依序转义: 先反斜杠 (避免二次转义), 再引号, 再控制字符;
      // 转义后的串包进 JSON 引号即可 jsonDecode 还原
      final escaped = raw
          .replaceAll('\\', '\\\\')
          .replaceAll(r'"', r'\"')
          .replaceAll('\n', '\\n')
          .replaceAll('\r', '\\r')
          .replaceAll('\t', '\\t');
      return jsonDecode('"$escaped"') as String;
    } catch (_) {
      return raw; // 解码失败原样返回 (字段可能带转义, 比崩溃好)
    }
  }

  /// HTML → 纯文本 (剥标签, &nbsp; 等实体还原, 压空白)
  static String _plainText(String html) {
    var t = html
        .replaceAll(RegExp(r'<script[^>]*>.*?</script>', dotAll: true), ' ')
        .replaceAll(RegExp(r'<style[^>]*>.*?</style>', dotAll: true), ' ')
        .replaceAll(RegExp(r'<br\s*/?>'), '\n')
        .replaceAll(RegExp(r'</(?:p|div|li)>'), '\n');
    t = t.replaceAll('&nbsp;', ' ').replaceAll('&amp;', '&');
    t = t.replaceAll('&lt;', '<').replaceAll('&gt;', '>');
    t = t.replaceAll('&quot;', '"').replaceAll('&#39;', "'");
    t = t.replaceAll(RegExp(r'<[^>]+>'), ' ');
    return t.replaceAll(RegExp(r'[ \t]+'), ' ');
  }
}
