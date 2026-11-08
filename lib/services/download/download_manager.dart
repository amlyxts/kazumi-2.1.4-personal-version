import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/request/clients/download_http_client.dart';
import 'package:kazumi/request/core/network_exception.dart';
import 'package:kazumi/utils/m3u8_parser.dart';
import 'package:kazumi/utils/m3u8_ad_filter.dart';
import 'package:kazumi/utils/format.dart' as fmt;
import 'package:kazumi/utils/file_system.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/download/download_directory_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path/path.dart' as path;

class _NotM3u8Exception implements Exception {
  final String message;
  _NotM3u8Exception(this.message);
  @override
  String toString() => message;
}

class _InsufficientStorageException implements Exception {
  final int availableBytes;
  final int requiredBytes;
  _InsufficientStorageException(this.availableBytes, this.requiredBytes);
  @override
  String toString() => '存储空间不足';
}

class DownloadTask {
  final String recordKey;
  final int episodeNumber;
  CancelToken cancelToken;
  bool isPaused;

  DownloadTask({
    required this.recordKey,
    required this.episodeNumber,
    CancelToken? cancelToken,
    this.isPaused = false,
  }) : cancelToken = cancelToken ?? CancelToken();
}

typedef ProgressCallback = void Function(
    String recordKey, int episodeNumber, DownloadEpisode episode, double speed);

final _m3u8SegmentFileNamePattern = RegExp(r'^seg_\d+\.ts$');

Future<int> calculateM3u8VideoBytes(String episodeDir) async {
  final dir = Directory(episodeDir);
  if (!await dir.exists()) return 0;

  var totalBytes = 0;
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is! File) continue;
    final name = entity.uri.pathSegments.isNotEmpty
        ? Uri.decodeComponent(entity.uri.pathSegments.last)
        : entity.path.split(Platform.pathSeparator).last;
    if (!_m3u8SegmentFileNamePattern.hasMatch(name)) continue;

    try {
      totalBytes += await entity.length();
    } on FileSystemException {
      // Ignore transient filesystem failures while reporting display size.
    }
  }
  return totalBytes;
}

class DownloadRequest {
  final String recordKey;
  final int bangumiId;
  final String pluginName;
  final int episodeNumber;
  final String m3u8Url;
  final Map<String, String> httpHeaders;
  final bool adBlockerEnabled;
  final DownloadEpisode episode;

  const DownloadRequest({
    required this.recordKey,
    required this.bangumiId,
    required this.pluginName,
    required this.episodeNumber,
    required this.m3u8Url,
    required this.httpHeaders,
    required this.adBlockerEnabled,
    required this.episode,
  });
}

abstract class IDownloadManager {
  ProgressCallback? onProgress;

  bool isDownloading(String recordKey, int episodeNumber);
  Future<void> enqueue(DownloadRequest request);
  Future<void> enqueuePriority(DownloadRequest request);
  void pause(String recordKey, int episodeNumber);
  Future<void> resume(DownloadRequest request);
  void cancel(String recordKey, int episodeNumber);
  String? getLocalVideoPath(DownloadEpisode? episode);
  Future<void> deleteEpisodeFiles(
      int bangumiId, String pluginName, int episodeNumber,
      {DownloadEpisode? episode});
  Future<void> deleteRecordFiles(int bangumiId, String pluginName,
      {DownloadRecord? record});
  double getSpeed(String recordKey, int episodeNumber);
}

class _SpeedTracker {
  int _lastBytes = 0;
  DateTime _lastTime = DateTime.now();
  double currentSpeed = 0.0; // bytes/sec

  void update(int totalBytes) {
    final now = DateTime.now();
    final elapsed = now.difference(_lastTime).inMilliseconds;
    if (elapsed > 500) {
      final bytesDownloaded = totalBytes - _lastBytes;
      currentSpeed = bytesDownloaded / (elapsed / 1000);
      _lastBytes = totalBytes;
      _lastTime = now;
    }
  }

  void reset() {
    _lastBytes = 0;
    _lastTime = DateTime.now();
    currentSpeed = 0.0;
  }
}

class DownloadManager implements IDownloadManager {
  DownloadManager() {
    _loadSettings();
  }

  final DownloadHttpClient _http = DownloadHttpClient.instance;
  final DownloadDirectoryService _directoryService = DownloadDirectoryService();

  final Map<String, DownloadTask> _activeTasks = {};
  final List<DownloadRequest> _queue = [];
  final Map<String, _SpeedTracker> _speedTrackers = {};
  int maxParallelEpisodes = 2;
  int maxParallelSegments = 3;
  int _runningCount = 0;

  @override
  ProgressCallback? onProgress;

  static const _minRequiredSpace = 100 * 1024 * 1024; // 100MB minimum
  static const _storageChannel = MethodChannel('com.predidit.kazumi/storage');

  void _loadSettings() {
    maxParallelEpisodes =
        GStorage.getSetting(SettingsKeys.downloadParallelEpisodes);
    maxParallelSegments =
        GStorage.getSetting(SettingsKeys.downloadParallelSegments);
  }

  /// Returns available bytes, or -1 if unable to determine
  Future<int> _getAvailableStorage(String path) async {
    try {
      final result = await _storageChannel.invokeMethod<int>(
        'getAvailableStorage',
        {'path': path},
      );
      return result ?? -1;
    } on MissingPluginException {
      return -1;
    } catch (e) {
      KazumiLogger().w('DownloadManager: failed to get storage info', error: e);
      return -1;
    }
  }

  Future<void> _checkStorageSpace(String downloadDir,
      {int requiredBytes = 0}) async {
    final available = await _getAvailableStorage(downloadDir);
    if (available == -1) return; // Skip check if unable to determine

    final required = requiredBytes > 0 ? requiredBytes : _minRequiredSpace;
    if (available < required) {
      throw _InsufficientStorageException(available, required);
    }
  }

  String _getStorageErrorMessage(FileSystemException e) {
    // POSIX error code 28 = ENOSPC (No space left on device)
    if (e.osError?.errorCode == 28) {
      return '存储空间不足，请清理后重试';
    }
    // POSIX error code 13 = EACCES (Permission denied)
    if (e.osError?.errorCode == 13) {
      return '存储权限被拒绝';
    }
    // POSIX error code 30 = EROFS (Read-only file system)
    if (e.osError?.errorCode == 30) {
      return '存储为只读，无法写入';
    }
    return '存储错误: ${e.message}';
  }

  @override
  double getSpeed(String recordKey, int episodeNumber) {
    final key = _taskKey(recordKey, episodeNumber);
    return _speedTrackers[key]?.currentSpeed ?? 0.0;
  }

  String _taskKey(String recordKey, int episodeNumber) =>
      '${recordKey}_$episodeNumber';

  @override
  bool isDownloading(String recordKey, int episodeNumber) =>
      _activeTasks.containsKey(_taskKey(recordKey, episodeNumber));

  String _getEpisodeDir(String downloadBase, int bangumiId, String pluginName,
      int episodeNumber) {
    return path.join(
        downloadBase, '${bangumiId}_$pluginName', '$episodeNumber');
  }

  /// Resolves the episode directory (kept from a previous attempt if any),
  /// verifies it is writable, and persists it on the episode.
  Future<String> _prepareEpisodeDir(
    DownloadEpisode episode,
    int bangumiId,
    String pluginName,
    int episodeNumber,
  ) async {
    final storedDir = episode.downloadDirectory.trim();
    final episodeDir = storedDir.isNotEmpty
        ? storedDir
        : _getEpisodeDir(await _directoryService.getDownloadDirectory(),
            bangumiId, pluginName, episodeNumber);
    await ensureDirectoryWritable(episodeDir);
    episode.downloadDirectory = episodeDir;
    await _checkStorageSpace(episodeDir);
    return episodeDir;
  }

  /// Directory to remove for an episode: the recorded one, or the default
  /// location for episodes that never started downloading.
  Future<String> _episodeDirForDeletion(
    DownloadEpisode? episode,
    int bangumiId,
    String pluginName,
    int episodeNumber,
  ) async {
    final storedDir = episode?.downloadDirectory.trim() ?? '';
    if (storedDir.isNotEmpty) return storedDir;
    return _getEpisodeDir(await getDefaultDownloadDirectory(), bangumiId,
        pluginName, episodeNumber);
  }

  @override
  Future<void> enqueue(DownloadRequest request) async {
    final key = _taskKey(request.recordKey, request.episodeNumber);
    if (_activeTasks.containsKey(key)) return;

    final task = DownloadTask(
      recordKey: request.recordKey,
      episodeNumber: request.episodeNumber,
    );

    if (_runningCount < maxParallelEpisodes) {
      _runningCount++;
      _activeTasks[key] = task;
      _runEpisodeDownload(
        task: task,
        bangumiId: request.bangumiId,
        pluginName: request.pluginName,
        m3u8Url: request.m3u8Url,
        httpHeaders: request.httpHeaders,
        adBlockerEnabled: request.adBlockerEnabled,
        episode: request.episode,
      );
    } else {
      request.episode.status = DownloadStatus.pending;
      _queue.add(request);
      _activeTasks[key] = task;
    }
  }

  @override
  Future<void> enqueuePriority(DownloadRequest request) async {
    final key = _taskKey(request.recordKey, request.episodeNumber);

    _queue.removeWhere(
      (r) =>
          r.recordKey == request.recordKey &&
          r.episodeNumber == request.episodeNumber,
    );
    _activeTasks.remove(key);

    final task = DownloadTask(
      recordKey: request.recordKey,
      episodeNumber: request.episodeNumber,
    );

    // Start immediately, bypassing the parallel limit (priority download)
    _runningCount++;
    _activeTasks[key] = task;
    _runEpisodeDownload(
      task: task,
      bangumiId: request.bangumiId,
      pluginName: request.pluginName,
      m3u8Url: request.m3u8Url,
      httpHeaders: request.httpHeaders,
      adBlockerEnabled: request.adBlockerEnabled,
      episode: request.episode,
    );
  }

  @override
  void pause(String recordKey, int episodeNumber) {
    final key = _taskKey(recordKey, episodeNumber);
    final task = _activeTasks[key];
    if (task != null) {
      task.isPaused = true;
      task.cancelToken.cancel('paused');
    }
  }

  @override
  Future<void> resume(DownloadRequest request) async {
    final key = _taskKey(request.recordKey, request.episodeNumber);
    _activeTasks.remove(key);

    final task = DownloadTask(
      recordKey: request.recordKey,
      episodeNumber: request.episodeNumber,
    );
    _activeTasks[key] = task;

    if (_runningCount < maxParallelEpisodes) {
      _runningCount++;
      _runEpisodeDownload(
        task: task,
        bangumiId: request.bangumiId,
        pluginName: request.pluginName,
        m3u8Url: request.m3u8Url,
        httpHeaders: request.httpHeaders,
        adBlockerEnabled: request.adBlockerEnabled,
        episode: request.episode,
      );
    } else {
      _queue.add(request);
    }
  }

  @override
  void cancel(String recordKey, int episodeNumber) {
    final key = _taskKey(recordKey, episodeNumber);
    final task = _activeTasks[key];
    if (task != null) {
      // The unwinding worker then leaves its episode paused, never active.
      task.isPaused = true;
      task.cancelToken.cancel('cancelled');
      _activeTasks.remove(key);
      _queue.removeWhere(
        (r) => r.recordKey == recordKey && r.episodeNumber == episodeNumber,
      );
    }
  }

  void _processQueue() {
    while (_runningCount < maxParallelEpisodes && _queue.isNotEmpty) {
      final request = _queue.removeAt(0);
      final key = _taskKey(request.recordKey, request.episodeNumber);
      final existingTask = _activeTasks[key];
      if (existingTask == null ||
          existingTask.isPaused ||
          existingTask.cancelToken.isCancelled) {
        _activeTasks.remove(key);
        continue;
      }

      _runningCount++;
      _runEpisodeDownload(
        task: existingTask,
        bangumiId: request.bangumiId,
        pluginName: request.pluginName,
        m3u8Url: request.m3u8Url,
        httpHeaders: request.httpHeaders,
        adBlockerEnabled: request.adBlockerEnabled,
        episode: request.episode,
      );
    }
  }

  Future<void> _runEpisodeDownload({
    required DownloadTask task,
    required int bangumiId,
    required String pluginName,
    required String m3u8Url,
    required Map<String, String> httpHeaders,
    required bool adBlockerEnabled,
    required DownloadEpisode episode,
  }) async {
    final key = _taskKey(task.recordKey, task.episodeNumber);
    try {
      final episodeDir = await _prepareEpisodeDir(
          episode, bangumiId, pluginName, task.episodeNumber);

      episode.status = DownloadStatus.downloading;
      episode.networkM3u8Url = m3u8Url;
      _notifyProgress(task, episode);

      String m3u8Content;
      try {
        m3u8Content = await _fetchM3u8(m3u8Url, httpHeaders, task.cancelToken);
      } on _NotM3u8Exception {
        KazumiLogger().i(
          'DownloadManager: URL is not M3U8, falling back to direct file download '
          'for episode ${task.episodeNumber}',
        );
        await _runDirectFileDownload(
          task: task,
          bangumiId: bangumiId,
          pluginName: pluginName,
          videoUrl: m3u8Url,
          httpHeaders: httpHeaders,
          episode: episode,
        );
        return;
      }

      final type = M3u8Parser.detectType(m3u8Content);
      String mediaM3u8Content = m3u8Content;
      String mediaM3u8Url = m3u8Url;

      if (type == M3u8Type.master) {
        final master = M3u8Parser.parseMasterPlaylist(m3u8Content, m3u8Url);
        final bestVariant = master.bestVariant;
        mediaM3u8Url = bestVariant.uri;
        mediaM3u8Content =
            await _fetchM3u8(mediaM3u8Url, httpHeaders, task.cancelToken);
      }

      final playlist =
          M3u8Parser.parseMediaPlaylist(mediaM3u8Content, mediaM3u8Url);

      // 展开嵌套 m3u8 片段（部分源将实际内容嵌套在 m3u8 引用中）
      final resolvedSegments = await M3u8Parser.resolveNestedSegments(
        playlist.segments,
        (url) => _fetchM3u8(url, httpHeaders, task.cancelToken),
      );
      final resolvedPlaylist = M3u8MediaPlaylist(
        segments: resolvedSegments,
        targetDuration: playlist.targetDuration,
        isVod: playlist.isVod,
      );

      if (!resolvedPlaylist.isVod) {
        episode.status = DownloadStatus.failed;
        episode.errorMessage = '不支持下载直播流 (无有效分片)';
        _notifyProgress(task, episode);
        return;
      }

      if (resolvedPlaylist.segments.isEmpty) {
        episode.status = DownloadStatus.failed;
        episode.errorMessage = 'M3U8 中未找到可下载的分片';
        _notifyProgress(task, episode);
        return;
      }

      List<M3u8Segment> segments = resolvedPlaylist.segments;
      if (adBlockerEnabled) {
        segments = M3u8AdFilter.filterAds(segments);
      }

      final keys = M3u8Parser.extractUniqueKeys(
        M3u8MediaPlaylist(
          segments: segments,
          targetDuration: resolvedPlaylist.targetDuration,
          isVod: true,
        ),
      );
      final keyUriToLocal = <String, String>{};
      for (int i = 0; i < keys.length; i++) {
        final keyFile = 'key_$i.key';
        final keyPath = path.join(episodeDir, keyFile);
        await _downloadFile(
            keys[i].uri, keyPath, httpHeaders, task.cancelToken);
        keyUriToLocal[keys[i].uri] = keyFile;
      }

      episode.totalSegments = segments.length;
      episode.downloadedSegments = 0;
      _notifyProgress(task, episode);
      final episodeDirObj = Directory(episodeDir);
      if (await episodeDirObj.exists()) {
        await for (final entity in episodeDirObj.list()) {
          if (entity.path.endsWith('.tmp')) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }

      final existingSegments = <int>{};
      var existingBytes = 0;
      for (int i = 0; i < segments.length; i++) {
        final segFile = File(
            path.join(episodeDir, 'seg_${i.toString().padLeft(5, '0')}.ts'));
        if (await segFile.exists()) {
          final segmentBytes = await segFile.length();
          if (segmentBytes <= 0) continue;
          existingSegments.add(i);
          episode.downloadedSegments++;
          existingBytes += segmentBytes;
        }
      }
      episode.totalBytes = existingBytes;
      episode.progressPercent = episode.totalSegments > 0
          ? episode.downloadedSegments / episode.totalSegments
          : 0.0;
      _notifyProgress(task, episode);

      final pendingIndices = <int>[];
      for (int i = 0; i < segments.length; i++) {
        if (!existingSegments.contains(i)) {
          pendingIndices.add(i);
        }
      }

      var sessionBytes = 0;
      final completer = Completer<void>();
      int completedCount = 0;
      int failedCount = 0;
      final semaphore = _Semaphore(maxParallelSegments);

      _speedTrackers[key] = _SpeedTracker();

      if (pendingIndices.isEmpty) {
      } else {
        for (final idx in pendingIndices) {
          if (task.isPaused || task.cancelToken.isCancelled) break;

          await semaphore.acquire();
          if (task.isPaused || task.cancelToken.isCancelled) {
            semaphore.release();
            break;
          }

          _downloadSegmentWithRetry(
            segments[idx].uri,
            path.join(episodeDir, 'seg_${idx.toString().padLeft(5, '0')}.ts'),
            httpHeaders,
            task.cancelToken,
          ).then((bytes) {
            sessionBytes += bytes;
            episode.downloadedSegments++;
            episode.totalBytes = existingBytes + sessionBytes;
            episode.progressPercent =
                episode.downloadedSegments / episode.totalSegments;
            _speedTrackers[key]?.update(sessionBytes);
            _notifyProgress(task, episode);
            completedCount++;
            semaphore.release();
            if (completedCount + failedCount == pendingIndices.length) {
              completer.complete();
            }
          }).catchError((e) {
            failedCount++;
            semaphore.release();
            if (completedCount + failedCount == pendingIndices.length) {
              completer.complete();
            }
          });
        }

        if (!task.isPaused &&
            !task.cancelToken.isCancelled &&
            pendingIndices.isNotEmpty) {
          await completer.future;
        }
      }

      if (task.isPaused || task.cancelToken.isCancelled) {
        if (task.isPaused) {
          episode.status = DownloadStatus.paused;
        }
        _notifyProgress(task, episode);
        return;
      }

      if (failedCount > 0) {
        episode.status = DownloadStatus.failed;
        episode.errorMessage = '$failedCount 个分片下载失败';
        _notifyProgress(task, episode);
        return;
      }

      final targetDuration = adBlockerEnabled
          ? M3u8AdFilter.calculateTargetDuration(segments)
          : resolvedPlaylist.targetDuration;
      final localM3u8 = M3u8Parser.buildLocalM3u8(
        segments,
        targetDuration: targetDuration,
        keyUriToLocal: keyUriToLocal,
      );
      final m3u8Path = path.join(episodeDir, 'playlist.m3u8');
      await File(m3u8Path).writeAsString(localM3u8);
      final finalVideoBytes = await calculateM3u8VideoBytes(episodeDir);

      episode.status = DownloadStatus.completed;
      episode.localM3u8Path = m3u8Path;
      episode.progressPercent = 1.0;
      episode.completedAt = DateTime.now();
      episode.totalBytes =
          finalVideoBytes > 0 ? finalVideoBytes : existingBytes + sessionBytes;
      _notifyProgress(task, episode);

      KazumiLogger().i(
        'DownloadManager: episode ${task.episodeNumber} completed. '
        '${segments.length} segments, ${(episode.totalBytes / 1024 / 1024).toStringAsFixed(1)} MB',
      );
    } on _InsufficientStorageException catch (e) {
      episode.status = DownloadStatus.failed;
      episode.errorMessage =
          '存储空间不足 (可用: ${fmt.formatBytes(e.availableBytes)})';
      _notifyProgress(task, episode);
      KazumiLogger().w('DownloadManager: insufficient storage space', error: e);
    } on FileSystemException catch (e) {
      episode.status = DownloadStatus.failed;
      episode.errorMessage = _getStorageErrorMessage(e);
      _notifyProgress(task, episode);
      KazumiLogger().e('DownloadManager: file system error', error: e);
    } on NetworkException catch (e) {
      if (e.type == NetworkExceptionType.cancel) {
        if (task.isPaused) {
          episode.status = DownloadStatus.paused;
        }
      } else {
        episode.status = DownloadStatus.failed;
        episode.errorMessage = e.message;
      }
      _notifyProgress(task, episode);
    } catch (e) {
      episode.status = DownloadStatus.failed;
      episode.errorMessage = e.toString();
      _notifyProgress(task, episode);
      KazumiLogger().e('DownloadManager: episode download failed', error: e);
    } finally {
      _onTaskComplete(task);
    }
  }

  Future<void> _runDirectFileDownload({
    required DownloadTask task,
    required int bangumiId,
    required String pluginName,
    required String videoUrl,
    required Map<String, String> httpHeaders,
    required DownloadEpisode episode,
  }) async {
    final key = _taskKey(task.recordKey, task.episodeNumber);
    try {
      final episodeDir = await _prepareEpisodeDir(
          episode, bangumiId, pluginName, task.episodeNumber);

      final filePath = path.join(episodeDir, 'video.mp4');
      final tmpPath = '$filePath.tmp';

      int existingBytes = 0;
      final tmpFile = File(tmpPath);
      if (await tmpFile.exists()) {
        existingBytes = await tmpFile.length();
      }

      episode.totalSegments = 1;
      episode.downloadedSegments = 0;
      _notifyProgress(task, episode);

      // [my新增] 直链多连接并行: 文件切 N 段 Range 并行下载 (实测 4 连接
      // ~2.1x)。sidecar (.pmeta) 记录各段进度, 暂停/失败后按段续传;
      // 服务器不支持 Range / 文件过小 / 连接数 < 2 时返回 false 走原路径。
      final connections =
          GStorage.getSetting(SettingsKeys.downloadDirectConnections);
      final metaPath = '$tmpPath.pmeta';
      final parallelDone = await _runParallelDirectDownload(
        task: task,
        episode: episode,
        videoUrl: videoUrl,
        httpHeaders: httpHeaders,
        tmpPath: tmpPath,
        metaPath: metaPath,
        connections: connections,
      );
      if (parallelDone == true) {
        await File(tmpPath).rename(filePath);
        episode.status = DownloadStatus.completed;
        episode.localM3u8Path = filePath;
        episode.downloadedSegments = 1;
        episode.progressPercent = 1.0;
        episode.completedAt = DateTime.now();
        episode.totalBytes = await File(filePath).length();
        _notifyProgress(task, episode);
        KazumiLogger().i(
          'DownloadManager: episode ${task.episodeNumber} completed (parallel direct download). '
          '${(episode.totalBytes / 1024 / 1024).toStringAsFixed(1)} MB',
        );
        return;
      }
      if (parallelDone == null) {
        // 暂停/取消: 状态已由并行路径设置
        return;
      }
      // false: 不适用并行 (无 Range 支持/文件过小/遗留 tmp 续传), 走原单连接。

      final requestHeaders = Map<String, String>.from(httpHeaders);
      bool useRange = existingBytes > 0;
      if (useRange) {
        requestHeaders['Range'] = 'bytes=$existingBytes-';
      }

      Response<ResponseBody> response;
      try {
        response = await _http.getStream(
          videoUrl,
          headers: requestHeaders,
          receiveTimeout: const Duration(minutes: 30),
          cancelToken: task.cancelToken,
        );
      } on NetworkException catch (e) {
        if (e.statusCode == 416 && useRange) {
          KazumiLogger().w(
            'DownloadManager: 416 Range Not Satisfiable, deleting tmp file and retrying',
          );
          await tmpFile.delete();
          existingBytes = 0;
          requestHeaders.remove('Range');
          response = await _http.getStream(
            videoUrl,
            headers: requestHeaders,
            receiveTimeout: const Duration(minutes: 30),
            cancelToken: task.cancelToken,
          );
        } else {
          rethrow;
        }
      }

      final contentRange = response.headers.value('content-range');
      final contentLength = int.tryParse(
              response.headers.value(Headers.contentLengthHeader) ?? '') ??
          0;
      int totalSize;
      if (contentRange != null) {
        final totalMatch = RegExp(r'/(\d+)').firstMatch(contentRange);
        totalSize = totalMatch != null ? int.parse(totalMatch.group(1)!) : 0;
      } else {
        totalSize = existingBytes + contentLength;
      }

      final raf = await tmpFile.open(
          mode: existingBytes > 0 ? FileMode.append : FileMode.write);
      int received = existingBytes;

      _speedTrackers[key] = _SpeedTracker();

      try {
        await for (final chunk in response.data!.stream) {
          if (task.isPaused || task.cancelToken.isCancelled) break;
          await raf.writeFrom(chunk);
          received += chunk.length;
          episode.totalBytes = received;
          episode.progressPercent = totalSize > 0 ? received / totalSize : 0;
          // Update speed tracker
          _speedTrackers[key]?.update(received);
          _notifyProgress(task, episode);
        }
      } finally {
        await raf.close();
      }

      if (task.isPaused || task.cancelToken.isCancelled) {
        if (task.isPaused) {
          episode.status = DownloadStatus.paused;
        }
        _notifyProgress(task, episode);
        return;
      }

      await File(tmpPath).rename(filePath);

      episode.status = DownloadStatus.completed;
      episode.localM3u8Path = filePath;
      episode.downloadedSegments = 1;
      episode.progressPercent = 1.0;
      episode.completedAt = DateTime.now();
      episode.totalBytes = await File(filePath).length();
      _notifyProgress(task, episode);

      KazumiLogger().i(
        'DownloadManager: episode ${task.episodeNumber} completed (direct download). '
        '${(episode.totalBytes / 1024 / 1024).toStringAsFixed(1)} MB',
      );
    } on _InsufficientStorageException catch (e) {
      episode.status = DownloadStatus.failed;
      episode.errorMessage =
          '存储空间不足 (可用: ${fmt.formatBytes(e.availableBytes)})';
      _notifyProgress(task, episode);
      KazumiLogger().w('DownloadManager: insufficient storage space', error: e);
    } on FileSystemException catch (e) {
      episode.status = DownloadStatus.failed;
      episode.errorMessage = _getStorageErrorMessage(e);
      _notifyProgress(task, episode);
      KazumiLogger().e('DownloadManager: file system error', error: e);
    } on NetworkException catch (e) {
      if (e.type == NetworkExceptionType.cancel) {
        if (task.isPaused) {
          episode.status = DownloadStatus.paused;
        }
      } else {
        episode.status = DownloadStatus.failed;
        episode.errorMessage = e.message;
      }
      _notifyProgress(task, episode);
    } catch (e) {
      episode.status = DownloadStatus.failed;
      episode.errorMessage = e.toString();
      _notifyProgress(task, episode);
      KazumiLogger()
          .e('DownloadManager: direct file download failed', error: e);
    }
  }

  // ====== [my新增] 直链多连接并行 ======
  // 方案: 探测总大小 → 文件按 bounds 切 N 段, 每段独立分片文件
  // (tmpPath.partN, 段文件长度即进度, 断点续传天然成立) → N 连接 Range
  // 并行 (每段带重试, 应对直连间歇性重置) → 全部完成后顺序拼接回 tmp。
  // sidecar (.pmeta) 只记 total+bounds, 用于恢复时校验分段布局。

  /// 返回: true = 完成 (tmp 已拼接好); null = 暂停/取消 (状态已设置);
  /// false = 不适用并行, 调用方走原单连接路径。异常 = 失败 (分片保留供重试)。
  Future<bool?> _runParallelDirectDownload({
    required DownloadTask task,
    required DownloadEpisode episode,
    required String videoUrl,
    required Map<String, String> httpHeaders,
    required String tmpPath,
    required String metaPath,
    required int connections,
  }) async {
    final key = _taskKey(task.recordKey, task.episodeNumber);
    final metaFile = File(metaPath);

    int totalSize = 0;
    List<int> bounds = const [];
    if (await metaFile.exists()) {
      try {
        final m = jsonDecode(await metaFile.readAsString());
        totalSize = (m['total'] as num?)?.toInt() ?? 0;
        bounds = ((m['bounds'] as List?) ?? const [])
            .map((e) => (e as num).toInt())
            .toList();
        if (totalSize <= 0 || bounds.isEmpty) {
          throw const FormatException('bad meta');
        }
      } catch (_) {
        await metaFile.delete();
        await _deletePartFiles(tmpPath, bounds.length);
        totalSize = 0;
        bounds = const [];
      }
    }
    final tmpExists = await File(tmpPath).exists();
    if (totalSize == 0) {
      if (tmpExists) return false; // 遗留单连接 tmp, 走原路径续传
      if (connections < 2) return false;

      // 探测总大小: Range 0-0 (响应体仅 1 字节)。独立 CancelToken —
      // 服务器无视 Range 返回 200 全量流时立即取消, 不吞整个文件。
      final probeToken = CancelToken();
      final probeHeaders = Map<String, String>.from(httpHeaders)
        ..['Range'] = 'bytes=0-0';
      final probe = await _http.getStream(
        videoUrl,
        headers: probeHeaders,
        receiveTimeout: const Duration(seconds: 30),
        cancelToken: probeToken,
      );
      final contentRange = probe.headers.value('content-range');
      if (contentRange == null) {
        probeToken.cancel();
        return false; // 不支持 Range, 并行无从谈起
      }
      await probe.data?.stream.drain<void>();
      final totalMatch = RegExp(r'/(\d+)').firstMatch(contentRange);
      if (totalMatch == null) return false;
      totalSize = int.parse(totalMatch.group(1)!);
      // 文件太小不值得并行 (< 8MB); 段数按每段至少 4MB 收敛
      if (totalSize < 8 * 1024 * 1024) return false;
      final n = connections.clamp(1, (totalSize / (4 * 1024 * 1024)).ceil());
      bounds = List.generate(n, (i) => (i + 1) * totalSize ~/ n);
      bounds[n - 1] = totalSize;
      await metaFile.writeAsString(jsonEncode(
          {'total': totalSize, 'bounds': bounds}));
      await _deletePartFiles(tmpPath, 64); // 清理可能的旧分片
    }
    if (connections < 2) return false;

    final starts = <int>[0, ...bounds.sublist(0, bounds.length - 1)];
    var received = 0;
    for (var i = 0; i < bounds.length; i++) {
      final f = File('$tmpPath.part$i');
      received += f.existsSync() ? await f.length() : 0;
    }
    episode.totalBytes = received;
    episode.progressPercent =
        totalSize > 0 ? received / totalSize : 0;
    _speedTrackers[key] = _SpeedTracker();
    _notifyProgress(task, episode);

    var interrupted = false;
    var partFailed = false;
    Object? firstError;
    final futures = <Future<void>>[];
    for (var i = 0; i < bounds.length; i++) {
      futures.add(_downloadDirectPart(
        task: task,
        videoUrl: videoUrl,
        httpHeaders: httpHeaders,
        partPath: '$tmpPath.part$i',
        rangeStart: starts[i],
        rangeEnd: bounds[i],
        onChunk: (len) {
          received += len;
          episode.totalBytes = received;
          episode.progressPercent = received / totalSize;
          _speedTrackers[key]?.update(received);
          _notifyProgress(task, episode);
        },
        onInterrupt: () => interrupted = true,
        shouldStop: () => interrupted || partFailed,
      ));
    }
    // 段失败置停其他段并等全部收尾, 避免标记失败后仍有写入者残留
    // (用户立即重试会双写同一分片)。
    await Future.wait(futures
        .map((f) => f.then((_) => null).catchError((e) {
              partFailed = true;
              firstError ??= e;
              return e;
            })));
    if (partFailed) {
      throw firstError!;
    }

    if (interrupted || task.isPaused || task.cancelToken.isCancelled) {
      if (task.isPaused) {
        episode.status = DownloadStatus.paused;
      }
      _notifyProgress(task, episode);
      return null;
    }

    // 全部段完成: 校验长度并拼接回 tmp
    for (var i = 0; i < bounds.length; i++) {
      final f = File('$tmpPath.part$i');
      final expect = bounds[i] - starts[i];
      if (!f.existsSync() || await f.length() != expect) {
        throw NetworkException(
          type: NetworkExceptionType.unknown,
          message: '并行分片 $i 校验失败',
        );
      }
    }
    final out = File(tmpPath);
    final raf = await out.open(mode: FileMode.write);
    try {
      for (var i = 0; i < bounds.length; i++) {
        final part = File('$tmpPath.part$i');
        final input = part.openRead();
        await for (final chunk in input) {
          await raf.writeFrom(chunk);
        }
      }
    } finally {
      await raf.close();
    }
    await _deletePartFiles(tmpPath, bounds.length);
    await metaFile.delete();
    return true;
  }

  Future<void> _deletePartFiles(String tmpPath, int count) async {
    for (var i = 0; i < count; i++) {
      final f = File('$tmpPath.part$i');
      if (f.existsSync()) await f.delete();
    }
  }

  /// 单段下载: 从分片文件当前长度处 Range 续传, 建连/流中断均重试
  /// (共 3 次; 直连路由存在间歇性重置, 单次失败不代表段不可用)。
  Future<void> _downloadDirectPart({
    required DownloadTask task,
    required String videoUrl,
    required Map<String, String> httpHeaders,
    required String partPath,
    required int rangeStart,
    required int rangeEnd,
    required void Function(int len) onChunk,
    required void Function() onInterrupt,
    required bool Function() shouldStop,
  }) async {
    const maxAttempts = 3;
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (shouldStop() || task.isPaused || task.cancelToken.isCancelled) {
        onInterrupt();
        return;
      }
      try {
        final partFile = File(partPath);
        var pos = partFile.existsSync() ? await partFile.length() : 0;
        if (rangeStart + pos >= rangeEnd) return; // 本段已完成
        final headers = Map<String, String>.from(httpHeaders)
          ..['Range'] = 'bytes=${rangeStart + pos}-${rangeEnd - 1}';
        final response = await _http.getStream(
          videoUrl,
          headers: headers,
          receiveTimeout: const Duration(minutes: 10),
          cancelToken: task.cancelToken,
        );
        final raf = await partFile
            .open(mode: pos > 0 ? FileMode.append : FileMode.write);
        try {
          await for (final chunk in response.data!.stream) {
            if (shouldStop() || task.isPaused ||
                task.cancelToken.isCancelled) {
              onInterrupt();
              return;
            }
            await raf.writeFrom(chunk);
            onChunk(chunk.length);
          }
        } finally {
          await raf.close();
        }
        return; // 本段完整
      } catch (e) {
        if (task.cancelToken.isCancelled ||
            (e is NetworkException &&
                e.type == NetworkExceptionType.cancel)) {
          onInterrupt();
          return;
        }
        lastError = e;
        if (attempt == maxAttempts) break;
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    throw lastError ?? NetworkException(
      type: NetworkExceptionType.unknown,
      message: '并行分片下载失败',
    );
  }

  void _onTaskComplete(DownloadTask task) {
    final key = _taskKey(task.recordKey, task.episodeNumber);
    // A retry may already own this key while the cancelled task is unwinding.
    if (_activeTasks[key] == null || identical(_activeTasks[key], task)) {
      _activeTasks.remove(key);
      _speedTrackers.remove(key);
    }
    _runningCount--;
    _processQueue();
  }

  void _notifyProgress(DownloadTask task, DownloadEpisode episode) {
    final key = _taskKey(task.recordKey, task.episodeNumber);
    // Cancelled or superseded tasks no longer own the episode.
    if (!identical(_activeTasks[key], task)) return;
    final speed = _speedTrackers[key]?.currentSpeed ?? 0.0;
    onProgress?.call(task.recordKey, task.episodeNumber, episode, speed);
  }

  Future<String> _fetchM3u8(
      String url, Map<String, String> headers, CancelToken cancelToken) async {
    final fetchToken = CancelToken();

    if (cancelToken.isCancelled) {
      throw NetworkException(
        type: NetworkExceptionType.cancel,
        message: '请求已被取消，请重新请求',
      );
    }

    try {
      final content = await _http.getPlain(
        url,
        headers: headers,
        receiveTimeout: const Duration(seconds: 15),
        cancelToken: fetchToken,
        onReceiveProgress: (received, total) {
          if (cancelToken.isCancelled) {
            fetchToken.cancel('task cancelled');
            return;
          }
          if (received > 2 * 1024 * 1024) {
            fetchToken.cancel('too large');
          }
        },
      );

      final trimmed = content.trimLeft();
      if (!trimmed.startsWith('#EXTM3U')) {
        throw _NotM3u8Exception('URL 不是 M3U8 播放列表');
      }

      return content;
    } on NetworkException catch (e) {
      if (cancelToken.isCancelled) rethrow;
      if (e.type == NetworkExceptionType.cancel) {
        throw _NotM3u8Exception('响应过大，非 M3U8 播放列表');
      }
      rethrow;
    }
  }

  Future<void> _downloadFile(String url, String savePath,
      Map<String, String> headers, CancelToken cancelToken) async {
    await _http.download(
      url,
      savePath,
      headers: headers,
      cancelToken: cancelToken,
    );
  }

  Future<int> _downloadSegmentWithRetry(
    String url,
    String savePath,
    Map<String, String> headers,
    CancelToken cancelToken, {
    int maxRetries = 3,
  }) async {
    final tmpPath = '$savePath.tmp';
    int retryCount = 0;
    while (true) {
      try {
        await _http.download(
          url,
          tmpPath,
          headers: headers,
          cancelToken: cancelToken,
        );
        await File(tmpPath).rename(savePath);
        return await File(savePath).length();
      } catch (e) {
        try {
          final tmpFile = File(tmpPath);
          if (await tmpFile.exists()) await tmpFile.delete();
        } catch (_) {}
        if (cancelToken.isCancelled) rethrow;
        retryCount++;
        if (retryCount >= maxRetries) rethrow;
        final delay = Duration(seconds: [1, 3, 9][retryCount - 1]);
        await Future.delayed(delay);
      }
    }
  }

  @override
  Future<void> deleteEpisodeFiles(
      int bangumiId, String pluginName, int episodeNumber,
      {DownloadEpisode? episode}) async {
    final dir = Directory(await _episodeDirForDeletion(
        episode, bangumiId, pluginName, episodeNumber));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  @override
  Future<void> deleteRecordFiles(int bangumiId, String pluginName,
      {DownloadRecord? record}) async {
    if (record == null) {
      final dir = Directory(path.join(
          await getDefaultDownloadDirectory(), '${bangumiId}_$pluginName'));
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      return;
    }

    // Episodes may live under different base directories, so delete each
    // episode directory individually.
    final parentDirs = <String>{};
    for (final entry in record.episodes.entries) {
      final episodeDir = await _episodeDirForDeletion(
          entry.value, bangumiId, pluginName, entry.key);
      final dir = Directory(episodeDir);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      parentDirs.add(path.dirname(episodeDir));
    }

    for (final parentDir in parentDirs) {
      try {
        await Directory(parentDir).delete();
      } on FileSystemException {
        // Parent is missing or still holds other files; leave it.
      }
    }
  }

  @override
  String? getLocalVideoPath(DownloadEpisode? episode) {
    if (episode == null) return null;
    if (episode.status != DownloadStatus.completed) return null;
    if (episode.localM3u8Path.isEmpty) return null;
    final file = File(episode.localM3u8Path);
    if (!file.existsSync()) return null;
    return episode.localM3u8Path;
  }
}

class _Semaphore {
  final int maxCount;
  int _currentCount = 0;
  final _waitQueue = <Completer<void>>[];

  _Semaphore(this.maxCount);

  Future<void> acquire() async {
    if (_currentCount < maxCount) {
      _currentCount++;
      return;
    }
    final completer = Completer<void>();
    _waitQueue.add(completer);
    return completer.future;
  }

  void release() {
    if (_waitQueue.isNotEmpty) {
      final completer = _waitQueue.removeAt(0);
      completer.complete();
    } else {
      _currentCount--;
    }
  }
}
