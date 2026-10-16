class PluginHTTPItem {
  String name;
  String version;
  bool useNativePlayer;
  String author;
  int lastUpdate;
  bool antiCrawlerEnabled;

  /// [my修改] 来源仓库: '' = 官方仓库; 否则为自定义仓库 base 前缀。
  /// 由目录 API 在拉取时打标, 安装/更新按此寻址, 不持久化。
  String sourceBase;

  PluginHTTPItem({
    required this.name,
    required this.version,
    required this.useNativePlayer,
    required this.author,
    required this.lastUpdate,
    this.antiCrawlerEnabled = false,
    this.sourceBase = '',
  });

  factory PluginHTTPItem.fromJson(Map<String, dynamic> json) {
    final dynamic rawConfig = json['antiCrawlerConfig'];
    final bool antiCrawlerEnabled = rawConfig is Map<String, dynamic>
        ? (rawConfig['enabled'] as bool? ?? false)
        : (json['antiCrawlerEnabled'] as bool? ?? false);
    return PluginHTTPItem(
      name: json['name'],
      version: json['version'],
      useNativePlayer: json['useNativePlayer'],
      author: json['author'],
      lastUpdate: json['lastUpdate'] ?? 0,
      antiCrawlerEnabled: antiCrawlerEnabled,
    );
  }
}
