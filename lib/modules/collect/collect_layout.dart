/// [my升级 v2] 收藏页布局三档: 列表 / 卡片(等高网格) / 瀑布流(交错)。
/// 瀑布流为 opt-in 档, 默认布局维持各自现状 (追番=list / 里番=cards)。
enum CollectLayout {
  list('列表'),
  cards('卡片'),
  waterfall('瀑布流');

  const CollectLayout(this.label);

  final String label;

  static CollectLayout fromValue(String value) {
    if (value == cards.name) return cards;
    if (value == waterfall.name) return waterfall;
    return list;
  }
}
