import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/modules/collect/collect_layout.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/collect/collect_library_view.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';

// [my重写] 里番收藏页 — 与追番页同构 (复用 CollectLibraryView 全套:
// 分类 Tab/搜索/排序/双布局/卡片交互), 数据源只喂 section==1。
// 布局记忆独立 (adultCollectLayout); 卡片点击: 有 bgm 匹配开条目页,
// 未匹配直接播放; 长按菜单含"移回追番"。
class AdultCollectPage extends StatefulWidget {
  const AdultCollectPage({super.key});

  @override
  State<AdultCollectPage> createState() => _AdultCollectPageState();
}

class _AdultCollectPageState extends State<AdultCollectPage> {
  final CollectController _collectController = inject<CollectController>();
  late CollectLayout _layout;

  @override
  void initState() {
    super.initState();
    _collectController.loadCollectibles();
    _layout = CollectLayout.fromValue(
        GStorage.getSetting(SettingsKeys.adultCollectLayout));
  }

  void _changeLayout(CollectLayout layout) {
    setState(() => _layout = layout);
    // [my修复] putSetting 是异步 Future — 未 await 时页面销毁可能中断
    // 落盘; 补 await + 日志 (布局记忆丢失排查)
    () async {
      await GStorage.putSetting(SettingsKeys.adultCollectLayout, layout.name);
      KazumiLogger().i(
          'AdultCollect: layout saved = ${layout.name}');
    }();
  }

  /// 卡片点击: 匹配 bgm (真实条目 id, 与追番条目 id 空间一致) 开条目页,
  /// 未匹配直接查本条目集数并弹出播放选择 (里番的"打开"就是看)。
  void _open(CollectedBangumi entry) {
    final item = entry.bangumiItem;
    final isRealBgmEntry = _collectController.collectibles
        .any((c) => c.bangumiItem.id == item.id && c.section != 1);
    if (isRealBgmEntry) {
      if (context.mounted) context.pushNamed('/info/', arguments: item);
      return;
    }
    KazumiDialog.showToast(message: '未匹配 Bangumi 条目, 请从源直连浏览页播放');
  }

  @override
  Widget build(BuildContext context) {
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
      body: SafeArea(
        top: false,
        bottom: false,
        child: CollectLibraryView(
          // 只喂里番区条目 (section 过滤在页面层, 与追番页对称)
          entries: _collectController.collectibles
              .where((c) => c.section == 1)
              .toList(),
          showRating: GStorage.getSetting(SettingsKeys.showRating),
          layout: _layout,
          onLayoutChanged: _changeLayout,
          canEdit: (_) => true,
          onOpen: (item) {
            final entry = _collectController.collectibles.firstWhere(
              (c) => c.bangumiItem.id == item.id,
              orElse: () => CollectedBangumi(item, DateTime.now(), 0),
            );
            _open(entry);
          },
          onChangeType: (item, type) => unawaited(_changeType(item, type)),
          isAdultSection: true,
          onMoveToMain: (item) async {
            await _collectController.setCollectSection(item.id, 0);
            if (mounted) KazumiDialog.showToast(message: '已移回追番 (表番区)');
          },
        ),
      ),
    );
  }

  Future<void> _changeType(BangumiItem item, CollectType type) async {
    if (type == CollectType.none) {
      await _collectController.deleteCollectLocalOnly(item);
      return;
    }
    try {
      // 里番区改类型: 纯本地 (section 保持 1, 不触发 Bangumi 同步)
      await _collectController.addCollectLocalOnly(item,
          type: type.value, section: 1);
    } catch (_) {
      KazumiDialog.showToast(message: '修改收藏状态失败，请稍后重试');
    }
  }

  /// 从追番 (表番区) 批量导入
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
                    onChanged: (v) => setDialogState(() => v == true
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
