import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/utils/constants.dart';

/// [my修改] 本地视频纯工具函数（无 UI 依赖）：
/// 路径处理、身份派生、目录扫描。启动器与历史恢复服务共用。

String normalizeLocalPath(String path) => path.replaceAll('\\', '/');

String localFileBasename(String path) =>
    normalizeLocalPath(path).split('/').last;

String localFileDisplayName(String path) {
  final fileName = localFileBasename(path);
  final dotIndex = fileName.lastIndexOf('.');
  return dotIndex > 0 ? fileName.substring(0, dotIndex) : fileName;
}

/// 所在目录（单文件模式取文件全路径作为身份来源）
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
  final name = localFileBasename(entity.path);
  final dotIndex = name.lastIndexOf('.');
  if (dotIndex < 0) {
    return false;
  }
  return localVideoExtensions
      .contains(name.substring(dotIndex + 1).toLowerCase());
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
