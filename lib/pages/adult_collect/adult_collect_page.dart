import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';

// [my新增] 里番收藏页: 收藏库 section=1 分区的独立视图。
// 数据与追番同库 (WebDAV 同步随库走), 但永不上传 Bangumi; 条目来源为
// 源直连浏览页收藏 (自动入区) 或从追番页导入 (下方按钮)。
class AdultCollectPage extends StatefulWidget {
  const AdultCollectPage({super.key});

  @override
  State<AdultCollectPage> createState() => _AdultCollectPageState();
}

class _AdultCollectPageState extends State<AdultCollectPage> {
  final CollectController _collectController = inject<CollectController>();

  @override
  void initState() {
    super.initState();
    _collectController.loadCollectibles();
  }

  List<CollectedBangumi> get _items => _collectController.collectibles
      .where((c) => c.section == 1)
      .toList()
    ..sort((a, b) => b.time.compareTo(a.time));

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        title: const Text('里番收藏'),
        actions: [
          IconButton(
            tooltip: '从追番导入',
            icon: const Icon(Icons.move_down_rounded),
            onPressed: _showImportPicker,
          ),
        ],
      ),
      body: items.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.folder_special_outlined,
                      size: 48,
                      color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 12),
                  const Text('还没有里番区收藏', style: TextStyle(fontSize: 14)),
                  const SizedBox(height: 4),
                  Text(
                    '在源直连浏览页收藏会自动入区; 也可用右上按钮从追番导入',
                    style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.outline),
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: items.length,
              itemBuilder: (context, index) {
                final entry = items[index];
                final item = entry.bangumiItem;
                final type = CollectType.fromValue(entry.type);
                return ListTile(
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: SizedBox(
                      width: 64,
                      height: 40,
                      child: (item.images['large'] ?? '').isNotEmpty
                          ? CachedNetworkImage(
                              imageUrl: item.images['large'] ?? '',
                              fit: BoxFit.cover,
                              errorWidget: (_, __, ___) => Container(
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerHighest,
                              ),
                            )
                          : Container(
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest,
                            ),
                    ),
                  ),
                  title: Text(
                    item.nameCn.isNotEmpty ? item.nameCn : item.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14),
                  ),
                  subtitle: Text(
                    '${type.label} · ${entry.time.month}/${entry.time.day}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) async {
                      if (v == 'move') {
                        await _collectController.setCollectSection(
                            item.id, 0);
                        KazumiDialog.showToast(message: '已移回追番 (表番区)');
                      } else if (v == 'delete') {
                        await _collectController
                            .deleteCollectLocalOnly(item);
                        KazumiDialog.showToast(message: '已取消收藏');
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                          value: 'move', child: Text('移回追番 (表番区)')),
                      PopupMenuItem(value: 'delete', child: Text('取消收藏')),
                    ],
                  ),
                );
              },
            ),
    );
  }

  /// 从追番 (表番区) 批量导入: 把旧收藏或误入的条目迁入里番区
  Future<void> _showImportPicker() async {
    final candidates = _collectController.collectibles
        .where((c) => c.section != 1)
        .toList()
      ..sort((a, b) => b.time.compareTo(a.time));
    if (candidates.isEmpty) {
      KazumiDialog.showToast(message: '表番区没有可导入的收藏');
      return;
    }
    final selected = <int>{};
    await KazumiDialog.show(
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('从追番导入到里番区', style: TextStyle(fontSize: 16)),
          content: SizedBox(
            width: 420,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final c in candidates)
                  CheckboxListTile(
                    dense: true,
                    value: selected.contains(c.bangumiItem.id),
                    title: Text(
                      c.bangumiItem.nameCn.isNotEmpty
                          ? c.bangumiItem.nameCn
                          : c.bangumiItem.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                    onChanged: (v) => setDialogState(() =>
                        v == true
                            ? selected.add(c.bangumiItem.id)
                            : selected.remove(c.bangumiItem.id)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: KazumiDialog.dismiss,
              child: Text('取消',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.outline)),
            ),
            TextButton(
              onPressed: () async {
                for (final id in selected) {
                  await _collectController.setCollectSection(id, 1);
                }
                KazumiDialog.dismiss();
                KazumiDialog.showToast(message: '已导入 ${selected.length} 条');
              },
              child: Text('导入 (${selected.length})'),
            ),
          ],
        ),
      ),
    );
  }
}
