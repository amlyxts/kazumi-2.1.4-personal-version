import 'dart:io';

import 'package:kazumi/modules/history/history_module.dart';

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

  bool _matches(History history) => switch (this) {
        all =>
          // iOS: 直连档隐藏 = 全部视图也不显示直连条目 (隐私默认)
          kHideDirectHistory ? !isDirect(history) : true,
        online => HistoryEntryKind.normalize(history.entryKind) ==
                HistoryEntryKind.online &&
            !(kHideDirectHistory && isDirect(history)),
        offline => HistoryEntryKind.normalize(history.entryKind) ==
                HistoryEntryKind.offline &&
            // [my修复] iOS 缓存档同样滤直连条目 — 此前只滤了全部/在线,
            // 缓存视图仍暴露 (用户实测发现)
            !(kHideDirectHistory && isDirect(history)),
        direct => isDirect(history),
      };
}

/// [my新增] iOS 隐藏直连历史 (方案A): 默认视图与"在线"档都不显示
/// 直连来源条目; "直连"档本尊也不列入选项 (等于功能整体隐藏)。
final bool kHideDirectHistory = Platform.isIOS;

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
