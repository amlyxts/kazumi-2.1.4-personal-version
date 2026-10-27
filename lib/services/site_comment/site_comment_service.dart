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
    // 锚点切分: comment-index-text 出现即新条目开始
    final anchor = RegExp(r'<div[^>]*comment-index-text');
    final matches = anchor.allMatches(html).toList();
    for (var i = 0; i < matches.length; i++) {
      final start = matches[i].start;
      final end = i + 1 < matches.length
          ? matches[i + 1].start
          : html.length;
      try {
        items.add(_parseOne(html.substring(start, end)));
      } catch (_) {}
    }
    return items;
  }

  static SiteCommentItem _parseOne(String seg) {
    // 头行纯文本: "银河球棒侠  4天前" (comment-index-text 内容)
    final headMatch = RegExp(r'comment-index-text[^>]*>(.*?)</div>',
            dotAll: true)
        .firstMatch(seg);
    final headPlain = _plainText(headMatch?.group(1) ?? seg).trim();
    // 头行拆分: 用户名在前, 时间 (相对/日期) 在后
    final timeMatch = RegExp(
            r'(\d+\s*[天小时分钟周月秒]{1,3}前|\d{4}-\d{2}-\d{2}[^ ]{0,5})')
        .firstMatch(headPlain);
    final timeText = timeMatch?.group(1) ?? '';
    final user = headPlain
        .replaceAll(timeText, '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    // 内容: 头行 div 结束后到点赞/回复区之前的纯文本
    final bodyStart = headMatch?.end ?? 0;
    var content = '';
    if (bodyStart > 0) {
      final bodySeg = seg.substring(bodyStart);
      final contentMatch =
          RegExp(r'^(.*?)(?:more_vert|thumb_up|回覆|舉報|$)', dotAll: true)
              .firstMatch(_plainText(bodySeg));
      content = (contentMatch?.group(1) ?? '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }

    // 点赞数: thumb_up 后的数字 (取最大)
    final plain = _plainText(seg);
    var likes = 0;
    for (final m in RegExp(r'thumb_up\D{0,40}?(\d{1,6})').allMatches(plain)) {
      final v = int.tryParse(m.group(1)!) ?? 0;
      if (v > likes) likes = v;
    }

    // 回复数: load-replies-btn 计数
    final replyCount =
        RegExp(r'load-replies-btn').allMatches(seg).length;

    return SiteCommentItem(
      user: user.isEmpty ? '匿名' : user,
      timeText: timeText,
      content: content,
      likes: likes,
      replyCount: replyCount,
    );
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
