import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/collect/collect_repair.dart';
import 'package:kazumi/modules/roads/road_module.dart';

/// [my新增] 系列判定与作品锚点提取 (里番收藏"作品级聚合"混合方案)。
///
/// T1 实测 (2026-10-30, 本地样本): 观看页自带的播放列表容器对系列类
/// 作品 = 该系列全集 (相邻标题公共前缀相似度 0.86~1.00, 列表新→旧排序,
/// 最老一集 id 最小且不变), 对非系列视频 = 推荐/最新流 (相似度 0.00~0.04,
/// 视频数多且 id 跨度全站)。据此用"相邻标题公共前缀相似度"区分两种形态,
/// 系列作品以列表中最老一集的链接为稳定锚点。
class SeriesDetectResult {
  const SeriesDetectResult({
    required this.isSeries,
    this.anchorUrl = '',
    this.seriesName = '',
    this.chapterCount = 0,
  });

  final bool isSeries;

  /// 系列锚点: 列表中最老一集的链接 (打开该页即全集列表)
  final String anchorUrl;

  /// 系列名: 全体集标题的最长公共前缀 (剥尾部集数残留)
  final String seriesName;
  final int chapterCount;
}

class SeriesDetector {
  SeriesDetector._();

  /// 相邻标题公共前缀相似度均值阈值 (剥离集数标记后: 系列≈1.0, 推荐流 ≤0.04)
  static const double seriesPrefixRatio = 0.7;

  /// 集数标记后缀 (剥掉后再比较, 避免 "第1话/第10话"、"前編/後編" 这类
  /// 合法系列被截断的公共前缀稀释)。
  /// [my升级] 增加裸尾数字形态 (作品名1 / 作品名 2 / 作品名 第2) ——
  /// 该站点集数常用裸数字编号 (T1 诊断实测此形态存在)。
  static final RegExp _episodeMarker = RegExp(
    r'[\s\-–—~～·・_]*('
    r'[前後后]編|[前後后]编|[上下]篇|'
    r'第?\s*[\d０-９]+\s*[话話巻卷集回]|'
    r'第\s*[\d０-９]+|'
    r'PART\s*[\d０-９]+|'
    r'【[\d０-９]+】|'
    r'その\s*[\d０-９]+|'
    r'[\d０-９]{1,3}'
    r')$',
    caseSensitive: false,
  );

  static String stripEpisodeMarker(String title) {
    var s = title.trim();
    while (s.isNotEmpty) {
      final m = _episodeMarker.firstMatch(s);
      // 整串都是标记时保留原样, 避免剥成空串
      if (m == null || m.start == 0) break;
      s = s.substring(0, m.start).trim();
    }
    return s;
  }

  /// [my新增] 严格标记 (命名用): 与 _episodeMarker 的区别是**不含裸尾
  /// 数字** —— 独立作品的标题本身就可能以数字结尾, 剥了会把真名改错;
  /// 匹配走宽松版, 存储名求准。
  static final RegExp _episodeMarkerStrict = RegExp(
    r'[\s\-–—~～·・_]*('
    r'[前後后]編|[前後后]编|[上下]篇|'
    r'第?\s*[\d０-９]+\s*[话話巻卷集回]|'
    r'第\s*[\d０-９]+|'
    r'PART\s*[\d０-９]+|'
    r'【[\d０-９]+】|'
    r'その\s*[\d０-９]+'
    r')$',
    caseSensitive: false,
  );

  /// [my新增] 条目命名清洗: 只剥带明确量词的集数标记, 不动裸尾数字与
  /// 前缀装饰。剥后为空或不足 2 字 → 回退原名。
  static String namingName(String raw) {
    var s = raw.trim();
    while (s.isNotEmpty) {
      final m = _episodeMarkerStrict.firstMatch(s);
      if (m == null || m.start == 0) break;
      s = s.substring(0, m.start).trim();
    }
    if (s.length < 2) return raw.trim();
    return s;
  }

  // ====== [my新增] 显示层剥裸尾数字 (方案一 b) ======
  // 命名层 (namingName) 保留裸尾数字以维持系列匹配 ("名 2"=第 2 集);
  // 展示层由本助手剥除并以角标呈现集数, 匹配/存储完全不动。

  /// 裸尾数字 (完整数字串, 可带空白/连字符前缀): 长度 >2 视为年份等
  /// 标题本体不剥 (在代码层守卫, 正则咬完整串防 "2024" 被截尾剥成
  /// "20"+24); "2nd" 尾为字母不匹配 (与 sameSeriesName 的拉丁拒绝口径
  /// 一致)
  static final RegExp _trailingBareDigits =
      RegExp(r'[\s\-–—~～·・_－]*([0-9０-９]+)$');

  /// 展示名与集数: "名 2" → ("名", 2); "名" → ("名", null)。
  /// 不剥: 无裸尾数字 / 数字超 2 位 / 剥后剩 <2 字符 (纯数字名)。
  static (String, int?) displayNameParts(String name) {
    final s = name.trim();
    final m = _trailingBareDigits.firstMatch(s);
    if (m == null) return (s, null);
    final digits = m.group(1)!;
    if (digits.length > 2) return (s, null);
    final ascii = digits.replaceAllMapped(RegExp(r'[０-９]'),
        (c) => String.fromCharCode(c.group(0)!.codeUnitAt(0) - 0xFF10 + 0x30));
    final ep = int.tryParse(ascii);
    final base = s.substring(0, m.start).trim();
    if (ep == null || ep < 1 || base.length < 2) return (s, null);
    return (base, ep);
  }

  /// [my升级] 判断两个收藏名是否属于同一作品:
  /// 剥集数标记后相等 → 同作品; 剥后短方是长方前缀且剩余部分是裸数字
  /// → 也判同作品 (该站集数用裸数字编号, "作品名1/作品名2" 是同系列;
  /// 剩余为字母等其他字符仍拒绝, 防 "XX" 误并 "XXR")。
  /// [my优化] 判定用字符类正则提升为常量: 此前每次调用现编译,
  /// 星标渲染是 卡片数×系列数 的乘法调用, 热路径
  static final RegExp _digitStart = RegExp(r'^[\d０-９]');
  static final RegExp _latinStart = RegExp(r'^[A-Za-z]');
  static final RegExp _urlDigits = RegExp(r'^\d+');

  static bool sameSeriesName(String seriesName, String otherName) {
    final a = stripEpisodeMarker(seriesName.trim());
    final b = stripEpisodeMarker(otherName.trim());
    if (a.isEmpty || b.isEmpty || a.length < 2 || b.length < 2) return false;
    if (a == b) return true;
    final shorter = a.length <= b.length ? a : b;
    final longer = a.length <= b.length ? b : a;
    if (!longer.startsWith(shorter)) return false;
    final rest = longer.substring(shorter.length);
    // 剩余以数字开头 → 集数编号 (作品名2 / 作品名2nd), 同作品
    if (_digitStart.hasMatch(rest)) return true;
    // 剩余以拉丁字母开头 → 疑似续作/别名 (作品名R), 拒绝
    if (_latinStart.hasMatch(rest)) return false;
    // 剩余为标点/CJK → 子标题变体 (作品名：温泉篇 / 作品名番外), 同作品
    return true;
  }

  /// [my优化] 一侧已剥除的匹配 (系列名集合预剥除后复用, 免热路径重复剥)
  static bool sameSeriesStripped(String seriesStripped, String otherRaw) {
    final b = stripEpisodeMarker(otherRaw.trim());
    if (seriesStripped.isEmpty ||
        b.isEmpty ||
        seriesStripped.length < 2 ||
        b.length < 2) {
      return false;
    }
    if (seriesStripped == b) return true;
    final shorter =
        seriesStripped.length <= b.length ? seriesStripped : b;
    final longer = seriesStripped.length <= b.length ? b : seriesStripped;
    if (!longer.startsWith(shorter)) return false;
    final rest = longer.substring(shorter.length);
    if (_digitStart.hasMatch(rest)) return true;
    if (_latinStart.hasMatch(rest)) return false;
    return true;
  }

  /// [my新增] 在里番区找与 [seriesItem] 同作品的其他条目 (含旧格式单集
  /// 收藏与锚点漂移的重复系列条目), 供收藏/打开时自动合并。
  static List<CollectedBangumi> findSameSeriesSiblings(
    BangumiItem seriesItem,
    Iterable<CollectedBangumi> all,
  ) {
    final name = seriesItem.nameCn.isNotEmpty
        ? seriesItem.nameCn
        : seriesItem.name;
    if (name.length < 2) return const [];
    return all
        .where((c) =>
            c.section == 1 &&
            c.bangumiItem.id != seriesItem.id &&
            // 只合并直连源条目, 真实 bgm 条目永不参与
            CollectSectionRepair.isDirectSourceItem(c.bangumiItem) &&
            sameSeriesName(
                name,
                c.bangumiItem.nameCn.isNotEmpty
                    ? c.bangumiItem.nameCn
                    : c.bangumiItem.name))
        .toList();
  }

  /// [my优化·抽取] 系列升级结果: 三处调用 (收藏/打开/批量迁移) 共享的
  /// "判定 → 构造作品条目 → 落库 → 合并兄弟" 流程产物
  static const int seriesUpgradeNoChange = 0;
  static const int seriesUpgradeCreated = 1;
  static const int seriesUpgradeUnchanged = 2;

  /// [my优化·抽取] 统一的系列升级+合并 (此前 direct 页/里番页/迁移三处
  /// 各自手写, 已出现细微分叉)。[roads] 为该条目播放页解析出的线路;
  /// [add]/[delete] 由调用方注入存储操作 (controller), 判定与构造在此。
  /// 返回 (状态, 作品条目, 合并条数):
  /// - seriesUpgradeNoChange: 非系列/未认领前置不满足 → item 原样返回
  /// - seriesUpgradeCreated: 已生成新作品条目并落库, 兄弟已删
  /// - seriesUpgradeUnchanged: 条目已是该系列锚点条目 (id 相同)
  static Future<(int, BangumiItem, int)> upgradeToSeries({
    required String pluginName,
    required BangumiItem item,
    required List<Road> roads,
    required int type,
    required Future<void> Function(BangumiItem item, int type) add,
    required Future<void> Function(BangumiItem item) delete,
    Iterable<CollectedBangumi> all = const [],
  }) async {
    final detected = detect(roads);
    if (!detected.isSeries) return (seriesUpgradeNoChange, item, 0);
    final seriesItem = buildSeriesItem(
        stableDirectId('${pluginName}_${detected.anchorUrl}'), detected, item);
    if (seriesItem.id == item.id) {
      return (seriesUpgradeUnchanged, seriesItem, 0);
    }
    await add(seriesItem, type);
    var merged = 0;
    for (final sibling in findSameSeriesSiblings(seriesItem, all)) {
      await delete(sibling.bangumiItem);
      merged++;
    }
    return (seriesUpgradeCreated, seriesItem, merged);
  }

  /// [my新增] 应用统一的直连条目稳定 id (与 direct_search_page 同算法:
  /// md5 前 7 位十六进制), 收藏/播放/打开三处必须产出同一 id
  static int stableDirectId(String source) {
    // [my优化] utf8.encode 已返回 Uint8List, 去掉多余的 fromList 拷贝
    final hex = crypto.md5.convert(utf8.encode('direct_search/$source')).toString();
    return int.parse(hex.substring(0, 7), radix: 16);
  }

  /// [my新增] 构造系列聚合条目 (收藏与播放共用同一 id):
  /// [id] 由调用方用应用统一的稳定哈希 (源名+锚点) 算出,
  /// name=系列名, info=锚点链接 (最老一集)。
  /// 历史/收藏/时间表凭此按作品归一。
  static BangumiItem buildSeriesItem(
      int id, SeriesDetectResult detected, BangumiItem baseItem) {
    return BangumiItem(
      id: id,
      type: 2,
      name: detected.seriesName,
      nameCn: detected.seriesName,
      summary: '',
      airDate: '',
      airWeekday: 0,
      rank: 0,
      images: baseItem.images,
      tags: [],
      alias: [],
      ratingScore: baseItem.ratingScore,
      votes: 0,
      votesCount: [],
      info: detected.anchorUrl,
    );
  }

  static SeriesDetectResult detect(List<Road> roads) {
    // 取集数最多的一条线路
    Road? road;
    for (final r in roads) {
      if (road == null || r.data.length > road.data.length) road = r;
    }
    if (road == null) return const SeriesDetectResult(isSeries: false);
    // 按链接去重 (容器含桌面/移动两套 DOM), 标题跟随首次出现;
    // [my优化] Set 成员判断 — 推荐流列表近百项时原 contains 是 O(n²)
    final urls = <String>[];
    final titles = <String>[];
    final seen = <String>{};
    for (var i = 0; i < road.data.length && i < road.identifier.length; i++) {
      final url = road.data[i];
      if (url.isEmpty || !seen.add(url)) continue;
      urls.add(url);
      titles.add(road.identifier[i].trim());
    }
    if (urls.length < 2) return const SeriesDetectResult(isSeries: false);
    // 剥集数标记后比较; 全被剥空时退回原标题
    // [my优化] 剥除只算一次 (原实现条件+取值各算一遍)
    final stripped = <String>[];
    for (final t in titles) {
      final s = stripEpisodeMarker(t);
      if (s.isNotEmpty) stripped.add(s);
    }
    final compareTitles = stripped.length == urls.length ? stripped : titles;
    var ratioSum = 0.0;
    var pairs = 0;
    for (var i = 0; i < compareTitles.length - 1; i++) {
      final a = compareTitles[i];
      final b = compareTitles[i + 1];
      final minLen = a.length < b.length ? a.length : b.length;
      if (minLen == 0) continue;
      ratioSum += _commonPrefix(a, b) / minLen;
      pairs++;
    }
    if (pairs == 0 || ratioSum / pairs < seriesPrefixRatio) {
      return SeriesDetectResult(isSeries: false, chapterCount: urls.length);
    }
    // 锚点 = 视频参数最小的链接 (列表新→旧 ⇒ 最小 id = 最老一集);
    // 链接无数字参数时退化为列表末项 (同为新→旧排序假设)
    var anchor = urls.last;
    int? minId;
    for (final url in urls) {
      final id = _videoParam(url);
      if (id != null && (minId == null || id < minId)) {
        minId = id;
        anchor = url;
      }
    }
    final name = _seriesName(compareTitles);
    return SeriesDetectResult(
      isSeries: name.isNotEmpty,
      anchorUrl: name.isNotEmpty ? anchor : '',
      seriesName: name,
      chapterCount: urls.length,
    );
  }

  static int _commonPrefix(String a, String b) {
    var n = 0;
    while (n < a.length && n < b.length && a[n] == b[n]) {
      n++;
    }
    return n;
  }

  static int? _videoParam(String url) {
    final marker = url.indexOf('v=');
    if (marker < 0) return null;
    final rest = url.substring(marker + 2);
    final num = _urlDigits.firstMatch(rest);
    return num == null ? null : int.tryParse(num.group(0)!);
  }

  /// 全体标题的最长公共前缀, 剥掉截断残留的集数标记
  /// (如 "作品名 第" / "作品名 第1" → "作品名")
  static String _seriesName(List<String> titles) {
    if (titles.isEmpty) return '';
    var prefix = titles.first;
    for (final t in titles) {
      var n = 0;
      while (n < prefix.length && n < t.length && prefix[n] == t[n]) {
        n++;
      }
      prefix = prefix.substring(0, n);
      if (prefix.isEmpty) break;
    }
    final name = prefix
        .replaceAll(RegExp(r'[\s]*[\d０-９]+$'), '')
        .replaceAll(RegExp(r'[\s\-–—~～·・_]*(第|話|话|巻|卷|集)$'), '')
        .trim();
    return name;
  }
}
