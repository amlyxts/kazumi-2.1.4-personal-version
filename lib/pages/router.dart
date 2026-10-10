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
    return index < 0 ? 0 : index;
  }
}

final MenuRoute menu = MenuRoute([
  MenuRouteItem(path: '/popular'),
  MenuRouteItem(path: '/timeline'),
  MenuRouteItem(path: '/collect'),
  // [my修改] 本地视频页签 (仅桌面端)
  if (kSupportsLocalVideo) MenuRouteItem(path: '/local_video'),
  MenuRouteItem(path: '/my'),
]);
