// [my新增] 直连收藏导出服务: 把里番区收藏 (section=1) 导出成 JSON 文件
// 存本地, 用于手动备份或分享到其他设备。
// 复用守卫 Build 判决 (见 收藏导出方案_本地.md): schema 为项目特有逻辑;
// 原子能力 (jsonEncode/FilePicker/GStorage) 全 Built-in 或已有依赖。
// 隐私纪律: R18 标题/封面只落本地文件, 日志与对话只输出条目数。
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/device.dart';

class CollectExportResult {
  const CollectExportResult({required this.count, required this.path});
  final int count;
  final String path;
}

class CollectExportService {
  CollectExportService._();

  /// 导出里番区 (section==1) 收藏 + 手动认领映射 (随备份走完整; 功能虽已
  /// 下线, 盘上残留数据仍随导出保留以便将来恢复)。
  /// 返回 null = 用户取消; count==0 时调用方应先提示避免弹空文件框。
  static Future<CollectExportResult?> exportDirectCollectibles(
      List<CollectedBangumi> allCollectibles) async {
    final entries =
        allCollectibles.where((c) => c.section == 1).toList(growable: false);
    if (entries.isEmpty) return const CollectExportResult(count: 0, path: '');

    final claimsRaw =
        GStorage.getSetting(SettingsKeys.directSearchClaims).trim();
    final claims = claimsRaw.isEmpty
        ? const <String, dynamic>{}
        : (jsonDecodeOrNull(claimsRaw) as Map<String, dynamic>? ??
            const <String, dynamic>{});

    final payload = <String, dynamic>{
      'app': 'kazumi',
      'kind': 'direct-collect-export',
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'count': entries.length,
      'entries': [for (final e in entries) _entryToJson(e)],
      'claims': claims,
    };
    final json = const JsonEncoder.withIndent('  ').convert(payload);

    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '导出直连收藏',
      fileName: 'kazumi-direct-collect-$stamp.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
      bytes: utf8.encode(json),
    );
    if (path == null || path.isEmpty) return null; // 用户取消
    try {
      // 桌面端 saveFile 仅返回路径 (bytes 参数只在移动端 SAF 生效), 需自写
      if (isDesktop()) {
        await File(path).writeAsString(json, flush: true);
      }
    } catch (e) {
      KazumiLogger().w('CollectExport: write file failed', error: e);
      rethrow;
    }
    KazumiLogger().i('CollectExport: exported ${entries.length} entries');
    return CollectExportResult(count: entries.length, path: path);
  }

  /// 条目 → 导出 map (v1 schema): href 来自 BangumiItem.info (导入侧凭此
  /// 重算 id / 重挂 claims); 省略 summary/votes/tags/alias (fabricated 为空,
  /// 导入按默认值重建)。id 原样导出 (存量可能为真实 bgm id, 导入策略见
  /// 方案文档 §3.2 round-trip 注意点)。
  static Map<String, dynamic> _entryToJson(CollectedBangumi e) {
    final item = e.bangumiItem;
    return {
      'id': item.id,
      'name': item.name,
      'nameCn': item.nameCn,
      'type': e.type,
      'section': e.section,
      'time': e.time.toUtc().toIso8601String(),
      'cover': item.images['large'] ?? item.images['common'] ?? '',
      'href': item.info,
      'ratingScore': item.ratingScore,
      'airDate': item.airDate,
    };
  }

  static dynamic jsonDecodeOrNull(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }
}
