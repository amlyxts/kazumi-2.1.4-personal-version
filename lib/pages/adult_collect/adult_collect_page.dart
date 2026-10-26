import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/modules/collect/collect_layout.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/pages/collect/collect_library_view.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/device.dart';

// [my重写] 里番收藏页 — 与追番页同构 (复用 CollectLibraryView 全套:
// 分类 Tab/搜索/排序/双布局/卡片交互), 数据源只喂 section==1。
// 布局记忆独立 (adultCollectLayout); 卡片点击: 有 bgm 匹配开条目页,
// 未匹配直接播放; 长按菜单含"移回追番"。
class AdultCollectPage extends StatefulWidget {
  const AdultCollectPage({super.key});

  @override
  State<AdultCollectPage> createState() => _AdultCollectPageState();
}

class _AdultCollectPageState extends State<AdultCollectPage>
    with KazumiDialogOwner {
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

  /// 卡片点击: 匹配 bgm 开条目页 (同追番); 未匹配凭收藏内嵌的播放地址
  /// (BangumiItem.info = 播放页 URL, 收藏时随库落 WebDAV) 直接恢复播放 —
  /// 跨设备收藏也能从收藏页一键播。
  Future<void> _open(CollectedBangumi entry) async {
    final item = entry.bangumiItem;
    final isRealBgmEntry = _collectController.collectibles
        .any((c) => c.bangumiItem.id == item.id && c.section != 1);
    if (isRealBgmEntry) {
      if (context.mounted) context.pushNamed('/info/', arguments: item);
      return;
    }
    final src = item.info.trim();
    if (src.isEmpty) {
      // 旧收藏 (info 落库前收的) 或跨设备来的: 指引用户去源直连页重收
      KazumiDialog.showToast(message: '此收藏缺播放地址, 请从源直连浏览页重新收藏');
      return;
    }
    final plugins = inject<PluginsController>().pluginList;
    final siteHost = Uri.tryParse(src)?.host ?? '';
    Plugin? plugin;
    for (final p in plugins) {
      if ((Uri.tryParse(p.baseUrl)?.host ?? '') == siteHost) {
        plugin = p;
        break;
      }
    }
    if (plugin == null) {
      KazumiDialog.showToast(message: '未找到与收藏站点同域的规则源');
      return;
    }
    // 收藏页内直接跑播放任务 (取线路 → 播放页), 与源搜索同款交互
    if (dialogs.isRunning) return;
    await dialogs.run((task) async {
      final roads = await task.loading(
        message: '正在获取播放列表',
        barrierDismissible: isDesktop(),
        action: () => plugin!.queryChapterRoads(src),
      );
      if (roads.isEmpty) {
        throw Exception('未获取到播放线路');
      }
      if (mounted) {
        task.withContext((context) => context.pushNamed(
              '/video/',
              arguments: OnlineVideoPlaybackArgs(
                bangumiItem: item,
                plugin: plugin!,
                title: item.nameCn.isNotEmpty ? item.nameCn : item.name,
                src: src,
                roads: roads,
              ),
            ));
      }
    }, onError: (error, stackTrace) {
      KazumiLogger().w('AdultCollect: play failed', error: error);
      KazumiDialog.showToast(message: '获取播放列表失败，请重试');
    });
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
    // [my排查] 取消收藏无反应 — 记录调用与结果
    KazumiLogger().i(
        'AdultCollect: changeType id=${item.id} type=${type.value}');
    if (type == CollectType.none) {
      await _collectController.deleteCollectLocalOnly(item);
      KazumiLogger().i(
          'AdultCollect: deleted id=${item.id}, remaining=${_collectController.collectibles.length}');
      if (mounted) KazumiDialog.showToast(message: '已取消收藏');
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
