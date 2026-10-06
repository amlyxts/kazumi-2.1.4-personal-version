import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/constants.dart';

/// [本地播放] 工具集：选文件/选文件夹、扫描播放列表、合成历史记录用的虚拟番剧条目。
/// 历史卡片与本地视频库页都依赖这里的 [listLocalVideoFiles] 与 [stableLocalVideoId]。

String normalizeLocalPath(String path) => path.replaceAll('\\', '/');

String localFileBasename(String path) =>
    normalizeLocalPath(path).split('/').last;

String localFileDisplayName(String path) {
  final fileName = localFileBasename(path);
  final dotIndex = fileName.lastIndexOf('.');
  return dotIndex > 0 ? fileName.substring(0, dotIndex) : fileName;
}

/// 目录本身（单文件模式取文件全路径作为身份来源）
String localEntryDirectory(String path) {
  final normalized = normalizeLocalPath(path);
  final segments = normalized.split('/');
  return segments.sublist(0, segments.length - 1).join('/');
}

/// 由路径派生稳定 id：同一个文件夹（或单文件）永远映射到同一个历史键，
/// 避免所有本地视频共用 bangumiId=-1 导致历史互相覆盖。
int stableLocalVideoId(String path) {
  final hex = md5.convert(utf8.encode(normalizeLocalPath(path))).toString();
  return int.parse(hex.substring(0, 7), radix: 16);
}

BangumiItem buildLocalBangumiItem({
  required String idSourcePath,
  required String name,
}) {
  return BangumiItem(
    id: stableLocalVideoId(idSourcePath),
    type: 2,
    name: name,
    nameCn: name,
    summary: '',
    airDate: '',
    airWeekday: 0,
    rank: 0,
    images: const {},
    tags: [],
    alias: [],
    ratingScore: 0.0,
    votes: 0,
    votesCount: [],
    info: '',
  );
}

bool _isLocalVideoFile(File entity) {
  final ext = localFileBasename(entity.path);
  final dotIndex = ext.lastIndexOf('.');
  if (dotIndex < 0) {
    return false;
  }
  return localVideoExtensions
      .contains(ext.substring(dotIndex + 1).toLowerCase());
}

/// 扫描目录下的视频文件，文件名按自然顺序（数字按数值比较）排序
List<String> listLocalVideoFiles(String dirPath) {
  final dir = Directory(dirPath);
  if (!dir.existsSync()) {
    return [];
  }
  final files = dir
      .listSync()
      .whereType<File>()
      .where(_isLocalVideoFile)
      .map((e) => e.path)
      .toList()
    ..sort(_compareNatural);
  return files;
}

bool _isDigit(String c) =>
    c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;

int _compareNatural(String a, String b) {
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    final digitA = _isDigit(a[i]);
    final digitB = _isDigit(b[j]);
    if (digitA && digitB) {
      final startI = i;
      final startJ = j;
      while (i < a.length && _isDigit(a[i])) {
        i++;
      }
      while (j < b.length && _isDigit(b[j])) {
        j++;
      }
      final na = int.tryParse(a.substring(startI, i)) ?? 0;
      final nb = int.tryParse(b.substring(startJ, j)) ?? 0;
      final cmp = na.compareTo(nb);
      if (cmp != 0) {
        return cmp;
      }
    } else {
      final cmp = a[i].toLowerCase().compareTo(b[j].toLowerCase());
      if (cmp != 0) {
        return cmp;
      }
      i++;
      j++;
    }
  }
  return (a.length - i).compareTo(b.length - j);
}

// [my修改] 分类归属存取 (本地视频库页与本文件共用)
Map<String, String> loadLocalVideoAssign() {
  try {
    final raw = GStorage.getSetting(SettingsKeys.localVideoCategoryAssign);
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

List<String> _loadLauncherCategories() {
  try {
    final raw = GStorage.getSetting(SettingsKeys.localVideoCategories);
    return (jsonDecode(raw) as List).cast<String>();
  } catch (_) {
    return [];
  }
}

// [本地播放] 弹出添加对话框 (可选归入分类), 选完直接进入播放页。
// 若发起了播放, 返回的 Future 在播放页退出后完成 true; 取消则完成 false。
Future<bool> showLocalVideoAddDialog() async {
  final playbackClosed = Completer<bool>();
  String? selectedCategory; // null = 未分类
  KazumiDialog.show(
    clickMaskDismiss: false,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        final chips = <Widget>[
          ChoiceChip(
            label: const Text('未分类'),
            selected: selectedCategory == null,
            onSelected: (_) => setDialogState(() => selectedCategory = null),
          ),
          for (final category in _loadLauncherCategories())
            ChoiceChip(
              label: Text(category),
              selected: selectedCategory == category,
              onSelected: (_) => setDialogState(() => selectedCategory = category),
            ),
          ChoiceChip(
            label: const Text('+ 新建'),
            selected: false,
            onSelected: (_) async {
              final name = await _newCategoryDialogInLauncher();
              if (name != null && name.isNotEmpty) {
                final cats = _loadLauncherCategories();
                if (!cats.contains(name)) {
                  cats.add(name);
                  await GStorage.putSetting(
                      SettingsKeys.localVideoCategories, jsonEncode(cats));
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
              Text('归入分类:',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
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
                Navigator.of(context).pop();
                _pickAndPlaySingleFile(playbackClosed, category);
              },
              child: const Text('选择视频文件'),
            ),
            TextButton(
              onPressed: () {
                final category = selectedCategory;
                Navigator.of(context).pop();
                _pickAndPlayFolder(playbackClosed, category);
              },
              child: const Text('选择文件夹（连播）'),
            ),
            TextButton(
              onPressed: () {
                playbackClosed.complete(false);
                Navigator.of(context).pop();
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
    Completer<bool> playbackClosed, String? category) async {
  try {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: '视频文件', extensions: localVideoExtensions),
      ],
      initialDirectory: _initialDirectory(),
    );
    if (file == null) {
      playbackClosed.complete(false);
      return;
    }
    await _launchLocalPlayback([file.path], category, playbackClosed);
  } catch (e) {
    playbackClosed.complete(false);
    KazumiDialog.showToast(message: '选择文件失败：$e');
  }
}

Future<void> _pickAndPlayFolder(
    Completer<bool> playbackClosed, String? category) async {
  try {
    final dirPath = await getDirectoryPath(
      initialDirectory: _initialDirectory(),
    );
    if (dirPath == null || dirPath.isEmpty) {
      playbackClosed.complete(false);
      return;
    }
    await GStorage.putSetting(
        SettingsKeys.localVideoLastDirectory, dirPath);
    final files = listLocalVideoFiles(dirPath);
    if (files.isEmpty) {
      playbackClosed.complete(false);
      KazumiDialog.showToast(message: '该文件夹下没有找到视频文件');
      return;
    }
    await _launchLocalPlayback(files, category, playbackClosed);
  } catch (e) {
    playbackClosed.complete(false);
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

Future<String?> _newCategoryDialogInLauncher() async {
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
Future<void> _launchLocalPlayback(
    List<String> files, String? category, Completer<bool> playbackClosed) async {
  // 文件夹连播用文件夹路径做身份（整个文件夹一条历史）；单文件用文件本身
  final idSourcePath = files.length > 1
      ? localEntryDirectory(files.first)
      : files.first;
  final name = files.length > 1
      ? localFileBasename(idSourcePath)
      : localFileDisplayName(files.first);
  if (name.isEmpty) {
    playbackClosed.complete(false);
    KazumiDialog.showToast(message: '无法解析文件名');
    return;
  }

  final folderId = stableLocalVideoId(idSourcePath).toString();
  if (category != null && category.isNotEmpty) {
    final assign = loadLocalVideoAssign();
    assign[folderId] = category;
    await saveLocalVideoAssign(assign);
  }

  final videoPageController = Modular.get<VideoPageController>();
  videoPageController.initForLocalFilePlayback(
    bangumiItem: buildLocalBangumiItem(idSourcePath: idSourcePath, name: name),
    filePaths: files,
  );
  // [my修改] 先进播放页, 播放页退出后再完成信号:
  // 调用方的列表刷新此时才能读到新建的历史记录 (播放开始时才写入)
  await Modular.to.pushNamed('/video/');
  playbackClosed.complete(true);
}
