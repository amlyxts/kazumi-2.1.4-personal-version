import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/popular/popular_module.dart';
import 'package:kazumi/pages/my/my_module.dart';
import 'package:kazumi/pages/video/local_video_module.dart';
import 'package:kazumi/pages/timeline/timeline_module.dart';
import 'package:kazumi/pages/collect/collect_module.dart';
import 'package:kazumi/utils/constants.dart';

class MenuRouteItem {
  final String path;
  final Module module;

  const MenuRouteItem({
    required this.path,
    required this.module,
  });
}

class MenuRoute {
  final List<MenuRouteItem> menuList;

  const MenuRoute(this.menuList);

  int get size => menuList.length;

  List<Module> get moduleList {
    return menuList.map((e) => e.module).toList();
  }

  List<ModuleRoute> get routes {
    return menuList.map((e) => ModuleRoute(e.path, module: e.module)).toList();
  }

  getPath(int index) {
    return menuList[index].path;
  }
}

final MenuRoute menu = MenuRoute([
  MenuRouteItem(
    path: "/popular",
    module: PopularModule(),
  ),
  MenuRouteItem(
    path: "/timeline",
    module: TimelineModule(),
  ),
  MenuRouteItem(
    path: "/collect",
    module: CollectModule(),
  ),
  // [my修改] 移动端不挂本地视频页签, 页签索引随列表自动对齐
  if (kSupportsLocalVideo)
    MenuRouteItem(
      path: "/local_video",
      module: LocalVideoModule(),
    ),
  MenuRouteItem(
    path: "/my",
    module: MyModule(),
  ),
]);
