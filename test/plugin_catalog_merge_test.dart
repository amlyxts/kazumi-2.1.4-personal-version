// 自定义规则仓库合并逻辑单测 (纯函数, 无网络/存储依赖)
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/request/apis/plugin_catalog_api.dart';
import 'package:kazumi/modules/plugin/plugin_http_module.dart';

PluginHTTPItem item(String name, [String version = '1.0']) =>
    PluginHTTPItem(
      name: name,
      version: version,
      useNativePlayer: true,
      author: 'test',
      lastUpdate: 0,
    );

void main() {
  test('合并: 自定义在前, 官方去重跟后, 同名以自定义为准', () {
    final custom = [item('myrepo'), item('dm84', '9.9')];
    final official = [item('dm84', '1.4'), item('age')];
    final merged = PluginCatalogApi.mergeCatalogs(custom, official);
    expect(merged.map((e) => e.name).toList(), ['myrepo', 'dm84', 'age']);
    expect(
        merged.firstWhere((e) => e.name == 'dm84').version, '9.9');
  });

  test('合并: 自定义为空时官方原样保留', () {
    final official = [item('age'), item('dm84')];
    final merged = PluginCatalogApi.mergeCatalogs([], official);
    expect(merged.map((e) => e.name).toList(), ['age', 'dm84']);
  });

  test('合并: 同名大小写不敏感去重', () {
    final merged =
        PluginCatalogApi.mergeCatalogs([item('DM84', '9.9')], [item('dm84')]);
    expect(merged.length, 1);
    expect(merged.first.version, '9.9');
  });

  test('合并: 双方皆空返回空', () {
    expect(PluginCatalogApi.mergeCatalogs([], []), isEmpty);
  });
}
