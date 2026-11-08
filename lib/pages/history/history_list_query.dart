import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/constants.dart';

enum HistorySourceFilter {
  all('全部'),
  online('在线'),
  offline('缓存'),
  // [my新增] 直连档: 源直连浏览产生的历史 (播放页地址含 watch?v= 特征),
  // 即里番来源 — iOS 默认隐藏该档 (公共场合隐私), 其他平台可筛
  direct('直连');

  const HistorySourceFilter(this.label);

  final String label;

  /// 直连来源判定: 播放页地址带 watch?v= (源站播放页特征)。
  /// 未匹配的直连条目 (极旧记录无 pageUrl) 归"在线"不误藏。
  static bool isDirect(History history) =>
      history.episodePageUrl.contains('watch?v=');

  // [my修复] iOS 强制恒隐藏直连条目 (纯表番端设计): 同步来的里番历史
  // 此前在 iOS 裸奔 (设置无开关且默认关), 现平台强制 + 设置双门控。
  static bool get _hideDirect =>
      !kSupportsR18Tabs || kHideDirectHistory;

  bool _matches(History history) => switch (this) {
        all => _hideDirect ? !isDirect(history) : true,
        online => HistoryEntryKind.normalize(history.entryKind) ==
                HistoryEntryKind.online &&
            !(_hideDirect && isDirect(history)),
        offline => HistoryEntryKind.normalize(history.entryKind) ==
                HistoryEntryKind.offline &&
            !(_hideDirect && isDirect(history)),
        direct => isDirect(history) && !_hideDirect,
      };
}

/// [my修改] 隐藏直连历史改为设置项 (默认关, 双平台通用):
/// 开启后三档均滤直连条目且"直连"档不显示 — 原方案A为 iOS 硬编码,
/// 用户要求可在任意平台自行开关。
bool get kHideDirectHistory =>
    GStorage.getSetting(SettingsKeys.hideDirectHistory);

class HistoryDateGroup {
  HistoryDateGroup._(this.date, this.entries);

  final DateTime date;
  final List<History> entries;

  String label(DateTime now) {
    final localNow = now.toLocal();
    final today = DateTime(localNow.year, localNow.month, localNow.day);
    if (date == today) return '今天';
    if (date == DateTime(today.year, today.month, today.day - 1)) return '昨天';
    final prefix = date.year == today.year ? '' : '${date.year}年';
    return '$prefix${date.month}月${date.day}日';
  }
}

List<HistoryDateGroup> groupHistoryEntries(
  Iterable<History> entries, {
  String query = '',
  HistorySourceFilter source = HistorySourceFilter.all,
}) {
  final keyword = query.trim().toLowerCase();
  final filtered = entries.where((entry) {
    if (!source._matches(entry)) return false;
    final item = entry.bangumiItem;
    return keyword.isEmpty ||
        [item.name, item.nameCn, ...item.alias, entry.adapterName]
            .any((value) => value.toLowerCase().contains(keyword));
  }).toList()
    ..sort((a, b) => b.lastWatchTime.compareTo(a.lastWatchTime));

  final groups = <HistoryDateGroup>[];
  for (final entry in filtered) {
    final localTime = entry.lastWatchTime.toLocal();
    final date = DateTime(localTime.year, localTime.month, localTime.day);
    if (groups.isEmpty || groups.last.date != date) {
      groups.add(HistoryDateGroup._(date, []));
    }
    groups.last.entries.add(entry);
  }
  return groups;
}
