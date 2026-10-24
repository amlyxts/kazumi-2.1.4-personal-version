// [my新增] DLsite 元数据服务: 源直连浏览的同人/Motion Anime 子集增强源。
// 用途: 卡片手动关联 DLsite 作品 → 补社团/系列名/卷号/系列总数/评分。
// 访问: DLsite 直连不可达 (国际站点), proxyEnable 时强制走代理;
// CF 对 dart TLS 指纹的拦截在部分站点存在, 统一走 System32 curl (Schannel)。
// 端点 (实测 200):
//   搜索: /maniax/fsr/=/keyword/<enc>/work_type_category[0]/doujin/per_page/30/
//   详情: /maniax/product/info/ajax?product_id=RJxxxxxx  (JSON, 83 字段)
import 'dart:convert';
import 'dart:io';

import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/proxy_utils.dart';
import 'package:kazumi/services/storage/storage.dart';

class DlsiteWork {
  DlsiteWork({
    required this.id,
    this.title = '',
    this.maker = '',
    this.thumb = '',
    this.seriesName = '',
    this.volume = '',
    this.seriesCount = 0,
    this.rating = 0.0,
    this.dlCount = 0,
  });

  final String id;
  final String title;
  final String maker;
  final String thumb;
  final String seriesName;
  final String volume;
  final int seriesCount;
  final double rating;
  final int dlCount;

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'maker': maker,
        'thumb': thumb,
        'seriesName': seriesName,
        'volume': volume,
        'seriesCount': seriesCount,
        'rating': rating,
        'dlCount': dlCount,
      };

  static DlsiteWork fromMap(Map<String, dynamic> m) => DlsiteWork(
        id: (m['id'] ?? '').toString(),
        title: (m['title'] ?? '').toString(),
        maker: (m['maker'] ?? '').toString(),
        thumb: (m['thumb'] ?? '').toString(),
        seriesName: (m['seriesName'] ?? '').toString(),
        volume: (m['volume'] ?? '').toString(),
        seriesCount: (m['seriesCount'] as num?)?.toInt() ?? 0,
        rating: (m['rating'] as num?)?.toDouble() ?? 0,
        dlCount: (m['dlCount'] as num?)?.toInt() ?? 0,
      );
}

class DlsiteService {
  DlsiteService._();

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  /// DLsite 直连不可达, proxyEnable 时强制走代理 (不走白名单判定)。
  static String? get _proxy {
    if (!GStorage.getSetting(SettingsKeys.proxyEnable)) return null;
    final parsed =
        ProxyUtils.parseProxyUrl(GStorage.getSetting(SettingsKeys.proxyUrl));
    if (parsed == null) return null;
    return 'http://${parsed.$1}:${parsed.$2}';
  }

  static Future<String?> _curlGet(String url) async {
    final root = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final exe = '$root\\System32\\curl.exe';
    if (!File(exe).existsSync()) return null;
    try {
      final proxy = _proxy;
      final r = await Process.run(exe, [
        '-s',
        '--max-time',
        '20',
        if (proxy != null) ...['-x', proxy],
        '-A',
        _ua,
        url,
      ], stdoutEncoding: utf8, stderrEncoding: utf8);
      final body = r.stdout.toString();
      if (r.exitCode != 0 || body.isEmpty) {
        KazumiLogger().w(
            'DLsite: curl null | exit=${r.exitCode} len=${body.length} stderr=${r.stderr.toString().trim()}');
        return null;
      }
      return body;
    } catch (e) {
      KazumiLogger().w('DLsite: curl error: $e');
      return null;
    }
  }

  /// 关键词检索 (每页 30, 不限分类 — 商业作品不在同人分类内, 过滤会漏)。
  /// 标题在 work_name 锚点 title 属性, 社团在 maker_name 锚点文本。
  /// 注意 DLsite 为日文站, 中文标题恒 0 结果 (实测), 调用方应优先用
  /// bgm 条目日文名等日文关键词。
  static Future<List<DlsiteWork>> search(String keyword) async {
    final enc = Uri.encodeComponent(keyword);
    final html = await _curlGet(
        'https://www.dlsite.com/maniax/fsr/=/keyword/$enc/per_page/30/');
    if (html == null) return const [];
    final works = <DlsiteWork>[];
    for (final item
        in RegExp(r'<li[^>]*search_result_img[^>]*>.*?</li>', dotAll: true)
            .allMatches(html)) {
      final seg = item.group(0)!;
      final id = RegExp(r'product_id/(RJ\d+)').firstMatch(seg)?.group(1);
      if (id == null) continue;
      final title = RegExp(r'work_name[^>]*>.*?<a[^>]*title="([^"]+)"',
              dotAll: true)
          .firstMatch(seg)
          ?.group(1)
          ?.trim();
      final maker = RegExp(r'maker_name[^>]*>\s*<a[^>]*>([^<]+)<', dotAll: true)
          .firstMatch(seg)
          ?.group(1)
          ?.trim();
      final thumb = RegExp(r'<img[^>]+src="([^"]+)"')
          .firstMatch(seg)
          ?.group(1)
          ?.replaceAll('\\/', '/');
      works.add(DlsiteWork(
        id: id,
        title: title ?? '',
        maker: maker ?? '',
        thumb: thumb ?? '',
      ));
    }
    KazumiLogger().i('DLsite: search "$keyword" -> ${works.length} works');
    return works;
  }

  /// 商品详情 (AJAX JSON): 补系列名/卷号/系列总数/评分/下载数。
  static Future<DlsiteWork?> info(String productId,
      {String maker = ''}) async {
    final body = await _curlGet(
        'https://www.dlsite.com/maniax/product/info/ajax?product_id=$productId');
    if (body == null) return null;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map || decoded.isEmpty) return null;
      final w = decoded.values.first;
      if (w is! Map) return null;
      return DlsiteWork(
        id: productId,
        title: (w['work_name'] ?? '').toString(),
        maker: maker,
        seriesName: (w['title_name'] ?? '').toString(),
        volume: (w['title_volumn'] ?? '').toString(),
        seriesCount: (w['title_work_count'] as num?)?.toInt() ?? 0,
        rating: (w['rate_average_2dp'] as num?)?.toDouble() ?? 0,
        dlCount: (w['dl_count'] as num?)?.toInt() ?? 0,
      );
    } catch (e) {
      KazumiLogger().w('DLsite: info parse failed: $e');
      return null;
    }
  }
}
