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
