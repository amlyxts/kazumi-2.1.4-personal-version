// [qa修改] R1 外挂字幕验证驱动 (--qa-local)
// 用法: kazumi.exe --qa-local <视频路径> [--qa-local-seconds n]
// 两阶段实证: ①默认配置打开 → 读字幕轨道/文本事件 ②设置 sub-auto=fuzzy 后
// 重开 → 再读。回答 R1 的"同名外挂字幕能否自动加载"。JSON 打到 stdout。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:media_kit/media_kit.dart';

const int qaLocalExitOk = 0;
const int qaLocalExitFailed = 1;

Future<void> runQaLocalDriver(List<String> args) async {
  final videoIdx = args.indexOf('--qa-local');
  if (videoIdx < 0 || videoIdx + 1 >= args.length) {
    stdout.writeln('QA_LOCAL_JSON: {"ok":false,"error":"missing video path"}');
    exit(qaLocalExitFailed);
  }
  final videoPath = args[videoIdx + 1];
  final secIdx = args.indexOf('--qa-local-seconds');
  final watchSeconds =
      secIdx >= 0 && secIdx + 1 < args.length ? int.tryParse(args[secIdx + 1]) ?? 8 : 8;

  MediaKit.ensureInitialized();
  final player = Player();

  Future<Map<String, dynamic>> probe(String tag) async {
    final subEvents = <String>[];
    final sub = player.stream.subtitle.listen((lines) {
      for (final l in lines) {
        if (l.trim().isNotEmpty && subEvents.length < 20) subEvents.add(l);
      }
    });
    final completer = Completer<void>();
    Timer(const Duration(seconds: 2), () {
      if (!completer.isCompleted) completer.complete();
    });
    await player.open(Media(videoPath));
    await completer.future;
    // 在字幕时间窗内继续采样
    await Future.delayed(Duration(seconds: watchSeconds));
    final tracks = player.state.tracks;
    final result = {
      'phase': tag,
      'subtitleTracks': tracks.subtitle
          .map((t) => {'id': t.id, 'title': t.title, 'lang': t.language})
          .toList(),
      'videoTracks': tracks.video.length,
      'audioTracks': tracks.audio.length,
      'subtitleEvents': subEvents,
      'playing': player.state.playing,
      'position': player.state.position.inMilliseconds,
    };
    await sub.cancel();
    return result;
  }

  Map<String, dynamic> phase1;
  Map<String, dynamic> phase2;
  try {
    phase1 = await probe('default');
    // 第二阶段: sub-auto=fuzzy (按文件名模糊匹配外挂字幕)
    try {
      final native = player.platform as dynamic;
      await native.setProperty('sub-auto', 'fuzzy');
    } catch (e) {
      stdout.writeln('QA_LOCAL_WARN: setProperty failed: $e');
    }
    phase2 = await probe('sub-auto-fuzzy');
    final out = {
      'ok': true,
      'video': videoPath,
      'phases': [phase1, phase2],
    };
    stdout.writeln('QA_LOCAL_JSON: ${jsonEncode(out)}');
    await player.dispose();
    exit(qaLocalExitOk);
  } catch (e) {
    stdout.writeln('QA_LOCAL_JSON: {"ok":false,"error":"${e.toString().replaceAll('"', "'")}"}');
    try {
      await player.dispose();
    } catch (_) {}
    exit(qaLocalExitFailed);
  }
}
