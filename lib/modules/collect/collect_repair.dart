import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_module.dart';

/// [my新增] 直连源收藏的识别与收藏分区修复。
///
/// 源直连页创建的收藏必然属于里番区 (收集时固定 section=1):
/// - 匹配到 bgm 条目时 id 为真实条目 id, info 为源站播放页 URL;
/// - 未匹配时 id 为稳定哈希 id (0 ~ 2^28-1), info 同样是播放页 URL。
/// Bangumi 接口返回的条目不带 info 字段 (恒为空串), 因此 "info 是
/// http(s) URL" 即可判定来源。旧版 WebDAV 合并 bug 曾把这类条目以
/// section=0 回写本地 (表现为出现在追番页), 这里提供一次性迁回与
/// Bangumi 上传豁免共用的判定。
class CollectSectionRepair {
  CollectSectionRepair._();

  /// 稳定哈希 id 的理论上限为 0xFFFFFFF (约 2.68e8), 真实 bgm 条目
  /// id 目前仅数百万; 取 1e8 作为 info 缺失旧数据的兜底判定。
  static const int _hashIdThreshold = 100000000;

  static bool isDirectSourceItem(BangumiItem item) {
    final info = item.info.trim();
    if (info.startsWith('http://') || info.startsWith('https://')) {
      return true;
    }
    return item.id >= _hashIdThreshold;
  }

  static bool isDirectSourceCollectible(CollectedBangumi collectible) {
    return isDirectSourceItem(collectible.bangumiItem);
  }

  /// 被误记为表番区 (section != 1) 的直连源条目。
  static bool isMisplacedDirectCollectible(CollectedBangumi collectible) {
    return collectible.section != 1 && isDirectSourceCollectible(collectible);
  }

  static List<CollectedBangumi> findMisplacedDirectCollectibles(
    Iterable<CollectedBangumi> collectibles,
  ) {
    return collectibles.where(isMisplacedDirectCollectible).toList()
      ..sort((a, b) => b.time.compareTo(a.time));
  }
}
