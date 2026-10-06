import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import 'package:kazumi/pages/video/local_video_launcher.dart';
import 'package:kazumi/services/logging/logger.dart';

/// [my修改] 本地视频封面：用静音的临时 media_kit 播放器截取视频画面帧,
/// 缓存到 local_covers 目录, 源文件未变化时直接复用。
/// 生成失败 (打不开/超时) 返回 null, 由界面回落到占位图标。
class LocalVideoCoverService {
  LocalVideoCoverService._();

  static Directory? _coverDir;

  /// 同一视频路径的进行中任务 (历史页多卡片并发 + 库页同时触发时去重,
  /// 避免为同一文件开两个临时播放器)
  static final Map<String, Future<String?>> _inFlight = {};

  /// 截帧串行链: 多个未命中缓存的请求逐个执行, 避免并发开多个 mpv 实例
  static Future<void> _captureChain = Future.value();

  static Future<Directory> _coversDirectory() async {
    if (_coverDir != null) return _coverDir!;
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/local_covers');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    _coverDir = dir;
    return dir;
  }

  static String _cacheKey(String videoPath) =>
      md5.convert(utf8.encode(normalizeLocalPath(videoPath))).toString();

  /// 视频文件的封面路径 (无则生成); 失败返回 null
  /// 缓存命中直接返回; 未命中时同路径并发调用共享同一任务, 截帧全局串行
  static Future<String?> coverForVideo(String videoPath) async {
    final cacheKey = _cacheKey(videoPath);
    try {
      final dir = await _coversDirectory();
      final cacheFile = File('${dir.path}/$cacheKey.png');

      if (cacheFile.existsSync()) {
        final videoStat = File(videoPath).statSync();
        final cacheStat = cacheFile.statSync();
        if (cacheStat.modified.isAfter(videoStat.modified)) {
          return cacheFile.path;
        }
      }

      final existing = _inFlight[cacheKey];
      if (existing != null) {
        return existing;
      }

      final task = _captureChain.then(
        (_) => _generateAndCache(videoPath, cacheFile),
      );
      _inFlight[cacheKey] = task;
      _captureChain = task.then((_) {}, onError: (_) {});
      task.whenComplete(() => _inFlight.remove(cacheKey));
      return task;
    } catch (e) {
      KazumiLogger().w('LocalCover: 生成异常', error: e, forceLog: true);
      return null;
    }
  }

  /// 截帧并写缓存 (已在串行链上执行)
  static Future<String?> _generateAndCache(
      String videoPath, File cacheFile) async {
    final pngBytes = await _captureFrame(videoPath);
    if (pngBytes == null) return null;

    await cacheFile.writeAsBytes(pngBytes, flush: true);
    KazumiLogger().i('LocalCover: 封面已生成 ($videoPath)', forceLog: true);
    return cacheFile.path;
  }

  /// 文件夹封面: 用文件夹内第一个视频生成; 无视频返回 null
  static Future<String?> coverForFolder(String folderPath) async {
    final files = listLocalVideoFiles(folderPath);
    if (files.isEmpty) return null;
    return coverForVideo(files.first);
  }

  /// 打开静音临时播放器, seek 到片长约 20% 处截取画面 (PNG)。
  /// 音频输出置 null, 不与主播放器抢占音频设备。
  static Future<Uint8List?> _captureFrame(String videoPath) async {
    final player = Player(
      configuration: PlayerConfiguration(
        bufferSize: 8 * 1024 * 1024,
        logLevel: MPVLogLevel.error,
      ),
    );
    try {
      // 保持渲染上下文存活 (封面截帧依赖它出帧)
      // ignore: unused_local_variable
      final controller = VideoController(
        player,
        configuration: VideoControllerConfiguration(
          enableHardwareAcceleration: true,
        ),
      );
      final native = player.platform as NativePlayer;
      await native.setProperty('ao', 'null');
      await player.open(Media(videoPath));
      await player.setVolume(0.0);

      // 等待视频参数与首帧 (最长 10s)
      final sw = Stopwatch()..start();
      while (sw.elapsed < const Duration(seconds: 10)) {
        if (player.state.width != null &&
            player.state.position > Duration.zero &&
            !player.state.buffering) {
          break;
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }

      // seek 到片长约 20% 处 (跳过片头黑屏), 等待出帧
      final duration = player.state.duration;
      if (duration > const Duration(seconds: 8)) {
        var target = duration * 0.2;
        if (target > const Duration(minutes: 4)) {
          target = const Duration(minutes: 4);
        }
        if (target < const Duration(seconds: 4)) {
          target = const Duration(seconds: 4);
        }
        await player.seek(target);
        await Future.delayed(const Duration(milliseconds: 1200));
      }

      final bytes = await player.screenshot(format: 'image/png');
      await player.dispose();
      return bytes;
    } catch (e) {
      KazumiLogger().w('LocalCover: 截帧失败', error: e, forceLog: true);
      try {
        await player.dispose();
      } catch (_) {}
      return null;
    }
  }
}
