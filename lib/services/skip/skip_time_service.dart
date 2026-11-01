// [my新增] 自动跳过片头片尾数据源服务 (方案见 播放器自动跳过片头片尾方案_本地.md):
// - id 映射: Bangumi 原名 → AniList GraphQL 搜索 → idMal (持久缓存, 设置 JSON 键)
// - 跳过区间: aniskip 社区库 (api.aniskip.com v2, 免鉴权, 实测可用) 按集拉取,
//   会话内存缓存 (正/负结果都缓存, 免重击)
// - 相似度校验: 归一化 bigram Dice ≥ 0.6 才采纳 (宁可不跳不错跳)
// 无数据/失败静默 → 调用方回退手动秒数 (R18 内容社区库基本无数据, 属预期)。
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 单个跳过区间 (秒); type: 'op' | 'ed'
class SkipInterval {
  const SkipInterval({
    required this.type,
    required this.start,
    required this.end,
  });
  final String type;
  final double start;
  final double end;
}

class SkipTimeService {
  SkipTimeService._();

  // [my修复] 外域 API (anilist/aniskip) 直连不可达 (实测), 必须走应用
  // 代理通道 — 两域名已纳入 NetworkConfig 白名单, 此处挂同源适配器
  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: Duration(seconds: 10),
    receiveTimeout: Duration(seconds: 20),
  ))
    ..httpClientAdapter = NetworkConfig.fromSettings(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
    ).createAdapter();

  // —— malId 映射 (持久) ——
  static final Map<String, int> _malIdCache = {};
  static bool _malIdLoaded = false;
  static final Map<String, Future<int?>> _malIdInflight = {};
  // [my修复] 确定无匹配 (查询成功但相似度都不足阈值) 的会话负缓存:
  // 原实现负结果不缓存 → 每次播放重查 AniList 再失败 (中文标题必失败,
  // 表现为"跳过与缓存都不生效")。网络失败不缓存 (下次重试)。
  static final Set<String> _malIdNoMatch = {};
  // bgm id 维度的负缓存 (bgm API 失败/原名未匹配)
  static final Set<String> _bgmNoMatch = {};

  /// [my新增] 镜像配置 (base+token 齐全才生效): iOS 无代理环境经自建
  /// frp 反代访问数据源; 留空 = 默认直连/走代理 (Windows 原路径)。
  static (String base, String token)? get _mirror {
    final base = GStorage.getSetting(SettingsKeys.skipMirrorBase).trim();
    if (base.isEmpty) return null;
    final token = GStorage.getSetting(SettingsKeys.skipMirrorToken).trim();
    if (token.isEmpty) return null;
    return (
      base.endsWith('/') ? base.substring(0, base.length - 1) : base,
      token,
    );
  }

  // —— 区间 (会话内存) ——
  // key: 'malId:episode' → 区间列表 (空列表 = 该集无社区数据)
  static final Map<String, List<SkipInterval>> _intervalCache = {};
  static final Map<String, Future<List<SkipInterval>>> _intervalInflight = {};

  static void _loadMalIdCache() {
    if (_malIdLoaded) return;
    _malIdLoaded = true;
    try {
      final raw = GStorage.getSetting(SettingsKeys.skipTimeIdMap).trim();
      if (raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        decoded.forEach((k, v) {
          final id = int.tryParse(v.toString());
          if (k.toString().isNotEmpty && id != null) {
            _malIdCache[k.toString()] = id;
          }
        });
      }
    } catch (e) {
      KazumiLogger().w('SkipTime: parse id map failed: $e');
    }
  }

  static Future<void> _persistMalIdCache() async {
    try {
      await GStorage.putSetting(
          SettingsKeys.skipTimeIdMap, jsonEncode(_malIdCache));
    } catch (e) {
      KazumiLogger().w('SkipTime: persist id map failed: $e');
    }
  }

  /// Bangumi 原名 → MAL id。名称相似度阈值 0.6, 低于视为未匹配 (null →
  /// 调用方走手动回退)。持久缓存; 并发去重。
  static Future<int?> resolveMalId(String subjectName) {
    _loadMalIdCache();
    final key = subjectName.trim();
    if (key.isEmpty) return Future.value(null);
    if (_malIdCache.containsKey(key)) return Future.value(_malIdCache[key]);
    if (_malIdNoMatch.contains(key)) return Future.value(null);
    return _malIdInflight.putIfAbsent(key, () => _resolveMalIdRemote(key))
        .whenComplete(() => _malIdInflight.remove(key));
  }

  // [my修复] id 优先解析链: 真实 bgm id → bgm API 取日文原名 → AniList。
  // 背景: 下载页缓存播放伪造的条目 name/nameCn 全是中文名 (下载记录落库
  // 即 nameCn 优先), 名称路径必失败 —— id 是唯一可靠入口; 直连 (R18) 条目
  // id 为哈希, 走名称路径 (社区库基本无数据, 手动回退属预期)。
  static Future<int?> resolveMalIdForSubject({
    required bool isBgmSubject,
    required int subjectId,
    required String fallbackName,
  }) async {
    _loadMalIdCache();
    if (!isBgmSubject || subjectId <= 0) {
      return resolveMalId(fallbackName);
    }
    final bgmKey = 'bgmv2:$subjectId'; // v2: 相似度保留尾标点后重解析,
    // 旧 'bgm:' 键的错季映射 (3736→7791) 不再读取
    if (_malIdCache.containsKey(bgmKey)) return _malIdCache[bgmKey];
    if (_bgmNoMatch.contains(bgmKey)) return null;
    try {
      final info = await BangumiApi.getBangumiInfoByID(subjectId);
      final name = info?.name.trim() ?? '';
      if (name.isEmpty) {
        _bgmNoMatch.add(bgmKey);
        return null;
      }
      final malId = await _anilistSearch(name);
      if (malId != null) {
        _malIdCache[name] = malId;
        _malIdCache[bgmKey] = malId;
        await _persistMalIdCache();
        KazumiLogger().i('SkipTime: bgm:$subjectId → malId $malId');
      } else {
        _bgmNoMatch.add(bgmKey);
      }
      return malId;
    } catch (e) {
      KazumiLogger().w('SkipTime: bgm subject resolve failed: $e');
      return null;
    }
  }

  /// AniList 搜索 (纯查询): 返回最佳 malId 或 null (无阈值命中)。
  /// 异常向上抛, 由调用方决定缓存与日志口径。
  static Future<int?> _anilistSearch(String query) async {
    final mirror = _mirror;
    final resp = await _dio.post(
      mirror == null
          ? 'https://graphql.anilist.co'
          : '${mirror.$1}/skip/anilist',
      data: {
        'query': '''
query (\$search: String) {
  Page(perPage: 5) {
    media(search: \$search, type: ANIME) {
      idMal
      title { native romaji english }
    }
  }
}''',
        'variables': {'search': query},
      },
      options: mirror == null
          ? null
          : Options(headers: {'X-Skip-Token': mirror.$2}),
    );
    final media =
        (resp.data['data']?['Page']?['media'] as List? ?? const []);
    int? best;
    var bestScore = 0.0;
    for (final m in media) {
      final malId = m['idMal'];
      if (malId == null) continue;
      for (final t in [
        (m['title']?['native'] ?? '').toString(),
        (m['title']?['romaji'] ?? '').toString(),
        (m['title']?['english'] ?? '').toString(),
      ]) {
        final score = similarity(query, t);
        if (score >= 0.6 && score > bestScore) {
          bestScore = score;
          best = (malId as num).toInt();
        }
      }
    }
    return best;
  }

  static Future<int?> _resolveMalIdRemote(String key) async {
    try {
      final best = await _anilistSearch(key);
      if (best != null) {
        _malIdCache[key] = best;
        await _persistMalIdCache();
        KazumiLogger().i('SkipTime: malId resolved (name=$key)');
      } else {
        _malIdNoMatch.add(key);
        KazumiLogger().i('SkipTime: malId not matched (阈值不足, 会话内不再重试)');
      }
      return best;
    } catch (e) {
      // [my升级] WARNING 进文件: 网络失败 (多为代理未通) 与阈值拒绝可区分
      KazumiLogger().w('SkipTime: anilist resolve failed: $e');
      return null;
    }
  }

  /// aniskip 按集区间; 无数据返回空列表 (负缓存), 网络失败返回 null (下次
  /// tick 重试)。并发去重。
  static Future<List<SkipInterval>?> intervalsFor({
    required int malId,
    required int episodeNumber,
    required int episodeLengthSec,
  }) {
    final key = '$malId:$episodeNumber';
    if (_intervalCache.containsKey(key)) {
      return Future.value(_intervalCache[key]);
    }
    return _intervalInflight.putIfAbsent(
            key,
            () => _intervalsRemote(malId, episodeNumber, episodeLengthSec,
                key))
        .whenComplete(() => _intervalInflight.remove(key));
  }

  static Future<List<SkipInterval>> _intervalsRemote(
      int malId, int episodeNumber, int episodeLengthSec, String key) async {
    try {
      final mirror = _mirror;
      final resp = await _dio.get(
        mirror == null
            ? 'https://api.aniskip.com/v2/skip-times/$malId/$episodeNumber'
            : '${mirror.$1}/skip/aniskip/v2/skip-times/$malId/$episodeNumber',
        queryParameters: {
          'types': ['op', 'ed'],
          'episodeLength': episodeLengthSec,
        },
        options: mirror == null
            ? null
            : Options(headers: {'X-Skip-Token': mirror.$2}),
      );
      final data = resp.data;
      final found = data is Map && data['found'] == true;
      final results =
          (data is Map ? data['results'] as List? : null) ?? const [];
      final intervals = <SkipInterval>[];
      if (found) {
        for (final r in results) {
          final interval = r is Map ? r['interval'] : null;
          if (interval is! Map) continue;
          final start = (interval['startTime'] as num?)?.toDouble();
          final end = (interval['endTime'] as num?)?.toDouble();
          final type = (r['skipType'] ?? '').toString();
          if (start == null || end == null || end <= start) continue;
          if (type != 'op' && type != 'ed') continue;
          intervals.add(SkipInterval(type: type, start: start, end: end));
        }
      }
      _intervalCache[key] = intervals;
      KazumiLogger().i(
          'SkipTime: intervals malId=$malId ep=$episodeNumber → ${intervals.length}');
      return intervals;
    } on DioException catch (e) {
      // 404 = 该集无社区数据 (负缓存); 其余失败不缓存 (下次 tick 重试)
      if (e.response?.statusCode == 404) {
        _intervalCache[key] = const [];
        KazumiLogger()
            .i('SkipTime: intervals malId=$malId ep=$episodeNumber → 无数据');
        return const [];
      }
      rethrow;
    } catch (e) {
      KazumiLogger().i('SkipTime: aniskip query failed: $e');
      rethrow;
    }
  }

  /// 归一化 (全角转半角, 小写, 去空白/装饰符) 后 bigram Dice 相似度。
  /// [my修复] 保留尾部 ! ? 等标点 —— "けいおん!" vs "けいおん!!" (一/二季)
  /// 靠它区分, 剥掉则归一化后全同 → 平票按序错配 (实测 bgm 3736 被解析到
  /// 第二季 7791)。
  static double similarity(String a, String b) {
    String norm(String s) {
      var t = s
          .replaceAll('！', '!')
          .replaceAll('？', '?')
          .replaceAll('：', ':')
          .replaceAll('，', ',')
          .toLowerCase();
      t = t.replaceAll(
          RegExp(r'[\s　·・~～\-–—_「」『』【】\[\]()（）,]+'), '');
      return t;
    }
    final x = norm(a);
    final y = norm(b);
    if (x.length < 2 || y.length < 2) return x == y ? 1.0 : 0.0;
    final grams = <String, int>{};
    for (var i = 0; i < x.length - 1; i++) {
      final g = x.substring(i, i + 2);
      grams[g] = (grams[g] ?? 0) + 1;
    }
    var hit = 0;
    for (var i = 0; i < y.length - 1; i++) {
      final g = y.substring(i, i + 2);
      final c = grams[g];
      if (c != null && c > 0) {
        grams[g] = c - 1;
        hit++;
      }
    }
    return 2 * hit / (x.length - 1 + y.length - 1);
  }
}
