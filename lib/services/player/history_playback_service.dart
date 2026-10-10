import 'dart:io';

import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart'
    show RuleCancelToken;
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/utils/local_video_utils.dart';

sealed class HistoryPlaybackResult {
  const HistoryPlaybackResult();
}

class HistoryPlaybackReady extends HistoryPlaybackResult {
  const HistoryPlaybackReady(this.args);

  final VideoPlaybackArgs args;
}

class HistoryPlaybackUnavailable extends HistoryPlaybackResult {
  const HistoryPlaybackUnavailable(this.reason);

  final String reason;
}

/// [my修改] 本地条目的源文件已不存在，调用方应提示并询问是否清理死条目
class HistoryPlaybackStale extends HistoryPlaybackResult {
  const HistoryPlaybackStale(this.reason);

  final String reason;
}

/// Restores a history entry into arguments the player route can take.
///
/// The history page and the my page share this one resolution path; cards
/// carry no source-lookup logic of their own.
class HistoryPlaybackService {
  HistoryPlaybackService(this._pluginsController, this._downloadController);

  final PluginsController _pluginsController;
  final DownloadController _downloadController;

  /// [cancelToken] lets the caller abort the online lookup, e.g. when the
  /// loading dialog it put up is dismissed.
  Future<HistoryPlaybackResult> open(
    History history, {
    RuleCancelToken? cancelToken,
  }) async {
    // [my修改] 本地视频条目走专用恢复路径
    if (history.adapterName == localVideoPluginName) {
      return _localArgs(history);
    }

    if (HistoryEntryKind.normalize(history.entryKind) ==
        HistoryEntryKind.offline) {
      final args = _offlineArgs(history);
      return args == null
          ? const HistoryPlaybackUnavailable('未找到可用缓存')
          : HistoryPlaybackReady(args);
    }

    final args = await _onlineArgs(history, cancelToken);
    return args == null
        ? const HistoryPlaybackUnavailable('在线源不可用，请重新选择播放源')
        : HistoryPlaybackReady(args);
  }

  /// [my修改] 本地条目续播：episodePageUrl 存的是最后播放文件的绝对路径。
  /// 三级降级：文件在 → 重扫文件夹重建列表续播；文件没了但文件夹还在 →
  /// 按上次集数就近定位；彻底没了 → Stale 结果让调用方询问清理。
  HistoryPlaybackResult _localArgs(History history) {
    final storedPath = history.episodePageUrl;
    final fileExists = storedPath.isNotEmpty && File(storedPath).existsSync();
    final folder = localEntryDirectory(storedPath);
    List<String> files;
    int startEpisode;

    if (fileExists) {
      files = listLocalVideoFiles(folder);
      final index = files.indexOf(storedPath);
      if (index < 0) {
        files = [storedPath];
        startEpisode = 1;
      } else {
        startEpisode = index + 1;
      }
    } else {
      files = listLocalVideoFiles(folder);
      if (files.isEmpty) {
        return const HistoryPlaybackStale('本地文件已不存在');
      }
      startEpisode = history.lastWatchEpisode.clamp(1, files.length).toInt();
    }

    return HistoryPlaybackReady(LocalVideoPlaybackArgs(
      bangumiItem: history.bangumiItem,
      filePaths: files,
      startEpisode: startEpisode,
    ));
  }

  Future<VideoPlaybackArgs?> _onlineArgs(
    History history,
    RuleCancelToken? cancelToken,
  ) async {
    if (history.lastSrc.isEmpty) {
      return null;
    }
    Plugin? targetPlugin;
    for (final plugin in _pluginsController.pluginList) {
      if (plugin.name == history.adapterName) {
        targetPlugin = plugin;
        break;
      }
    }
    if (targetPlugin == null) {
      return null;
    }
    try {
      final roads = await targetPlugin.queryChapterRoads(
        history.lastSrc,
        cancelToken: cancelToken,
      );
      if (roads.isEmpty) {
        return null;
      }
      return OnlineVideoPlaybackArgs(
        bangumiItem: history.bangumiItem,
        plugin: targetPlugin,
        title: history.bangumiItem.nameCn.isEmpty
            ? history.bangumiItem.name
            : history.bangumiItem.nameCn,
        src: history.lastSrc,
        roads: roads,
      );
    } catch (_) {
      KazumiLogger().w("QueryManager: failed to query roads");
      return null;
    }
  }

  VideoPlaybackArgs? _offlineArgs(History history) {
    final downloadedEpisodes = _downloadController.getCompletedEpisodes(
      history.bangumiItem.id,
      history.adapterName,
    );
    if (downloadedEpisodes.isEmpty) {
      return null;
    }

    // The page url pins the exact episode; the number is the legacy fallback.
    DownloadEpisode? targetEpisode;
    DownloadEpisode? numberMatch;
    for (final episode in downloadedEpisodes) {
      if (history.episodePageUrl.isNotEmpty &&
          episode.episodePageUrl == history.episodePageUrl) {
        targetEpisode = episode;
        break;
      }
      if (episode.episodeNumber == history.lastWatchEpisode) {
        numberMatch ??= episode;
      }
    }
    targetEpisode ??= numberMatch;
    if (targetEpisode == null) {
      return null;
    }

    final localPath = _downloadController.getLocalVideoPath(
      history.bangumiItem.id,
      history.adapterName,
      targetEpisode.episodeNumber,
    );
    if (localPath == null) {
      return null;
    }

    return OfflineVideoPlaybackArgs(
      bangumiItem: history.bangumiItem,
      pluginName: history.adapterName,
      episodeNumber: targetEpisode.episodeNumber,
      road: targetEpisode.road,
      downloadedEpisodes: downloadedEpisodes,
    );
  }
}
