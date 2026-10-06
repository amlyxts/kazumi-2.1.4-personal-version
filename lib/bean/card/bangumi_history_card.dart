import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/widget/collect_button.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/pages/video/local_video_launcher.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/video/local_cover_service.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/utils/device.dart';
import 'package:kazumi/utils/date_time.dart';

String historySourceText(String entryKind) {
  return HistoryEntryKind.normalize(entryKind) == HistoryEntryKind.offline
      ? '缓存'
      : '在线';
}

Future<HistoryPlaybackOpenResult> openHistoryPlaybackForEntry({
  required String entryKind,
  required Future<bool> Function() openOnlinePlayback,
  required Future<bool> Function() openOfflinePlayback,
}) async {
  if (HistoryEntryKind.normalize(entryKind) == HistoryEntryKind.offline) {
    final opened = await openOfflinePlayback();
    return HistoryPlaybackOpenResult(
      opened: opened,
      failureMessage: opened ? null : '未找到可用缓存',
    );
  }

  final opened = await openOnlinePlayback();
  return HistoryPlaybackOpenResult(
    opened: opened,
    failureMessage: opened ? null : '在线源不可用，请重新选择播放源',
  );
}

class HistoryPlaybackOpenResult {
  const HistoryPlaybackOpenResult({
    required this.opened,
    required this.failureMessage,
  });

  final bool opened;
  final String? failureMessage;
}

// 视频历史记录卡片 - 水平布局
class BangumiHistoryCardV extends StatefulWidget {
  const BangumiHistoryCardV({
    super.key,
    required this.historyItem,
    this.showDelete = false,
    this.onDeleted,
  });

  final History historyItem;
  final bool showDelete;
  final VoidCallback? onDeleted;

  @override
  State<BangumiHistoryCardV> createState() => _BangumiHistoryCardVState();
}

class _BangumiHistoryCardVState extends State<BangumiHistoryCardV> {
  final VideoPageController videoPageController =
      Modular.get<VideoPageController>();
  final PluginsController pluginsController = Modular.get<PluginsController>();
  final CollectController collectController = Modular.get<CollectController>();
  final DownloadController downloadController =
      Modular.get<DownloadController>();
  final HistoryController historyController = Modular.get<HistoryController>();

  bool get _isLocalHistoryEntry =>
      widget.historyItem.adapterName == localVideoPluginName;

  // [my修改] 本地条目封面: 与本地视频库页共用 mpv 截帧缓存 (local_covers/),
  // 异步加载; null 且加载完成 = 文件缺失 (占位换破损图标)
  String? _localCoverPath;
  bool _localCoverMissing = false;

  @override
  void initState() {
    super.initState();
    if (_isLocalHistoryEntry) {
      _loadLocalCover();
    }
  }

  Future<void> _loadLocalCover() async {
    String? cover;
    try {
      cover = await LocalVideoCoverService.coverForFolder(
          localEntryDirectory(widget.historyItem.episodePageUrl));
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _localCoverPath = cover;
      _localCoverMissing = cover == null;
    });
  }

  Future<void> _onTap() async {
    if (widget.showDelete) {
      KazumiDialog.showToast(message: '编辑模式');
      return;
    }
    // [本地播放] 本地条目自己处理失败提示与死条目清理，不走通用 loading 流程
    if (_isLocalHistoryEntry) {
      final opened = await _openLocalPlayback();
      if (opened) {
        Modular.to.pushNamed('/video/');
      }
      return;
    }
    KazumiDialog.showLoading(
      msg: '获取中',
      barrierDismissible: isDesktop(),
      onDismiss: () {
        videoPageController.cancelQueryRoads();
      },
    );
    final result = await openHistoryPlaybackForEntry(
      entryKind: widget.historyItem.entryKind,
      openOnlinePlayback: _openOnlinePlayback,
      openOfflinePlayback: _openOfflinePlayback,
    );
    KazumiDialog.dismiss();
    if (result.opened) {
      Modular.to.pushNamed('/video/');
      return;
    }
    KazumiDialog.showToast(message: result.failureMessage ?? '未找到可用播放入口');
  }

  /// [本地播放] 本地条目续播：episodePageUrl 存的是最后播放文件的绝对路径。
  /// 三级降级：文件在 → 重扫文件夹重建列表续播；文件没了但文件夹还在 →
  /// 按上次集数就近定位；文件夹也没了 → 提示并可一键清理死条目。
  Future<bool> _openLocalPlayback() async {
    final storedPath = widget.historyItem.episodePageUrl;
    final lastEpisode = widget.historyItem.lastWatchEpisode;

    final fileExists = storedPath.isNotEmpty && File(storedPath).existsSync();
    final folder = localEntryDirectory(storedPath);
    List<String> files;
    int startEpisode;

    if (fileExists) {
      files = listLocalVideoFiles(folder);
      // [my修改] 归一化后比对, 避免反斜杠/正斜杠不一致导致只挂单个文件
      final index = files.indexWhere(
          (f) => normalizeLocalPath(f) == normalizeLocalPath(storedPath));
      files = index >= 0 ? files : [storedPath];
      startEpisode = index >= 0 ? index + 1 : 1;
    } else {
      files = listLocalVideoFiles(folder);
      if (files.isEmpty) {
        KazumiDialog.showToast(message: '本地文件已不存在');
        _confirmDeleteStaleHistory();
        return false;
      }
      startEpisode = lastEpisode.clamp(1, files.length).toInt();
    }

    videoPageController.initForLocalFilePlayback(
      bangumiItem: widget.historyItem.bangumiItem,
      filePaths: files,
      startEpisode: startEpisode,
    );
    return true;
  }

  void _confirmDeleteStaleHistory() {
    KazumiDialog.show(
      builder: (context) => AlertDialog(
        title: const Text('删除历史记录'),
        content: const Text('本地文件已不存在，是否删除这条历史记录？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              historyController.deleteHistory(widget.historyItem);
              widget.onDeleted?.call();
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  Future<bool> _openOnlinePlayback() async {
    if (widget.historyItem.lastSrc.isEmpty) {
      return false;
    }
    Plugin? targetPlugin;
    for (Plugin plugin in pluginsController.pluginList) {
      if (plugin.name == widget.historyItem.adapterName) {
        targetPlugin = plugin;
        break;
      }
    }
    if (targetPlugin == null) {
      return false;
    }
    videoPageController.bangumiItem = widget.historyItem.bangumiItem;
    videoPageController.currentPlugin = targetPlugin;
    videoPageController.title = widget.historyItem.bangumiItem.nameCn == ''
        ? widget.historyItem.bangumiItem.name
        : widget.historyItem.bangumiItem.nameCn;
    videoPageController.src = widget.historyItem.lastSrc;
    try {
      await videoPageController.queryRoads(
        widget.historyItem.lastSrc,
        targetPlugin.name,
      );
      return true;
    } catch (_) {
      KazumiLogger().w("QueryManager: failed to query roads");
      return false;
    }
  }

  Future<bool> _openOfflinePlayback() async {
    final downloadedEpisodes = downloadController.getCompletedEpisodes(
      widget.historyItem.bangumiItem.id,
      widget.historyItem.adapterName,
    );
    if (downloadedEpisodes.isEmpty) {
      return false;
    }

    DownloadEpisode? targetEpisode;
    if (widget.historyItem.episodePageUrl.isNotEmpty) {
      for (final episode in downloadedEpisodes) {
        if (episode.episodePageUrl == widget.historyItem.episodePageUrl) {
          targetEpisode = episode;
          break;
        }
      }
    }
    targetEpisode ??= _episodeByNumber(
      downloadedEpisodes,
      widget.historyItem.lastWatchEpisode,
    );
    if (targetEpisode == null) {
      return false;
    }

    final localPath = downloadController.getLocalVideoPath(
      widget.historyItem.bangumiItem.id,
      widget.historyItem.adapterName,
      targetEpisode.episodeNumber,
    );
    if (localPath == null) {
      return false;
    }

    videoPageController.initForOfflinePlayback(
      bangumiItem: widget.historyItem.bangumiItem,
      pluginName: widget.historyItem.adapterName,
      episodeNumber: targetEpisode.episodeNumber,
      road: targetEpisode.road,
      downloadedEpisodes: downloadedEpisodes,
    );
    return true;
  }

  DownloadEpisode? _episodeByNumber(
    List<DownloadEpisode> episodes,
    int episodeNumber,
  ) {
    for (final episode in episodes) {
      if (episode.episodeNumber == episodeNumber) {
        return episode;
      }
    }
    return null;
  }

  /// [my修改] 本地条目封面渲染: 截帧缓存命中用 Image.file, 否则占位图标
  Widget _buildLocalCover(
      ThemeData theme, ColorScheme colorScheme, double w, double h) {
    final coverExists =
        _localCoverPath != null && File(_localCoverPath!).existsSync();
    return SizedBox(
      width: w,
      height: h,
      child: coverExists
          ? Image.file(
              File(_localCoverPath!),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => Container(
                color: colorScheme.surfaceContainerHighest,
                alignment: Alignment.center,
                child: Icon(Icons.movie_outlined,
                    size: 32, color: colorScheme.onSurfaceVariant),
              ),
            )
          : Container(
              color: colorScheme.surfaceContainerHighest,
              alignment: Alignment.center,
              child: Icon(
                _localCoverMissing
                    ? Icons.broken_image_outlined
                    : Icons.movie_outlined,
                size: 32,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final double imageWidth = 80;
    final double imageHeight = 108;
    final String title = widget.historyItem.bangumiItem.nameCn == ''
        ? widget.historyItem.bangumiItem.name
        : widget.historyItem.bangumiItem.nameCn;
    final String episodeText = widget.historyItem.lastWatchEpisodeName.isEmpty
        ? '第${widget.historyItem.lastWatchEpisode}话'
        : widget.historyItem.lastWatchEpisodeName;
    final String sourceText = historySourceText(widget.historyItem.entryKind);

    return Dismissible(
      key: ValueKey(widget.historyItem.key),
      direction: DismissDirection.endToStart,
      onDismissed: (_) {
        widget.onDeleted?.call();
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        decoration: BoxDecoration(
          color: colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Icon(
          Icons.delete_outline,
          color: colorScheme.onErrorContainer,
        ),
      ),
      child: Card(
        elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        clipBehavior: Clip.antiAlias,
        color: colorScheme.surfaceContainerLow,
        child: InkWell(
          onTap: _onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _isLocalHistoryEntry
                      ? _buildLocalCover(
                          theme, colorScheme, imageWidth, imageHeight)
                      : NetworkImgLayer(
                          src: widget.historyItem.bangumiItem.images['large'] ??
                              '',
                          width: imageWidth,
                          height: imageHeight,
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: imageHeight,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: colorScheme.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Icon(
                              Icons.play_circle_outline,
                              size: 14,
                              color: colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                episodeText,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              Icons.extension_outlined,
                              size: 14,
                              color: colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                _isLocalHistoryEntry
                                    ? '本地视频'
                                    : '$sourceText · ${widget.historyItem.adapterName}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                              ),
                            ),
                          ],
                        ),
                        const Spacer(),
                        Row(
                          children: [
                            Icon(
                              Icons.access_time,
                              size: 12,
                              color: colorScheme.outline,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              formatTimestampToRelativeTime(widget.historyItem
                                      .lastWatchTime.millisecondsSinceEpoch ~/
                                  1000),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colorScheme.outline,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!widget.showDelete && !_isLocalHistoryEntry) ...[
                      Observer(
                        builder: (context) {
                          collectController.collectibles.length;
                          return CollectButton(
                            onClose: () {
                              FocusScope.of(context).unfocus();
                            },
                            bangumiItem: widget.historyItem.bangumiItem,
                            color: colorScheme.onSurfaceVariant,
                          );
                        },
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.open_in_new,
                          size: 20,
                          color: colorScheme.onSurfaceVariant,
                        ),
                        tooltip: '番剧详情',
                        onPressed: () {
                          Modular.to.pushNamed(
                            '/info/',
                            arguments: widget.historyItem.bangumiItem,
                          );
                        },
                      ),
                    ],
                    if (widget.showDelete)
                      IconButton(
                        icon: Icon(
                          Icons.delete_outline,
                          color: colorScheme.error,
                        ),
                        tooltip: '删除记录',
                        onPressed: () {
                          widget.onDeleted?.call();
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
