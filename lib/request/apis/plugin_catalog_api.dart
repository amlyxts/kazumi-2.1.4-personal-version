import 'dart:convert';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/request/clients/rules_repo_client.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/modules/plugin/plugin_http_module.dart';
import 'package:kazumi/services/storage/storage.dart';

class PluginCatalogApi {
  static final RulesRepoClient _client = RulesRepoClient.instance;

  /// 自定义规则仓库 base 前缀 (上游 Issue #2485 的个人实现)。
  /// 约定: `{base}index.json` 为目录, `{base}<规则名>.json` 为规则体;
  /// 留空 = 仅官方仓库。可填 gh-proxy 前缀为 raw.githubusercontent 仓库加速。
  static String? get _customRepoBase {
    final raw = GStorage.getSetting(SettingsKeys.customRuleRepoUrl).trim();
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      KazumiLogger().w('Plugin: 自定义规则仓库地址无效, 已忽略: $raw');
      return null;
    }
    return raw.endsWith('/') ? raw : '$raw/';
  }

  static Future<List<PluginHTTPItem>> getPluginList() async {
    return getMergedPluginList(_customRepoBase);
  }

  /// [customBase] 为 null 时仅官方仓库; 参数化以便测试注入。
  /// 合并规则: 自定义目录在前, 官方去重跟后 —— 同名规则以自定义仓库为准。
  static Future<List<PluginHTTPItem>> getMergedPluginList(
      String? customBase) async {
    final official = await _fetchCatalog(ApiEndpoints.pluginShop);
    if (customBase == null) return official;
    try {
      final custom = await _fetchCatalog(customBase);
      final merged = mergeCatalogs(custom, official);
      KazumiLogger().i(
          'Plugin: 规则目录已合并 (自定义 ${custom.length} 条 + 官方 ${official.length} 条)');
      return List.unmodifiable(merged);
    } catch (error) {
      KazumiLogger().w('Plugin: 自定义规则仓库加载失败, 回落仅官方目录: $error');
      return official;
    }
  }

  /// 自定义在前, 官方按名去重跟后 (同名以自定义为准, 大小写不敏感)。
  static List<PluginHTTPItem> mergeCatalogs(
      List<PluginHTTPItem> custom, List<PluginHTTPItem> official) {
    final customNames = {
      for (final item in custom) pluginNameKey(item.name),
    };
    return [
      ...custom,
      ...official.where(
          (item) => !customNames.contains(pluginNameKey(item.name))),
    ];
  }

  static Future<List<PluginHTTPItem>> _fetchCatalog(String base) async {
    final raw = await _client.getText('${base}index.json');
    final result = parsePluginList(raw);
    if (result.skippedItems > 0) {
      KazumiLogger().w(
        'Plugin: skipped ${result.skippedItems} invalid rule catalog item(s)',
      );
    }
    return result.items;
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

  static Future<Plugin> getPlugin(String name) async {
    return getPluginWithRepos(name, _customRepoBase);
  }

  /// [customBase] 非 null 时优先从自定义仓库取, 失败回落官方仓库。
  static Future<Plugin> getPluginWithRepos(String name, String? customBase) async {
    if (customBase != null) {
      try {
        return _parsePlugin(
            await _client.getText('$customBase$name.json'));
      } catch (error) {
        KazumiLogger().w('Plugin: 自定义仓库未取到 $name, 回落官方仓库');
      }
    }
    return _parsePlugin(
        await _client.getText('${ApiEndpoints.pluginShop}$name.json'));
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
