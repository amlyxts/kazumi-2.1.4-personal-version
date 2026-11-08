import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/widget/embedded_native_control_area.dart';
import 'package:kazumi/navigation.dart';
import 'package:kazumi/pages/menu/route_visibility.dart';
import 'package:kazumi/utils/constants.dart';

class ScaffoldMenu extends StatefulWidget {
  const ScaffoldMenu({super.key, required this.location});

  final String location;

  @override
  State<ScaffoldMenu> createState() => _ScaffoldMenu();
}

/// 页签规格 — [my重构] 单一事实源: 底栏 7 项 (含源搜索页签, 移动端),
/// 桌面侧栏 = 底栏去掉源搜索 (侧栏里源搜索是搜索按钮下方的独立按钮)。
/// 导航一律按路径 (不再用位置索引 — 三表位置耦合是历次错位的根源)。
class _TabSpec {
  const _TabSpec(this.path, this.icon, this.selectedIcon, this.label);

  final String path;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

final List<_TabSpec> _kBottomTabs = [
  _TabSpec('/popular', Icons.home_outlined, Icons.home, '推荐'),
  _TabSpec('/timeline', Icons.timeline_outlined, Icons.timeline, '时间表'),
  _TabSpec('/collect', Icons.favorite_border, Icons.favorite, '追番'),
  if (kSupportsR18Tabs)
    _TabSpec('/adult_collect', Icons.folder_special_outlined,
        Icons.folder_special, '里番收藏'),
  if (kSupportsLocalVideo)
    _TabSpec('/local_video', Icons.video_library_outlined,
        Icons.video_library, '本地视频'),
  if (kSupportsR18Tabs)
    _TabSpec('/direct_search', Icons.travel_explore_outlined,
        Icons.travel_explore, '源搜索'),
  _TabSpec('/my', Icons.settings_outlined, Icons.settings, '我的'),
];

final List<_TabSpec> _kRailTabs =
    _kBottomTabs.where((t) => t.path != '/direct_search').toList();

class _ScaffoldMenu extends State<ScaffoldMenu> with RouteAware {
  final _outletKey = GlobalKey<RouterOutletState>();

  /// 当前激活的页签路径 — 按路径导航与记忆, 与列表位置解耦
  String _selectedPath = '/popular';

  /// 上一次命中的页签位置 (源搜索按钮直航时页签列表无此项, 保持其高亮)
  int _lastTabIndex = 0;
  DateTime? _lastExitPromptAt;

  /// The shell sits at the bottom of the root stack and stays mounted while
  /// other pages cover it, so it publishes that state for its subtree.
  bool _isCovered = false;

  String _pathFromLocation(String location) {
    final raw =
        location.startsWith('/tab') ? location.substring(4) : location;
    var path = Uri.parse(raw).path;
    if (path.endsWith('/') && path.length > 1) {
      path = path.substring(0, path.length - 1);
    }
    return path;
  }

  int _highlightIndex(List<_TabSpec> tabs) {
    final i = tabs.indexWhere((t) => t.path == _selectedPath);
    if (i >= 0) {
      _lastTabIndex = i;
      return i;
    }
    // 直航页 (源搜索按钮/未知道路): 保持上一次页签高亮
    return _lastTabIndex.clamp(0, tabs.length - 1);
  }

  @override
  void initState() {
    super.initState();
    _selectedPath = _pathFromLocation(widget.location);
  }

  @override
  void didUpdateWidget(covariant ScaffoldMenu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.location != widget.location) {
      _selectedPath = _pathFromLocation(widget.location);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<void>) {
      rootRouteObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    rootRouteObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPushNext() => _setCovered(true);

  @override
  void didPopNext() => _setCovered(false);

  void _setCovered(bool value) {
    if (!mounted || _isCovered == value) {
      return;
    }
    setState(() => _isCovered = value);
  }

  /// 按路径导航 (页签/按钮共用) — 不再有索引换算
  void _navigateTo(String path) {
    _lastExitPromptAt = null;
    if (_selectedPath == path) {
      return;
    }
    _selectedPath = path;
    if (mounted) setState(() {});
    _outletKey.currentState?.navigate('/tab$path/');
  }

  void _handleSystemBack(BuildContext context) {
    if (_outletKey.currentState?.maybePop() ?? false) {
      _lastExitPromptAt = null;
      return;
    }

    if (_selectedPath != '/popular') {
      _navigateTo('/popular');
      return;
    }

    final now = DateTime.now();
    final lastPromptAt = _lastExitPromptAt;
    if (lastPromptAt == null ||
        now.difference(lastPromptAt) > const Duration(seconds: 2)) {
      _lastExitPromptAt = now;
      KazumiDialog.showToast(message: '再按一次退出应用', context: context);
      return;
    }

    _lastExitPromptAt = null;
    SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final portrait =
        MediaQuery.orientationOf(context) == Orientation.portrait;
    final tabs = portrait ? _kBottomTabs : _kRailTabs;
    final highlight = _highlightIndex(tabs);
    return RouteVisibility(
      isCovered: _isCovered,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) {
            _handleSystemBack(context);
          }
        },
        child: portrait
            ? _bottomMenu(context, tabs, highlight)
            : _sideMenu(context, tabs, highlight),
      ),
    );
  }

  Widget _outlet(BuildContext context, {BorderRadius? borderRadius}) {
    Widget child = NotificationListener<NavigationNotification>(
      // A non-poppable outlet must not override the shell's PopScope state.
      onNotification: (notification) => !notification.canHandlePop,
      child: RouterOutlet(key: _outletKey),
    );
    if (borderRadius != null) {
      child = ClipRRect(borderRadius: borderRadius, child: child);
    }
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: borderRadius,
      ),
      child: child,
    );
  }

  Widget _bottomMenu(
      BuildContext context, List<_TabSpec> tabs, int highlight) {
    return Scaffold(
      body: _outlet(context),
      bottomNavigationBar: NavigationBar(
        destinations: [
          for (final tab in tabs)
            NavigationDestination(
              selectedIcon: Icon(tab.selectedIcon),
              icon: Icon(tab.icon),
              label: tab.label,
            ),
        ],
        selectedIndex: highlight,
        onDestinationSelected: (index) =>
            _navigateTo(tabs[index].path),
      ),
    );
  }

  Widget _sideMenu(
      BuildContext context, List<_TabSpec> tabs, int highlight) {
    const borderRadius = BorderRadius.only(
      topLeft: Radius.circular(16),
      bottomLeft: Radius.circular(16),
    );
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      body: Row(
        children: [
          EmbeddedNativeControlArea(
            child: NavigationRail(
              backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
              groupAlignment: 1,
              // [my修改] 左上角搜索按钮 + 其下方的源搜索按钮 (独立按钮,
              // 不是页签; 直航 /tab/direct_search/ 且保持页签原高亮)
              leading: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FloatingActionButton(
                    elevation: 0,
                    heroTag: 'menu-search-fab',
                    onPressed: () => context.pushNamed('/search/'),
                    child: const Icon(Icons.search),
                  ),
                  const SizedBox(height: 12),
                  if (kSupportsR18Tabs)
                    FloatingActionButton(
                      elevation: 0,
                      heroTag: 'menu-direct-search-fab',
                      onPressed: () => _navigateTo('/direct_search'),
                      child: const Icon(Icons.travel_explore),
                    ),
                ],
              ),
              labelType: NavigationRailLabelType.selected,
              destinations: [
                for (final tab in tabs)
                  NavigationRailDestination(
                    selectedIcon: Icon(tab.selectedIcon),
                    icon: Icon(tab.icon),
                    label: Text(tab.label),
                  ),
              ],
              selectedIndex: highlight,
              onDestinationSelected: (index) =>
                  _navigateTo(tabs[index].path),
            ),
          ),
          Expanded(child: _outlet(context, borderRadius: borderRadius)),
        ],
      ),
    );
  }
}
