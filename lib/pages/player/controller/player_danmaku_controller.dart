// ignore_for_file: library_private_types_in_public_api

import 'package:canvas_danmaku/canvas_danmaku.dart' as canvas;
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/request/apis/danmaku_api.dart';
import 'package:kazumi/services/danmaku/danmaku_alignment_service.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:mobx/mobx.dart';
import 'package:kazumi/utils/danmaku.dart';

part 'player_danmaku_controller.g.dart';

class PlayerDanmakuController = _PlayerDanmakuController
    with _$PlayerDanmakuController;

enum DanmakuLoadStatus {
  success,
  empty,
  failed,
}

class DanmakuLoadResult {
  const DanmakuLoadResult({
    required this.danmakus,
    required this.bangumiID,
    required this.status,
  });

  factory DanmakuLoadResult.success({
    required List<DanmakuEntry> danmakus,
    required int bangumiID,
  }) {
    return DanmakuLoadResult(
      danmakus: danmakus,
      bangumiID: bangumiID,
      status: danmakus.isEmpty
          ? DanmakuLoadStatus.empty
          : DanmakuLoadStatus.success,
    );
  }

  factory DanmakuLoadResult.failed({
    required int bangumiID,
  }) {
    return DanmakuLoadResult(
      danmakus: const [],
      bangumiID: bangumiID,
      status: DanmakuLoadStatus.failed,
    );
  }

  final List<DanmakuEntry> danmakus;
  final int bangumiID;
  final DanmakuLoadStatus status;

  bool get hasDanmakus => status == DanmakuLoadStatus.success;

  bool get isFailed => status == DanmakuLoadStatus.failed;
}

class DanmakuTimeline {
  static int? resolveSourceSecond(
    Duration playbackPosition,
    double timelineOffsetSeconds,
  ) {
    final sourceMilliseconds = playbackPosition.inMilliseconds -
        (timelineOffsetSeconds * 1000).round();
    if (sourceMilliseconds < 0) {
      return null;
    }
    return Duration(milliseconds: sourceMilliseconds).inSeconds;
  }

  static int staggerDelayMilliseconds({
    required int index,
    required int total,
  }) {
    if (total <= 0) {
      return 0;
    }
    return index * 1000 ~/ total;
  }
}

abstract class _PlayerDanmakuController with Store {
  _PlayerDanmakuController({
    required this.isLocalPlayback,
    required this.downloadController,
  });

  final bool Function() isLocalPlayback;
  final DownloadController downloadController;

  late canvas.DanmakuController canvasController;

  final Map<int, List<DanmakuEntry>> danDanmakus = {};
  @observable
  bool danmakuOn = false;
  @observable
  bool danmakuLoading = false;

  int bangumiID = 0;
  int _scheduledDanmakuGeneration = 0;

  int get scheduledDanmakuGeneration => _scheduledDanmakuGeneration;

  double get timelineOffsetSeconds {
    final offset = GStorage.getSetting(SettingsKeys.danmakuTimeOffset);
    return offset;
  }

  int? resolveDanmakuSecond(Duration playbackPosition) {
    return DanmakuTimeline.resolveSourceSecond(
      playbackPosition,
      timelineOffsetSeconds,
    );
  }

  List<DanmakuEntry> danmakusForPlaybackPosition(Duration playbackPosition) {
    final danmakuSecond = resolveDanmakuSecond(playbackPosition);
    if (danmakuSecond == null) {
      return const [];
    }
    return danDanmakus[danmakuSecond] ?? const [];
  }

  @action
  void setDanmakuEnabled(bool value) {
    danmakuOn = value;
  }

  void clearAndInvalidateScheduledDanmakus() {
    _scheduledDanmakuGeneration++;
    canvasController.clear();
  }

  // Apply fetched data only after VideoPageController validates the session.
  /// [my修改] 单一解析点: 锚点 → 推断 → 自动(+正片校验+顺手转锚点)。
  /// 见 DanmakuAlignmentService (弹幕匹配探查报告_20261024.md)。
  /// itemTitle 供跨季推断检索同系列条目。
  Future<DanmakuLoadResult> fetchDanmaku(
    int bangumiId,
    String pluginName,
    int episode, {
    String? itemTitle,
  }) async {
    if (isLocalPlayback()) {
      // 离线: 缓存优先 (缓存键本就是 源集), 未命中走在线解析链并存缓存
      final cached = await _fetchCachedDanmaku(bangumiId, pluginName, episode);
      if (cached.hasDanmakus) return cached;
      final online =
          await _resolveAlignedOnline(bangumiId, pluginName, episode,
              itemTitle: itemTitle, cacheTo: (danmakus, dandanId) {
        _saveDanmakuToCache(
            downloadController, bangumiId, pluginName, episode, danmakus,
            dandanId);
      });
      return online;
    }
    return _resolveAlignedOnline(bangumiId, pluginName, episode,
        itemTitle: itemTitle, cacheTo: null);
  }

  Future<DanmakuLoadResult> _resolveAlignedOnline(
    int bangumiId,
    String pluginName,
    int srcEp, {
    String? itemTitle,
    void Function(List<DanmakuEntry> danmakus, int dandanId)? cacheTo,
  }) async {
    final align = DanmakuAlignmentService.instance;

    DanmakuMatchInfo matchInfo(String source,
            {int? episodeId, String? animeTitle, String? episodeTitle,
             String? note}) =>
        DanmakuMatchInfo(
          source: source,
          bgmId: bangumiId,
          pluginName: pluginName,
          srcEp: srcEp,
          episodeId: episodeId,
          animeTitle: animeTitle,
          episodeTitle: episodeTitle,
          note: note,
        );

    Future<DanmakuLoadResult?> fetchByEpisodeId(int episodeId) async {
      try {
        final res = await DanmakuApi.getDanDanmakuByEpisodeID(episodeId);
        cacheTo?.call(res, episodeId ~/ 10000);
        return DanmakuLoadResult.success(
            danmakus: res, bangumiID: episodeId ~/ 10000);
      } catch (_) {
        return null; // 落到下一级
      }
    }

    // 1) 锚点
    final anchor = align.anchorFor(bangumiId, pluginName, srcEp);
    if (anchor != null) {
      final r = await fetchByEpisodeId(anchor.episodeId);
      if (r != null) {
        align.lastMatch = matchInfo('anchor',
            episodeId: anchor.episodeId, episodeTitle: anchor.title);
        return r;
      }
    }

    // 2) 推断 (插值/外推/跨季滚动)
    try {
      final inferred = await align.infer(
          bgmId: bangumiId, plugin: pluginName, srcEp: srcEp,
          itemTitle: itemTitle);
      if (inferred != null) {
        final r = await fetchByEpisodeId(inferred.episodeId);
        if (r != null) {
          align.lastMatch = matchInfo('inferred',
              episodeId: inferred.episodeId,
              episodeTitle: inferred.episodeTitle);
          return r;
        }
      }
    } catch (e) {
      KazumiLogger().w('PlayerController: danmaku inference failed', error: e);
    }

    // 3) 自动: bgm 映射 + 正片校验 (治"成功但命中 OP/ED")
    return await _fetchDanDanmakuWithValidation(
        bangumiId, pluginName, srcEp, align, matchInfo, cacheTo);
  }

  Future<DanmakuLoadResult> _fetchDanDanmakuWithValidation(
    int bgmBangumiID,
    String pluginName,
    int episode,
    DanmakuAlignmentService align,
    DanmakuMatchInfo Function(String,
            {int? episodeId,
            String? animeTitle,
            String? episodeTitle,
            String? note})
        matchInfo,
    void Function(List<DanmakuEntry>, int)? cacheTo,
  ) async {
    var nextBangumiID = bangumiID;
    try {
      nextBangumiID =
          await DanmakuApi.getDanDanBangumiIDByBgmBangumiID(bgmBangumiID);
      if (nextBangumiID == 0) {
        // 无映射 (含直连浏览哈希条目): 快速结束, 不做标题搜索 —
        // dandanplay 无 R18 收录, 中文标题搜索注定 12s 白等
        align.lastMatch = matchInfo('none');
        return DanmakuLoadResult.success(
          danmakus: const [],
          bangumiID: nextBangumiID,
        );
      }
      // 正片校验
      final suspect = await align.validateAutoTarget(nextBangumiID, episode);
      if (suspect != null) {
        align.lastMatch = matchInfo('suspect', note: suspect);
        KazumiLogger().w(
            'PlayerController: danmaku suspect mismatch: $suspect');
        return DanmakuLoadResult.success(
          danmakus: const [],
          bangumiID: nextBangumiID,
        );
      }
      var res = await DanmakuApi.getDanDanmaku(nextBangumiID, episode);
      // 校验通过的自动命中顺手转正为锚点 (推断从此有大量免费锚点)
      if (res.isNotEmpty) {
        final eps = await align.episodesOf(nextBangumiID);
        final title = episode <= eps.length
            ? eps[episode - 1].episodeTitle
            : '';
        await align.writeAnchor(bgmBangumiID, pluginName, episode,
            nextBangumiID * 10000 + episode, title);
        align.lastMatch = matchInfo('auto', episodeTitle: title);
      } else {
        align.lastMatch = matchInfo('none');
      }
      cacheTo?.call(res, nextBangumiID);
      return DanmakuLoadResult.success(
        danmakus: res,
        bangumiID: nextBangumiID,
      );
    } catch (e) {
      KazumiLogger().w(
          'PlayerController: failed to get danmaku [BgmBangumiID] $bgmBangumiID',
          error: e);
    }
    return DanmakuLoadResult.failed(bangumiID: nextBangumiID);
  }

  @action
  void beginDanmakuLoad() {
    danDanmakus.clear();
    danmakuLoading = true;
  }

  @action
  void applyDanmakuLoad(
    DanmakuLoadResult result, {
    required bool enableDanmaku,
  }) {
    bangumiID = result.bangumiID;
    addDanmakus(result.danmakus);
    danmakuOn = enableDanmaku;
    danmakuLoading = false;
  }

  @action
  void applyUnavailableDanmakuLoad(DanmakuLoadResult result) {
    bangumiID = result.bangumiID;
    danDanmakus.clear();
    danmakuOn = false;
    danmakuLoading = false;
  }

  @action
  void finishDanmakuLoad({bool disableDanmaku = false}) {
    if (disableDanmaku) {
      danDanmakus.clear();
      danmakuOn = false;
    }
    danmakuLoading = false;
  }

  Future<DanmakuLoadResult> _fetchCachedDanmaku(
      int bangumiId, String pluginName, int episode) async {
    KazumiLogger().i(
        'PlayerController: attempting to load cached danmaku for episode $episode');
    var nextBangumiID = bangumiID;
    try {
      final cachedDanmakus = await downloadController.getCachedDanmakus(
        bangumiId,
        pluginName,
        episode,
      );

      if (cachedDanmakus != null && cachedDanmakus.isNotEmpty) {
        KazumiLogger().i(
            'PlayerController: loaded ${cachedDanmakus.length} cached danmakus');
        return DanmakuLoadResult.success(
          danmakus: cachedDanmakus,
          bangumiID: nextBangumiID,
        );
      } else {
        KazumiLogger()
            .i('PlayerController: no cached danmaku, attempting online fetch');
        try {
          nextBangumiID =
              await DanmakuApi.getDanDanBangumiIDByBgmBangumiID(bangumiId);
          if (nextBangumiID != 0) {
            var res = await DanmakuApi.getDanDanmaku(nextBangumiID, episode);
            if (res.isNotEmpty) {
              KazumiLogger()
                  .i('PlayerController: fetched ${res.length} danmakus online');
              _saveDanmakuToCache(downloadController, bangumiId, pluginName,
                  episode, res, nextBangumiID);
            }
            return DanmakuLoadResult.success(
              danmakus: res,
              bangumiID: nextBangumiID,
            );
          }
        } catch (e) {
          KazumiLogger().w(
              'PlayerController: failed to fetch danmaku online (may be offline)',
              error: e);
          return DanmakuLoadResult.failed(bangumiID: nextBangumiID);
        }
      }
    } catch (e) {
      KazumiLogger()
          .w('PlayerController: failed to load cached danmaku', error: e);
      return DanmakuLoadResult.failed(bangumiID: nextBangumiID);
    }
    return DanmakuLoadResult.success(
      danmakus: const [],
      bangumiID: nextBangumiID,
    );
  }

  void _saveDanmakuToCache(
      DownloadController downloadController,
      int bangumiId,
      String pluginName,
      int episode,
      List<DanmakuEntry> danmakus,
      int danDanID) {
    try {
      downloadController.updateCachedDanmakus(
        bangumiId,
        pluginName,
        episode,
        danmakus,
        danDanID,
      );
      KazumiLogger()
          .i('PlayerController: saved ${danmakus.length} danmakus to cache');
    } catch (e) {
      KazumiLogger()
          .w('PlayerController: failed to save danmaku to cache', error: e);
    }
  }

  @action
  Future<bool> getDanDanmakuByEpisodeID(int episodeID) async {
    KazumiLogger().i('PlayerController: attempting to get danmaku $episodeID');
    danmakuLoading = true;
    try {
      danDanmakus.clear();
      var res = await DanmakuApi.getDanDanmakuByEpisodeID(episodeID);
      addDanmakus(res);
      return res.isNotEmpty;
    } catch (e) {
      KazumiLogger().w('PlayerController: failed to get danmaku', error: e);
      rethrow;
    } finally {
      danmakuLoading = false;
    }
  }

  void addDanmakus(List<DanmakuEntry> danmakus) {
    final bool danmakuDeduplicationEnable =
        GStorage.getSetting(SettingsKeys.danmakuDeduplication);

    final List<DanmakuEntry> listToAdd = danmakuDeduplicationEnable
        ? mergeDuplicateDanmakus(danmakus, timeWindowSeconds: 5)
        : danmakus;

    for (final element in listToAdd) {
      final danmakuSecond = element.time.toInt();
      (danDanmakus[danmakuSecond] ??= <DanmakuEntry>[]).add(element);
    }
  }

  void updateDanmakuSpeed(double playerSpeed) {
    final baseDuration = GStorage.getSetting(SettingsKeys.danmakuDuration);
    final followSpeed = GStorage.getSetting(SettingsKeys.danmakuFollowSpeed);

    final duration = followSpeed ? (baseDuration / playerSpeed) : baseDuration;
    canvasController
        .updateOption(canvasController.option.copyWith(duration: duration));
  }
}
