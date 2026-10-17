// 自定义规则仓库列表解析单测 (纯函数, 无网络/存储依赖)
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/request/apis/plugin_catalog_api.dart';

void main() {
  test('解析: 正常列表全部保留', () {
    final repos = PluginCatalogApi.parseRepos(
        '[{"name":"a","url":"https://example.com/a/"},{"name":"b","url":"https://gh-proxy.org/https://raw.githubusercontent.com/u/r/main/"}]');
    expect(repos.length, 2);
    expect(repos[0].name, 'a');
    expect(repos[1].base,
        'https://gh-proxy.org/https://raw.githubusercontent.com/u/r/main/');
  });

  test('解析: base 自动补尾斜杠', () {
    final repos =
        PluginCatalogApi.parseRepos('[{"name":"a","url":"https://example.com/a"}]');
    expect(repos.single.base, 'https://example.com/a/');
  });

  test('解析: 无效条目跳过 (缺字段/非 http 协议)', () {
    final repos = PluginCatalogApi.parseRepos(
        '[{"name":"bad","url":"ftp://x/"},{"name":"","url":"https://x.com/"},{"url":"https://x.com/"},{"name":"ok","url":"https://ok.com/"}]');
    expect(repos.length, 1);
    expect(repos.single.name, 'ok');
  });

  test('解析: 空串/坏 JSON/非数组 返回空列表', () {
    expect(PluginCatalogApi.parseRepos(''), isEmpty);
    expect(PluginCatalogApi.parseRepos('not json'), isEmpty);
    expect(PluginCatalogApi.parseRepos('{"a":1}'), isEmpty);
  });
}
