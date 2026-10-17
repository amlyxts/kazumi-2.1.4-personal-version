import 'dart:convert';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/clients/rules_repo_client.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/modules/plugin/plugin_http_module.dart';
import 'package:kazumi/services/storage/storage.dart';

/// [my修改] 自定义规则仓库 (上游 Issue #2485 的个人实现)。
/// 可配置多个仓库, 插件市场按所选仓库拉取目录, 打开页面默认官方仓库。
/// 仓库约定: `{url}index.json` 为目录, `{url}<规则名>.json` 为规则体。
/// raw.githubusercontent 源可套 gh-proxy 前缀加速。
class RuleRepo {
  String name;
  String url;

  RuleRepo({required this.name, required this.url});

  factory RuleRepo.fromJson(Map<String, dynamic> json) => RuleRepo(
        name: json['name']?.toString() ?? '',
        url: json['url']?.toString() ?? '',
      );

  Map<String, dynamic> toJson() => {'name': name, 'url': url};

  bool get valid =>
      name.isNotEmpty &&
      url.isNotEmpty &&
      Uri.tryParse(url) != null &&
      (uri?.scheme == 'http' || uri?.scheme == 'https') &&
      (uri?.host.isNotEmpty ?? false);

  Uri? get uri => Uri.tryParse(url);

  /// 规范化 base: 补尾斜杠
  String get base => url.endsWith('/') ? url : '$url/';
}

class PluginCatalogApi {
  static final RulesRepoClient _client = RulesRepoClient.instance;

  /// 官方仓库目录 (sourceBase = '' 即官方)
  static Future<List<PluginHTTPItem>> getPluginList() async {
    return _fetchCatalog(ApiEndpoints.pluginShop, '');
  }

  /// 解析设置里的自定义仓库列表; 无效条目跳过
  static List<RuleRepo> parseRepos(String raw) {
    if (raw.isEmpty) return [];
    try {
      final list = json.decode(raw);
      if (list is! List) return [];
      return [
        for (final item in list)
          if (item is Map)
            RuleRepo.fromJson(Map<String, dynamic>.from(item)),
      ].where((repo) => repo.valid).toList();
    } catch (e) {
      KazumiLogger().w('Plugin: 自定义仓库列表解析失败: $e');
      return [];
    }
  }

  static List<RuleRepo> listRepos() {
    final raw = GStorage.getSetting(SettingsKeys.customRuleRepos);
    return parseRepos(raw);
  }

  /// 拉取指定仓库目录并为条目打上来源标
  static Future<List<PluginHTTPItem>> _fetchCatalog(
      String base, String sourceName) async {
    final raw = await _client.getText('${base}index.json');
    final result = parsePluginList(raw);
    if (result.skippedItems > 0) {
      KazumiLogger().w(
        'Plugin: skipped ${result.skippedItems} invalid rule catalog item(s)',
      );
    }
    for (final item in result.items) {
      item.sourceBase = base;
    }
    KazumiLogger().i(
        'Plugin: 已加载${sourceName.isEmpty ? '' : ' $sourceName'}仓库目录 '
        '(${result.items.length} 条, base=$base)');
    return result.items;
  }

  static Future<List<PluginHTTPItem>> fetchCatalogFromRepo(RuleRepo repo) {
    return _fetchCatalog(repo.base, repo.name);
  }

  static PluginCatalogParseResult parsePluginList(String raw) {
    final jsonData = json.decode(raw);
    if (jsonData is! List) {
      throw const FormatException('Rule catalog root must be a JSON array');
    }
    final items = <PluginHTTPItem>[];
    var skippedItems = 0;
    for (var index = 0; index < jsonData.length; index++) {
      try {
        items.add(_parsePluginListItem(jsonData[index], index));
      } on FormatException {
        skippedItems++;
      }
    }
    if (jsonData.isNotEmpty && items.isEmpty) {
      throw const FormatException('Rule catalog contains no valid items');
    }
    return PluginCatalogParseResult(
      items: List.unmodifiable(items),
      skippedItems: skippedItems,
    );
  }

  static PluginHTTPItem _parsePluginListItem(Object? value, int index) {
    if (value is! Map) {
      throw FormatException('Rule catalog item $index must be an object');
    }
    try {
      return PluginHTTPItem.fromJson(Map<String, dynamic>.from(value));
    } catch (error) {
      throw FormatException('Invalid rule catalog item $index: $error');
    }
  }

  /// [base] 为空 = 官方仓库; 否则为自定义仓库 base 前缀
  static Future<Plugin> getPlugin(String name, {String? base}) async {
    return _parsePlugin(await _client
        .getText('${(base ?? ApiEndpoints.pluginShop)}$name.json'));
  }

  static Plugin _parsePlugin(String raw) {
    final jsonData = json.decode(raw);
    if (jsonData is! Map) {
      throw const FormatException('Rule must be a JSON object');
    }
    return Plugin.fromJson(Map<String, dynamic>.from(jsonData));
  }
}

class PluginCatalogParseResult {
  const PluginCatalogParseResult({
    required this.items,
    required this.skippedItems,
  });

  final List<PluginHTTPItem> items;
  final int skippedItems;
}
