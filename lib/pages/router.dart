import 'package:flutter/foundation.dart';

import 'package:kazumi/utils/constants.dart';

class MenuRouteItem {
  const MenuRouteItem({required this.path});

  final String path;
}

class MenuRoute {
  const MenuRoute(this.menuList);

  final List<MenuRouteItem> menuList;

  String getPath(int index) => menuList[index].path;

  int indexForPath(String path) {
    final index = menuList.indexWhere(
      (item) =>
          path == '/tab${item.path}' ||
          path == '/tab${item.path}/' ||
          path.startsWith('/tab${item.path}/'),
    );
    // [my修复] 未命中返回 -1 (如按钮直航的 direct_search): 所有页签熄灭,
    // 原返回 0 会错亮推荐
    return index < 0 ? -1 : index;
  }
}

/// [my新增] shell 页签高亮覆盖通道: 页签外的入口 (源搜索按钮直航) 写
/// null 强制全灭; 页签点击/系统返回写回索引。ScaffoldMenu 监听本通道,
/// 优先于 indexForPath 的自动推算 — 绕开 nested-location 链路时序问题。
final ValueNotifier<int?> shellHighlightOverride = ValueNotifier(null);

final MenuRoute menu = MenuRoute([
  MenuRouteItem(path: '/popular'),
  MenuRouteItem(path: '/timeline'),
  MenuRouteItem(path: '/collect'),
  // [my修改] 里番收藏页签 (追番下方; iOS 不提供)
  if (kSupportsR18Tabs) MenuRouteItem(path: '/adult_collect'),
  // [my修改] 源直连搜索页签 (iOS 不提供)
  if (kSupportsR18Tabs) MenuRouteItem(path: '/direct_search'),
  // [my修改] 本地视频页签 (仅桌面端)
  if (kSupportsLocalVideo) MenuRouteItem(path: '/local_video'),
  MenuRouteItem(path: '/my'),
]);
