// [my新增] 弹幕集数对齐服务 — 治"源站编号 vs 弹弹play 编号"的一切错位。
// 设计 (见 弹幕匹配探查报告_20261024.md): 不预判源的编号规则, 把每次人工
// 纠正变成持久锚点 (源集 → dandanplay episodeId, 全局唯一、与编号语义
// 无关); 未锚定的集在正片序列上从锚点线性插值/外推 (跨季滚动到同系列
// 下一季条目); 自动命中经正片校验, 命中 OP/ED/C 曲目或越界不再静默采用,
// 且校验通过的自动命中顺手转正为锚点。
// 存储: 设置键 danmakuAlignmentMap, JSON { "bgmId:plugin": {srcEp: [eid, title, ts]} }
// 同步: WebDAV per-device JSON (仿弹幕屏蔽词同步), 新旧按时间戳合并。
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/modules/danmaku/danmaku_episode_response.dart';
import 'package:kazumi/modules/danmaku/danmaku_search_response.dart';
import 'package:kazumi/request/apis/danmaku_api.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/sync/webdav.dart';

class DanmakuAnchor {
  const DanmakuAnchor({
    required this.srcEp,
    required this.episodeId,
    required this.title,
    required this.updatedAt,
  });

  final int srcEp;
  final int episodeId;
  final String title;
  final int updatedAt;
}

/// 当前集弹幕匹配的来源与结果 (面板展示 / 疑似错配提示用)
class DanmakuMatchInfo {
  DanmakuMatchInfo({
    required this.source,
    this.bgmId = 0,
    this.pluginName = '',
    this.srcEp = 0,
    this.episodeId,
    this.animeTitle,
    this.episodeTitle,
    this.note,
  });

  /// anchor=锚点 / inferred=推断 / auto=自动(已校验) /
  /// manual=手动当次 / suspect=疑似错配 / none=无匹配
  final String source;
  final int bgmId;
  final String pluginName;
  final int srcEp;
  final int? episodeId;
  final String? animeTitle;
  final String? episodeTitle;
  final String? note;

  String get sourceLabel => switch (source) {
        'anchor' => '锚点匹配',
        'inferred' => '推断匹配',
        'auto' => '自动匹配',
        'manual' => '手动匹配',
        'suspect' => '疑似错配',
        _ => '未匹配',
      };
}

class DanmakuAlignmentService {
  DanmakuAlignmentService._();

  static final DanmakuAlignmentService instance = DanmakuAlignmentService._();

  /// 非正片条目标题特征 (OP/ED/C 曲目/SP/PV 等, dandanplay 习惯 append 在
  /// 正片后, 占用集数位置 — "成功命中 C1 Opening"是静默错配的根源)
  static final RegExp _nonEpisodePattern = RegExp(
      r'^(?:C\d|OP|ED|NCOP|NCED|SP\d?|PV\d?|CM|MV|Preview|预告|番宣|ノンクレジット|クレジット|Credit|エンディング|オープニング)'
      r'|(?:^|\s)(?:Opening|Ending|Main Theme|Insert Song)\b',
      caseSensitive: false);

  static bool isNonEpisodeTitle(String title) =>
      _nonEpisodePattern.hasMatch(title.trim());

  /// episodeId 结构 (实测): animeId * 10000 + 序号 (163000001 = 条目16300 第1条)
  static (int, int) decomposeEpisodeId(int episodeId) =>
      (episodeId ~/ 10000, episodeId % 10000);

  // ====== 存储 ======

  Map<String, Map<int, DanmakuAnchor>> _load() {
    final raw = GStorage.getSetting(SettingsKeys.danmakuAlignmentMap).trim();
    if (raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final result = <String, Map<int, DanmakuAnchor>>{};
      for (final e in decoded.entries) {
        final inner = <int, DanmakuAnchor>{};
        if (e.value is Map) {
          for (final a in (e.value as Map).entries) {
            final srcEp = int.tryParse(a.key.toString());
            final v = a.value;
            if (srcEp == null || v is! List || v.length < 3) continue;
            inner[srcEp] = DanmakuAnchor(
              srcEp: srcEp,
              episodeId: (v[0] as num).toInt(),
              title: v[1].toString(),
              updatedAt: (v[2] as num).toInt(),
            );
          }
        }
        result[e.key.toString()] = inner;
      }
      return result;
    } catch (e) {
      KazumiLogger().w('DanmakuAlignment: parse table failed: $e');
      return {};
    }
  }

  Future<void> _save(Map<String, Map<int, DanmakuAnchor>> table) async {
    final encoded = <String, Map<String, List<dynamic>>>{};
    for (final e in table.entries) {
      encoded[e.key] = {
        for (final a in e.value.entries)
          a.key.toString(): [a.value.episodeId, a.value.title, a.value.updatedAt],
      };
    }
    await GStorage.putSetting(
        SettingsKeys.danmakuAlignmentMap, jsonEncode(encoded));
    _changes.add(null);
  }

  String _key(int bgmId, String plugin) => '$bgmId:$plugin';

  List<DanmakuAnchor> anchorsOf(int bgmId, String plugin) {
    final item = _load()[_key(bgmId, plugin)];
    if (item == null) return const [];
    final list = item.values.toList()..sort((a, b) => a.srcEp - b.srcEp);
    return list;
  }

  DanmakuAnchor? anchorFor(int bgmId, String plugin, int srcEp) {
    final item = _load()[_key(bgmId, plugin)];
    if (item == null) return null;
    final a = item[srcEp];
    return a;
  }

  int get totalAnchors =>
      _load().values.fold(0, (sum, item) => sum + item.length);

  Future<void> writeAnchor(
      int bgmId, String plugin, int srcEp, int episodeId, String title) async {
    final table = _load();
    final k = _key(bgmId, plugin);
    table.putIfAbsent(k, () => {})[srcEp] = DanmakuAnchor(
          srcEp: srcEp,
          episodeId: episodeId,
          title: title,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        );
    await _save(table);
    KazumiLogger().i(
        'DanmakuAlignment: anchor $k ep$srcEp -> $episodeId ($title)');
  }

  Future<void> removeItem(int bgmId, String plugin) async {
    final table = _load();
    table.remove(_key(bgmId, plugin));
    await _save(table);
  }

  Future<void> clearAll() async {
    await _save({});
  }

  // ====== 集表缓存 (推断/校验的数据底座) ======

  final Map<int, List<DanmakuEpisode>> _episodeCache = {};
  final Map<String, (DateTime, List<DanmakuSearchAnime>)> _searchCache = {};

  Future<List<DanmakuEpisode>> episodesOf(int animeId) async {
    final cached = _episodeCache[animeId];
    if (cached != null) return cached;
    try {
      final resp =
          await DanmakuApi.getDanDanEpisodesByDanDanBangumiID(animeId);
      final eps = resp.episodes;
      _episodeCache[animeId] = eps;
      return eps;
    } catch (e) {
      KazumiLogger().w('DanmakuAlignment: fetch episodes failed: $e');
      return const [];
    }
  }

  /// 正片子序列 (过滤 OP/ED/C 曲目)
  List<DanmakuEpisode> mainEpisodes(List<DanmakuEpisode> eps) =>
      eps.where((e) => !isNonEpisodeTitle(e.episodeTitle)).toList();

  Future<List<DanmakuSearchAnime>> _searchAnimesCached(String keyword) async {
    final cached = _searchCache[keyword];
    if (cached != null &&
        DateTime.now().difference(cached.$1) < const Duration(minutes: 10)) {
      return cached.$2;
    }
    try {
      final resp = await DanmakuApi.searchAnimes(keyword);
      _searchCache[keyword] = (DateTime.now(), resp.animes);
      return resp.animes;
    } catch (_) {
      return const [];
    }
  }

  // ====== 推断 (插值 + 外推 + 跨季滚动) ======

  /// 返回推断目标 (正片序列内的 DanmakuEpisode), 无信心则 null。
  Future<DanmakuEpisode?> infer({
    required int bgmId,
    required String plugin,
    required int srcEp,
    String? itemTitle,
  }) async {
    final anchors = anchorsOf(bgmId, plugin);
    if (anchors.isEmpty) return null;
    final below = anchors.where((a) => a.srcEp < srcEp).toList();
    final above = anchors.where((a) => a.srcEp > srcEp).toList();
    final last = below.isEmpty ? anchors.first : below.last;

    // 插值: 夹在两锚点之间且同条目 → 线性内插 (源缺集等非线性错位天然覆盖)
    if (below.isNotEmpty && above.isNotEmpty) {
      final a = below.last;
      final b = above.first;
      final (aAnime, aSeq) = decomposeEpisodeId(a.episodeId);
      final (bAnime, bSeq) = decomposeEpisodeId(b.episodeId);
      if (aAnime == bAnime && b.srcEp > a.srcEp) {
        final seq = aSeq +
            ((bSeq - aSeq) * (srcEp - a.srcEp)) ~/ (b.srcEp - a.srcEp);
        final ep = await _episodeAt(aAnime, seq);
        if (ep != null) return ep;
      }
    }

    // 外推: 超出最后锚点, 按最近两锚点斜率 (缺省 1)
    final (lastAnime, lastSeq) = decomposeEpisodeId(last.episodeId);
    if (srcEp > last.srcEp) {
      var slope = 1.0;
      if (below.length >= 2) {
        final prev = below[below.length - 2];
        final (prevAnime, prevSeq) = decomposeEpisodeId(prev.episodeId);
        if (prevAnime == lastAnime && last.srcEp > prev.srcEp) {
          slope = (lastSeq - prevSeq) / (last.srcEp - prev.srcEp);
        }
      }
      final seqEst = lastSeq + (slope * (srcEp - last.srcEp)).round();
      // 条目内放得下 (正片数内) → 直接用
      final ep = await _episodeAt(lastAnime, seqEst);
      if (ep != null) return ep;
      // 跨季滚动: 放不下 → 找同系列下一季条目继续编
      if (itemTitle != null && itemTitle.trim().isNotEmpty) {
        return await _rollOverToNextSeason(
            itemTitle, lastAnime, seqEst, bgmId);
      }
    }
    return null;
  }

  /// 条目 animeId 的第 seq 条 (原始表序号), 要求落在正片范围内
  Future<DanmakuEpisode?> _episodeAt(int animeId, int seq) async {
    if (seq < 1) return null;
    final eps = await episodesOf(animeId);
    if (eps.isEmpty || seq > eps.length) return null;
    final ep = eps[seq - 1];
    if (isNonEpisodeTitle(ep.episodeTitle)) return null;
    return ep;
  }

  Future<DanmakuEpisode?> _rollOverToNextSeason(
      String itemTitle, int currentAnimeId, int seqEst, int bgmId) async {
    final candidates = await _searchAnimesCached(itemTitle);
    if (candidates.isEmpty) return null;
    final currentEps = await episodesOf(currentAnimeId);
    final currentMain = mainEpisodes(currentEps).length;
    final remaining = seqEst - currentMain;
    if (remaining < 1) return null;
    // 相似度排序: 与检索词最像的优先 (屏蔽 "SSSS.古立特" 类噪音)
    final sorted = _sortBySimilarity(candidates, itemTitle);
    for (final anime in sorted) {
      if (anime.animeId == currentAnimeId) continue;
      final ep = await _episodeAt(anime.animeId, remaining);
      if (ep != null) {
        KazumiLogger().i(
            'DanmakuAlignment: 跨季推断 -> ${anime.animeTitle} #$remaining');
        return ep;
      }
    }
    return null;
  }

  /// 标题相似度排序 (公开: 手动匹配候选列表复用)
  static List<DanmakuSearchAnime> sortAnimesBySimilarity(
          List<DanmakuSearchAnime> animes, String keyword) =>
      _sortBySimilarity(animes, keyword);

  /// 标题相似度排序 (同名/包含优先, 长度差小者优先, 稳定保序)
  static List<DanmakuSearchAnime> _sortBySimilarity(
      List<DanmakuSearchAnime> animes, String keyword) {
    final k = keyword.toLowerCase();
    int score(DanmakuSearchAnime a) {
      final t = a.animeTitle.toLowerCase();
      var s = 0;
      if (t == k) s += 100;
      if (t.contains(k) || k.contains(t)) s += 50;
      final common =
          k.runes.toSet().intersection(t.runes.toSet()).length;
      s += common;
      s -= (t.length - k.length).abs() ~/ 8;
      return s;
    }

    final indexed = [
      for (var i = 0; i < animes.length; i++) (animes[i], score(animes[i]), i)
    ]..sort((x, y) {
        final c = y.$2.compareTo(x.$2);
        return c != 0 ? c : x.$3.compareTo(y.$3);
      });
    return [for (final e in indexed) e.$1];
  }

  // ====== 自动命中校验 (治"成功但错配") ======

  /// 返回 null = 校验通过; 非 null = 疑似错配原因 (调用方提示手动匹配)
  Future<String?> validateAutoTarget(int animeId, int srcEp) async {
    final eps = await episodesOf(animeId);
    if (eps.isEmpty) return null; // 拿不到集表, 保持原行为
    if (srcEp > eps.length) {
      return '第 $srcEp 集超出该条目集数表 (共 ${eps.length} 条)';
    }
    final title = eps[srcEp - 1].episodeTitle;
    if (isNonEpisodeTitle(title)) {
      return '第 $srcEp 集命中非正片条目「$title」';
    }
    return null;
  }

  // ====== 当前集匹配信息 (面板展示) ======

  DanmakuMatchInfo? lastMatch;

  // ====== WebDAV 同步 (仿弹幕屏蔽词: per-device 文件, 时间戳合并) ======

  final _changes = StreamController<void>.broadcast();
  Timer? _pushDebounce;
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    _changes.stream.listen((_) {
      _pushDebounce?.cancel();
      _pushDebounce = Timer(const Duration(seconds: 2), () {
        unawaited(_syncQuietly());
      });
    });
  }

  /// 合并远端状态 (新旧时间戳取胜), 返回合并后的扁平 JSON
  Future<Map<String, dynamic>> mergeRemote(Map<String, dynamic> remote) async {
    final table = _load();
    final remoteTable = _decodeFlat(remote);
    var changed = false;
    for (final e in remoteTable.entries) {
      final local = table.putIfAbsent(e.key, () => {});
      for (final a in e.value.values) {
        final cur = local[a.srcEp];
        if (cur == null || a.updatedAt > cur.updatedAt) {
          local[a.srcEp] = a;
          changed = true;
        }
      }
    }
    if (changed) await _save(table);
    return _encodeFlat(table);
  }

  Map<String, dynamic> exportState() => _encodeFlat(_load());

  Map<String, dynamic> _encodeFlat(
      Map<String, Map<int, DanmakuAnchor>> table) {
    return {
      for (final e in table.entries)
        e.key: {
          for (final a in e.value.values)
            a.srcEp.toString(): [a.episodeId, a.title, a.updatedAt],
        }
    };
  }

  Map<String, Map<int, DanmakuAnchor>> _decodeFlat(Map<String, dynamic> flat) {
    final result = <String, Map<int, DanmakuAnchor>>{};
    for (final e in flat.entries) {
      final inner = <int, DanmakuAnchor>{};
      if (e.value is Map) {
        for (final a in (e.value as Map).entries) {
          final srcEp = int.tryParse(a.key.toString());
          final v = a.value;
          if (srcEp == null || v is! List || v.length < 3) continue;
          inner[srcEp] = DanmakuAnchor(
            srcEp: srcEp,
            episodeId: (v[0] as num).toInt(),
            title: v[1].toString(),
            updatedAt: (v[2] as num).toInt(),
          );
        }
      }
      result[e.key.toString()] = inner;
    }
    return result;
  }

  Future<void> _syncQuietly() async {
    try {
      final webDav = _webDav();
      if (webDav == null) return;
      final deviceId = await _deviceId();
      await webDav.syncDanmakuAlignment(
        deviceId: deviceId,
        merge: mergeRemote,
        export: exportState,
      );
    } catch (e) {
      KazumiLogger().w('DanmakuAlignment: webdav sync failed', error: e);
    }
  }

  WebDav? _webDav() {
    try {
      return inject<WebDav>();
    } catch (_) {
      return null;
    }
  }

  Future<String> _deviceId() async {
    var id = GStorage.getSetting(SettingsKeys.danmakuAlignmentDeviceId);
    if (id.isNotEmpty) return id;
    final rand = List.generate(16,
            (i) => '0123456789abcdef'[math.Random().nextInt(16)]).join();
    id = '${DateTime.now().millisecondsSinceEpoch.toRadixString(16)}$rand';
    await GStorage.putSetting(SettingsKeys.danmakuAlignmentDeviceId, id);
    return id;
  }
}
