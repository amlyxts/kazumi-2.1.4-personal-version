import 'dart:io';

import 'package:flutter/services.dart' show rootBundle, AssetManifest;
import 'package:kazumi/services/logging/logger.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class ShaderAssetService {
  late Directory shadersDirectory;

  Future<void> copyShadersToExternalDirectory() async {
    final assetManifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final assets = assetManifest.listAssets();
    final directory = await getApplicationSupportDirectory();
    shadersDirectory = Directory(path.join(directory.path, 'anime_shaders'));

    if (!await shadersDirectory.exists()) {
      await shadersDirectory.create(recursive: true);
      KazumiLogger()
          .i('ShaderManager: Create GLSL Shader: ${shadersDirectory.path}');
    }

    final shaderFiles = assets.where((String asset) =>
        asset.startsWith('assets/shaders/') && asset.endsWith('.glsl'));

    int copiedFilesCount = 0;

    for (var filePath in shaderFiles) {
      final fileName = filePath.split('/').last;
      final targetFile = File(path.join(shadersDirectory.path, fileName));
      try {
        // [my修复] 旧实现对已存在文件一律跳过 → assets 里的着色器更新
        // 永远到不了用户机器 (实测 ArtCNN/FSRCNNX 字节数不一致的旧版本
        // 长期驻留)。改为长度比对: 不一致即覆盖换新。
        final data = await rootBundle.load(filePath);
        final List<int> bytes = data.buffer.asUint8List();
        if (await targetFile.exists()) {
          if (await targetFile.length() == bytes.length) {
            KazumiLogger().i(
                'ShaderManager: GLSL Shader exists, skip: ${targetFile.path}');
            continue;
          }
          KazumiLogger()
              .w('ShaderManager: GLSL Shader 更新覆盖: ${targetFile.path}');
        }
        await targetFile.writeAsBytes(bytes, flush: true);
        copiedFilesCount++;
        KazumiLogger().i('ShaderManager: Copy: ${targetFile.path}');
      } catch (e) {
        KazumiLogger().e('ShaderManager: Copy: ($filePath)', error: e);
      }
    }

    KazumiLogger().i(
        'ShaderManager: $copiedFilesCount GLSL files copied to ${shadersDirectory.path}');
  }
}
