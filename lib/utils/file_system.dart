import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

Future<String> getDefaultDownloadDirectory() async {
  // [my修改] iOS 默认下载放 Documents/Downloads: 配合 UIFileSharingEnabled
  // 在"文件"App 可见可导出 (Application Support 对文件 App 不可见);
  // 其余平台维持原 Application Support 位置, 已下载记录的绝对路径不受影响。
  if (Platform.isIOS) {
    final docs = await getApplicationDocumentsDirectory();
    return path.join(docs.path, 'Downloads');
  }
  final appSupport = await getApplicationSupportDirectory();
  return path.join(appSupport.path, 'downloads');
}

Future<void> ensureDirectoryWritable(String directoryPath) async {
  final directory = Directory(directoryPath);
  await directory.create(recursive: true);

  final probe = File(path.join(
    directoryPath,
    '.kazumi_write_test_${DateTime.now().microsecondsSinceEpoch}.tmp',
  ));

  try {
    await probe.writeAsString('ok', flush: true);
  } finally {
    try {
      if (await probe.exists()) {
        await probe.delete();
      }
    } on FileSystemException {
      // The write check already succeeded; a leftover probe is not fatal.
    }
  }
}
