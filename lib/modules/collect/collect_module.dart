import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_type.dart';

part 'collect_module.g.dart';

@HiveType(typeId: 3)
class CollectedBangumi {
  @HiveField(0)
  BangumiItem bangumiItem;

  @HiveField(1)
  DateTime time;

  /// Refer to [CollectType]
  // 1. 在看
  // 2. 想看
  // 3. 搁置
  // 4. 看过
  // 5. 抛弃
  @HiveField(2)
  int type;

  /// [my新增] 收藏分区: 0=表番 (默认, 可同步 Bangumi) / 1=里番区
  /// (纯本地+WebDAV, 永不上传 Bangumi)。旧数据无此字段读取时归 0。
  @HiveField(3)
  int section;

  String get key => bangumiItem.id.toString();

  CollectedBangumi(this.bangumiItem, this.time, this.type,
      {this.section = 0});

  static String getKey(BangumiItem bangumiItem) => bangumiItem.id.toString();

  @override
  String toString() {
    return 'type: $type, time: $time, section: $section, anime: ${bangumiItem.name}';
  }
}
