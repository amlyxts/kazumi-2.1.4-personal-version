import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/utils/local_video_utils.dart';

/// [my修改] 本地视频播放入口：选文件/选文件夹，组装 [LocalVideoPlaybackArgs]
/// 后交给 '/video/' 路由（modular 7 参数对象模式）。

/// 我的页入口：弹出选择方式，选完直接进入播放页
Future<void> pickAndPlayLocalVideo(BuildContext context) async {
  KazumiDialog.show(
    builder: (dialogContext) => AlertDialog(
      title: const Text('播放本地视频'),
      content: const Text('选择一个视频文件直接播放，或选择文件夹把里面的视频当作剧集连播。'),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(dialogContext).pop();
            _pickAndPlaySingleFile(context, null, null);
          },
          child: const Text('选择视频文件'),
        ),
        TextButton(
          onPressed: () {
            Navigator.of(dialogContext).pop();
            _pickAndPlayFolder(context, null, null);
          },
          child: const Text('选择文件夹（连播）'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
      ],
    ),
  );
}

/// 本地视频库页入口：弹出添加对话框 (可选归入分类), 选完直接进入播放页。
/// 若发起了播放, 返回的 Future 在播放页退出后完成 true; 取消则完成 false。
Future<bool> showLocalVideoAddDialog(BuildContext context) async {
  final playbackClosed = Completer<bool>();
  String? selectedCategory; // null = 未分类
  KazumiDialog.show(
    clickMaskDismiss: false,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) {
        final chips = <Widget>[
          ChoiceChip(
            label: const Text('未分类'),
            selected: selectedCategory == null,
            onSelected: (_) => setDialogState(() => selectedCategory = null),
          ),
          for (final category in loadLocalVideoCategories())
            ChoiceChip(
              label: Text(category),
              selected: selectedCategory == category,
              onSelected: (_) =>
                  setDialogState(() => selectedCategory = category),
            ),
          ChoiceChip(
            label: const Text('+ 新建'),
            selected: false,
            onSelected: (_) async {
              final name = await _newCategoryDialog(dialogContext);
              if (name != null && name.isNotEmpty) {
                final cats = loadLocalVideoCategories();
                if (!cats.contains(name)) {
                  cats.add(name);
                  await GStorage.putSetting(
                    SettingsKeys.localVideoCategories,
                    cats,
                  );
                }
                setDialogState(() => selectedCategory = name);
              }
            },
          ),
        ];
        return AlertDialog(
          title: const Text('添加本地视频'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '归入分类:',
                style: Theme.of(dialogContext).textTheme.labelMedium?.copyWith(
                    color:
                        Theme.of(dialogContext).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 4, children: chips),
              const SizedBox(height: 12),
              const Text('选择一个视频文件直接播放, 或选择文件夹把里面的视频当作剧集连播。'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                final category = selectedCategory;
                Navigator.of(dialogContext).pop();
                _pickAndPlaySingleFile(context, playbackClosed, category);
              },
              child: const Text('选择视频文件'),
            ),
            TextButton(
              onPressed: () {
                final category = selectedCategory;
                Navigator.of(dialogContext).pop();
                _pickAndPlayFolder(context, playbackClosed, category);
              },
              child: const Text('选择文件夹（连播）'),
            ),
            TextButton(
              onPressed: () {
                playbackClosed.complete(false);
                Navigator.of(dialogContext).pop();
              },
              child: const Text('取消'),
            ),
          ],
        );
      },
    ),
  );
  return playbackClosed.future;
}

Future<void> _pickAndPlaySingleFile(
  BuildContext context,
  Completer<bool>? playbackClosed,
  String? category,
) async {
  try {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: localVideoExtensions,
      initialDirectory: _initialDirectory(),
    );
    final path = result?.files.single.path;
    if (path == null || path.isEmpty) {
      playbackClosed?.complete(false);
      return;
    }
    await _launchLocalPlayback(context, [path], category, playbackClosed);
  } catch (e) {
    playbackClosed?.complete(false);
    KazumiDialog.showToast(message: '选择文件失败：$e');
  }
}

Future<void> _pickAndPlayFolder(
  BuildContext context,
  Completer<bool>? playbackClosed,
  String? category,
) async {
  try {
    final dirPath = await FilePicker.platform
        .getDirectoryPath(initialDirectory: _initialDirectory());
    if (dirPath == null || dirPath.isEmpty) {
      playbackClosed?.complete(false);
      return;
    }
    await GStorage.putSetting(SettingsKeys.localVideoLastDirectory, dirPath);
    final files = listLocalVideoFiles(dirPath);
    if (files.isEmpty) {
      playbackClosed?.complete(false);
      KazumiDialog.showToast(message: '该文件夹下没有找到视频文件');
      return;
    }
    await _launchLocalPlayback(context, files, category, playbackClosed);
  } catch (e) {
    playbackClosed?.complete(false);
    KazumiDialog.showToast(message: '选择文件夹失败：$e');
  }
}

String? _initialDirectory() {
  final lastDir = GStorage.getSetting(SettingsKeys.localVideoLastDirectory);
  if (lastDir.isEmpty || !Directory(lastDir).existsSync()) {
    return null;
  }
  return lastDir;
}

Future<String?> _newCategoryDialog(BuildContext dialogContext) async {
  final controller = TextEditingController();
  return KazumiDialog.show<String>(
    builder: (context) => AlertDialog(
      title: const Text('新建分类'),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 20,
        decoration: const InputDecoration(hintText: '分类名称'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () {
            final name = controller.text.trim();
            if (name.isEmpty) return;
            Navigator.of(context).pop(name);
          },
          child: const Text('确定'),
        ),
      ],
    ),
  );
}

/// 组装并进入播放; 归入指定分类 (写归属映射, 供标签筛选)。
Future<void> _launchLocalPlayback(BuildContext context, List<String> files,
    String? category, Completer<bool>? playbackClosed) async {
  // 文件夹连播用文件夹路径做身份（整个文件夹一条历史）；单文件用文件本身
  final idSourcePath =
      files.length > 1 ? localEntryDirectory(files.first) : files.first;
  final name = files.length > 1
      ? localFileBasename(idSourcePath)
      : localFileDisplayName(files.first);
  if (name.isEmpty) {
    playbackClosed?.complete(false);
    KazumiDialog.showToast(message: '无法解析文件名');
    return;
  }

  final folderId = stableLocalVideoId(idSourcePath).toString();
  if (category != null && category.isNotEmpty) {
    final assign = loadLocalVideoAssign();
    assign[folderId] = category;
    await saveLocalVideoAssign(assign);
  }

  if (!context.mounted) {
    playbackClosed?.complete(true);
    return;
  }
  // [my修改] modular 7 参数对象模式：播放上下文经路由交给 VideoPage 自建控制器
  unawaited(context.pushNamed(
    '/video/',
    arguments: LocalVideoPlaybackArgs(
      bangumiItem:
          buildLocalBangumiItem(idSourcePath: idSourcePath, name: name),
      filePaths: files,
    ),
  ));
  playbackClosed?.complete(true);
}

// ===== 分类存取 (本地视频库页与本文件共用) =====

Map<String, String> loadLocalVideoAssign() {
  try {
    final raw =
        GStorage.getSetting<String>(SettingsKeys.localVideoCategoryAssign);
    final map = jsonDecode(raw) as Map;
    return map.map((k, v) => MapEntry(k as String, v as String));
  } catch (_) {
    return {};
  }
}

Future<void> saveLocalVideoAssign(Map<String, String> assign) async {
  await GStorage.putSetting(
      SettingsKeys.localVideoCategoryAssign, jsonEncode(assign));
}

List<String> loadLocalVideoCategories() {
  try {
    final raw = GStorage.getSetting<String>(SettingsKeys.localVideoCategories);
    return (jsonDecode(raw) as List).cast<String>();
  } catch (_) {
    return [];
  }
}
