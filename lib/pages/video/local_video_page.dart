import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/pages/video/local_video_launcher.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/video/local_cover_service.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/utils/local_video_utils.dart';

/// [my修改] 本地视频库：看过一次的文件夹生成一张卡片, 点击直接从上次位置续播。
/// 支持用户自管理分类 (添加/重命名/删除/排序), 顶部标签行筛选, 样式与追番页一致。
class LocalVideoPage extends StatefulWidget {
  const LocalVideoPage({super.key});

  @override
  State<LocalVideoPage> createState() => _LocalVideoPageState();
}

class _LocalVideoPageState extends State<LocalVideoPage>
    with SingleTickerProviderStateMixin {
  // [my修改] modular 7：inject 全局获取；播放上下文经路由参数传递，不再持有共享控制器
  final HistoryController _historyController = inject<HistoryController>();

  List<History> _entries = [];
  // [my修改] 封面缓存: 文件夹合成 id → 封面文件路径 (null=无封面/未生成)
  final Map<int, String?> _covers = {};
  bool _coversLoading = false;

  // [my修改] 分类: 名称列表 (有序) 与 文件夹id→分类名 归属
  List<String> _categories = [];
  Map<String, String> _assign = {};
  TabController? _tabController;
  int _tabIndex = 0;
  bool _editMode = false;

  @override
  void initState() {
    super.initState();
    _categories = _loadCategories();
    _assign = _loadAssign();
    _reload();
  }

  @override
  void dispose() {
    _tabController?.dispose();
    super.dispose();
  }

  List<String> _loadCategories() {
    try {
      final raw = GStorage.getSetting(SettingsKeys.localVideoCategories);
      return (jsonDecode(raw) as List).cast<String>();
    } catch (_) {
      return [];
    }
  }

  Map<String, String> _loadAssign() => loadLocalVideoAssign();

  Future<void> _saveCategories() async {
    await GStorage.putSetting(
        SettingsKeys.localVideoCategories, jsonEncode(_categories));
  }

  Future<void> _saveAssign() => saveLocalVideoAssign(_assign);

  void _syncTabController() {
    final length = _categories.length + 1; // 全部 + 分类们
    final old = _tabController;
    if (old != null && old.length == length) {
      if (_tabIndex >= length) {
        _tabIndex = length - 1;
        old.index = _tabIndex;
      }
      return;
    }
    _tabIndex = _tabIndex.clamp(0, length - 1);
    _tabController = TabController(
        vsync: this,
        length: length,
        initialIndex: _tabIndex)
      ..addListener(() {
        if (!_tabController!.indexIsChanging) {
          setState(() => _tabIndex = _tabController!.index);
        }
      });
    old?.dispose();
  }

  void _reload() {
    _assign = _loadAssign();
    _historyController.init();
    final localEntries = _historyController.histories
        .where((h) => h.adapterName == localVideoPluginName)
        .toList()
      ..sort((a, b) => b.lastWatchTime.compareTo(a.lastWatchTime));
    if (mounted) {
      setState(() => _entries = localEntries);
    }
    _syncTabController();
    _loadCovers();
  }

  List<History> _filteredEntries() {
    if (_tabIndex == 0) {
      return _entries;
    }
    final category = _categories[_tabIndex - 1];
    return _entries
        .where((h) => _assign['${h.bangumiItem.id}'] == category)
        .toList();
  }

  String? _categoryOf(History history) => _assign['${history.bangumiItem.id}'];

  // [my修改] 后台逐个生成封面 (mpv 截帧), 生成一张刷一张
  Future<void> _loadCovers() async {
    if (_coversLoading) return;
    _coversLoading = true;
    for (final history in _entries) {
      final id = history.bangumiItem.id;
      if (_covers.containsKey(id)) continue;
      if (_isFileMissing(history)) {
        _covers[id] = null;
        continue;
      }
      final folder = localEntryDirectory(history.episodePageUrl);
      String? cover;
      try {
        cover = await LocalVideoCoverService.coverForFolder(folder);
      } catch (_) {}
      if (!mounted) {
        _coversLoading = false;
        return;
      }
      setState(() => _covers[id] = cover);
    }
    _coversLoading = false;
  }

  bool _isFileMissing(History history) =>
      history.episodePageUrl.isEmpty ||
      !File(history.episodePageUrl).existsSync();

  String _progressText(History history) {
    final episodeText = '第 ${history.lastWatchEpisode} 集';
    final progress = history.progresses[history.lastWatchEpisode]?.progress;
    if (progress == null || progress.inSeconds <= 0) {
      return episodeText;
    }
    final seconds = (progress.inSeconds % 60).toString().padLeft(2, '0');
    final minutes = (progress.inMinutes % 60).toString().padLeft(2, '0');
    final position = progress.inHours > 0
        ? '${progress.inHours}:$minutes:$seconds'
        : '$minutes:$seconds';
    return '$episodeText · 看到 $position';
  }

  // 与历史卡片相同的续播逻辑: 存储的文件路径还在 → 重扫文件夹续播;
  // 文件没了但文件夹在 → 按上次集数就近定位; 彻底没了 → 询问清理
  Future<void> _openEntry(History history) async {
    final storedPath = history.episodePageUrl;
    final fileExists = storedPath.isNotEmpty && File(storedPath).existsSync();
    final folder = localEntryDirectory(storedPath);
    List<String> files;
    int startEpisode;

    if (fileExists) {
      files = listLocalVideoFiles(folder);
      final index = files.indexWhere(
          (f) => normalizeLocalPath(f) == normalizeLocalPath(storedPath));
      if (index < 0) {
        files = [storedPath];
        startEpisode = 1;
      } else {
        startEpisode = index + 1;
      }
    } else {
      files = listLocalVideoFiles(folder);
      if (files.isEmpty) {
        _confirmDelete(history, '本地文件已不存在，是否删除这条记录？');
        return;
      }
      startEpisode = history.lastWatchEpisode.clamp(1, files.length).toInt();
    }

    // [my修改] modular 7 参数对象模式：播放上下文经路由交给 VideoPage 自建控制器
    if (!mounted) return;
    context.pushNamed(
      '/video/',
      arguments: LocalVideoPlaybackArgs(
        bangumiItem: history.bangumiItem,
        filePaths: files,
        startEpisode: startEpisode,
      ),
    );
    _reload();
  }

  void _confirmDelete(History history, String message) {
    KazumiDialog.show(
      builder: (context) => AlertDialog(
        title: const Text('删除记录'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _deleteEntry(history);
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteEntry(History history) async {
    await _historyController.deleteHistory(history);
    _assign.remove('${history.bangumiItem.id}');
    await _saveAssign();
    _reload();
  }

  Future<void> _addVideo() async {
    await showLocalVideoAddDialog(context);
    _reload();
  }

  // [my修改] 卡片长按菜单: 移动到分类 / 删除记录
  void _showEntryActions(History history) {
    KazumiDialog.show(
      builder: (context) => AlertDialog(
        title: Text(history.bangumiItem.name,
            maxLines: 2, overflow: TextOverflow.ellipsis),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_copy_outlined),
              title: const Text('移动到分类'),
              onTap: () {
                Navigator.of(context).pop();
                _moveToCategoryDialog(history);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除记录'),
              onTap: () {
                Navigator.of(context).pop();
                _confirmDelete(history, '确定删除这条观看记录吗?\n(不会删除磁盘上的视频文件)');
              },
            ),
          ],
        ),
      ),
    );
  }

  // [my修改] 移动到分类: 单选弹窗 + 新建分类入口
  void _moveToCategoryDialog(History history) {
    final id = '${history.bangumiItem.id}';
    KazumiDialog.show(
      builder: (context) => StatefulBuilder(builder: (context, setState) {
        final current = _assign[id];
        return AlertDialog(
          title: const Text('移动到分类'),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(
                      current == null
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      color: Theme.of(context).colorScheme.primary),
                  title: const Text('未分类'),
                  onTap: () {
                    setState(() => _assign.remove(id));
                  },
                ),
                for (final category in _categories)
                  ListTile(
                    leading: Icon(
                        current == category
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        color: Theme.of(context).colorScheme.primary),
                    title: Text(category),
                    onTap: () {
                      setState(() => _assign[id] = category);
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.add),
                  title: const Text('新建分类并移入'),
                  onTap: () async {
                    Navigator.of(context).pop();
                    final newCategory = await _newCategoryDialog();
                    if (newCategory != null && newCategory.isNotEmpty) {
                      if (!_categories.contains(newCategory)) {
                        setState(() => _categories.add(newCategory));
                        _saveCategories();
                        _syncTabController();
                      }
                      _assign[id] = newCategory;
                      await _saveAssign();
                    }
                    _moveToCategoryDialog(history);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await _saveAssign();
                _reload();
              },
              child: const Text('确定'),
            ),
          ],
        );
      }),
    );
  }

  Future<String?> _newCategoryDialog() async {
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

  // [my修改] 分类管理: 添加/重命名/删除/上下排序
  void _manageCategoriesDialog() {
    KazumiDialog.show(
      builder: (context) => StatefulBuilder(builder: (context, setState) {
        return AlertDialog(
          title: const Text('管理分类'),
          content: SizedBox(
            width: 360,
            height: 380,
            child: Column(
              children: [
                _AddCategoryRow(
                  onAdd: (name) {
                    if (name.isEmpty || _categories.contains(name)) return;
                    setState(() => _categories.add(name));
                    _saveCategories();
                    _syncTabController();
                  },
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ListView.builder(
                    itemCount: _categories.length,
                    itemBuilder: (context, index) {
                      final category = _categories[index];
                      return ListTile(
                        dense: true,
                        title: Text(category),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (index > 0)
                              IconButton(
                                icon:
                                    const Icon(Icons.arrow_upward, size: 20),
                                tooltip: '上移',
                                onPressed: () {
                                  setState(() {
                                    final tmp = _categories[index - 1];
                                    _categories[index - 1] =
                                        _categories[index];
                                    _categories[index] = tmp;
                                  });
                                  _saveCategories();
                                  _syncTabController();
                                },
                              ),
                            if (index < _categories.length - 1)
                              IconButton(
                                icon: const Icon(Icons.arrow_downward,
                                    size: 20),
                                tooltip: '下移',
                                onPressed: () {
                                  setState(() {
                                    final tmp = _categories[index + 1];
                                    _categories[index + 1] =
                                        _categories[index];
                                    _categories[index] = tmp;
                                  });
                                  _saveCategories();
                                  _syncTabController();
                                },
                              ),
                            IconButton(
                              icon:
                                  const Icon(Icons.edit_outlined, size: 20),
                              tooltip: '重命名',
                              onPressed: () async {
                                final controller = TextEditingController(
                                    text: category);
                                final newName =
                                    await KazumiDialog.show<String>(
                                  builder: (context) => AlertDialog(
                                    title: const Text('重命名分类'),
                                    content: TextField(
                                      controller: controller,
                                      maxLength: 20,
                                      autofocus: true,
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(context).pop(),
                                        child: const Text('取消'),
                                      ),
                                      TextButton(
                                        onPressed: () => Navigator.of(
                                                context)
                                            .pop(controller.text.trim()),
                                        child: const Text('确定'),
                                      ),
                                    ],
                                  ),
                                );
                                if (newName == null ||
                                    newName.isEmpty ||
                                    _categories.contains(newName)) {
                                  return;
                                }
                                setState(() {
                                  _categories[index] = newName;
                                  _assign.updateAll((key, value) =>
                                      value == category ? newName : value);
                                });
                                _saveCategories();
                                _saveAssign();
                                _syncTabController();
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  size: 20),
                              tooltip: '删除',
                              onPressed: () {
                                setState(() {
                                  _categories.removeAt(index);
                                  _assign.removeWhere(
                                      (key, value) => value == category);
                                });
                                _saveCategories();
                                _saveAssign();
                                _syncTabController();
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                _reload();
              },
              child: const Text('完成'),
            ),
          ],
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    // [my修改] 列数与追番页一致 (同款断点)
    int crossCount = 3;
    if (MediaQuery.sizeOf(context).width >
        LayoutBreakpoint.compact['width']!) {
      crossCount = 5;
    }
    if (MediaQuery.sizeOf(context).width >
        LayoutBreakpoint.medium['width']!) {
      crossCount = 6;
    }
    final filtered = _filteredEntries();
    final tabs = <Tab>[
      const Tab(text: '全部'),
      for (final category in _categories) Tab(text: category),
    ];
    // [my修改] 2.3.8 的 SysAppBar 无 bottom 参数, 分类 TabBar 移入 body 顶部
    final Widget? categoryTabBar = _tabController == null
        ? null
        : TabBar(
            controller: _tabController,
            tabs: tabs,
            indicatorColor: colorScheme.primary,
            isScrollable: _categories.length > 4,
          );
    return Scaffold(
      appBar: SysAppBar(
        needTopOffset: false,
        toolbarHeight: 104,
        title: const Text('本地视频'),
        actions: [
          IconButton(
            tooltip: '添加视频',
            onPressed: () async {
              await showLocalVideoAddDialog(context);
              _reload();
            },
            icon: const Icon(Icons.add),
          ),
          IconButton(
            tooltip: _editMode ? '退出编辑' : '编辑分类 (点击卡片移动到分类)',
            onPressed: () => setState(() => _editMode = !_editMode),
            icon: Icon(_editMode ? Icons.edit_off_outlined : Icons.edit_outlined),
          ),
          IconButton(
            icon: const Icon(Icons.category_outlined),
            tooltip: '管理分类',
            onPressed: _manageCategoriesDialog,
          ),
        ],
      ),
      body: Column(
        children: [
          if (categoryTabBar != null)
            SizedBox(height: 48, child: categoryTabBar),
          Expanded(
            child: _entries.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.video_library_outlined,
                      size: 56, color: colorScheme.outline),
                  const SizedBox(height: 12),
                  Text('还没有播放记录, 点击下方按钮添加本地视频',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: colorScheme.onSurfaceVariant)),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _addVideo,
                    icon: const Icon(Icons.add),
                    label: const Text('添加本地视频'),
                  ),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: () async => _reload(),
              child: Column(
                children: [
                  if (_editMode)
                    Container(
                      width: double.infinity,
                      color: colorScheme.primaryContainer,
                      padding: const EdgeInsets.symmetric(
                          vertical: 6, horizontal: 12),
                      child: Text('编辑模式: 点击卡片移动到分类',
                          style: theme.textTheme.labelMedium?.copyWith(
                              color: colorScheme.onPrimaryContainer)),
                    ),
                  Expanded(
                    child: GridView.builder(
                // [my修改] 与追番页同款网格: 固定列数 + 统一主轴高度 (竖版海报卡), 间距与追番页一致
                padding: const EdgeInsets.fromLTRB(
                    StyleString.cardSpace,
                    StyleString.cardSpace,
                    StyleString.cardSpace,
                    0),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  mainAxisSpacing: StyleString.cardSpace - 2,
                  crossAxisSpacing: StyleString.cardSpace,
                  crossAxisCount: crossCount,
                  mainAxisExtent:
                      MediaQuery.sizeOf(context).width / crossCount / 0.65 +
                          MediaQuery.textScalerOf(context).scale(32.0),
                ),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final history = filtered[index];
                    final missing = _isFileMissing(history);
                    return _LocalVideoCard(
                      title: history.bangumiItem.name,
                      progressText: _progressText(history),
                      missing: missing,
                      category: _categoryOf(history),
                      coverPath: _covers[history.bangumiItem.id],
                      editMode: _editMode,
                      onMoveOut: () async {
                        _assign.remove('${history.bangumiItem.id}');
                        await _saveAssign();
                        _reload();
                      },
                      onTap: () {
                        if (_editMode) {
                          _moveToCategoryDialog(history);
                        } else {
                          _openEntry(history);
                        }
                      },
                      onLongPress: () => _showEntryActions(history),
                    );
                  },
                ),
              ),
              ],
            ),
          ),
          ),
        ],
      ),
    );
  }
}

class _AddCategoryRow extends StatelessWidget {
  const _AddCategoryRow({required this.onAdd});

  final ValueChanged<String> onAdd;

  @override
  Widget build(BuildContext context) {
    final controller = TextEditingController();
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            maxLength: 20,
            decoration:
                const InputDecoration(hintText: '新分类名称', isDense: true),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add),
          tooltip: '添加分类',
          onPressed: () {
            final name = controller.text.trim();
            if (name.isNotEmpty) onAdd(name);
          },
        ),
      ],
    );
  }
}

class _LocalVideoCard extends StatelessWidget {
  const _LocalVideoCard({
    required this.title,
    required this.progressText,
    required this.missing,
    required this.onTap,
    required this.onLongPress,
    this.category,
    this.coverPath,
    this.editMode = false,
    this.onMoveOut,
  });

  final String title;
  final String progressText;
  final bool missing;
  final String? category;
  final String? coverPath;
  final bool editMode;
  final VoidCallback? onMoveOut;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final cover = coverPath != null && File(coverPath!).existsSync();
    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SizedBox(
                width: double.infinity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (cover)
                      Image.file(File(coverPath!),
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          errorBuilder: (_, __, ___) => _placeholder(
                              theme, colorScheme))
                    else
                      _placeholder(theme, colorScheme),
                    if (editMode &&
                        category != null &&
                        category!.isNotEmpty &&
                        onMoveOut != null)
                      Positioned(
                        right: 6,
                        top: 6,
                        child: InkWell(
                          onTap: onMoveOut,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: colorScheme.errorContainer,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Icon(Icons.close,
                                size: 16,
                                color: colorScheme.onErrorContainer),
                          ),
                        ),
                      ),
                    if (category != null && category!.isNotEmpty)
                      Positioned(
                        left: 6,
                        top: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(category!,
                              style: theme.textTheme.labelSmall?.copyWith(
                                  color: colorScheme.onPrimaryContainer)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // [my修改] 固定高度文字区: 标题长度不影响封面大小
            SizedBox(
              height: 66,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(progressText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium?.copyWith(
                            color: missing
                                ? colorScheme.error
                                : colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _placeholder(ThemeData theme, ColorScheme colorScheme) {
    return Container(
      width: double.infinity,
      color: colorScheme.surfaceContainerHighest,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            missing ? Icons.broken_image_outlined : Icons.movie_outlined,
            size: 40,
            color: colorScheme.onSurfaceVariant,
          ),
          if (missing) ...[
            const SizedBox(height: 6),
            Text('文件缺失',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: colorScheme.error)),
          ],
        ],
      ),
    );
  }
}
