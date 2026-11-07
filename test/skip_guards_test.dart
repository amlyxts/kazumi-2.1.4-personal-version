// [my新增] 跳过守门单测 — 长度 210s / 跨度 40% / 黑名单 / 模板标记。
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/skip/skip_time_service.dart';

SkipInterval _iv(String type, double start, double end,
        {String skipId = '', bool isTemplate = false}) =>
    SkipInterval(
        type: type, start: start, end: end, skipId: skipId, isTemplate: isTemplate);

void main() {
  group('SkipTimeService.applyGuards', () {
    test('长度 >210s 丢弃 (数据驱动: 310 条真实样本 max=179.4s)', () {
      final r = SkipTimeService.applyGuards([
        _iv('op', 0, 90),
        _iv('op', 0, 179.4),
        _iv('op', 0, 210.1),
        _iv('ed', 1300, 1490),
      ], episodeLengthSec: 1420);
      expect(r.length, 3);
      expect(r.any((e) => e.end == 210.1), isFalse);
    });

    test('跨度 >40% 片长丢弃 (短剧集场景)', () {
      // 300×0.4 = 120s: 110s 保留 (长度门 210 内), 130s 被跨度门丢弃
      final r = SkipTimeService.applyGuards([
        _iv('op', 0, 110),
        _iv('op', 0, 130),
      ], episodeLengthSec: 300);
      expect(r.length, 1);
      expect(r.first.end, 110);
    });

    test('黑名单按 skipId 精确过滤, 其余不受影响', () {
      final r = SkipTimeService.applyGuards([
        _iv('op', 0, 90, skipId: 'bad-uuid'),
        _iv('ed', 1300, 1400, skipId: 'good-uuid'),
        _iv('op', 0, 85), // 无 skipId 的不受黑名单影响
      ],
          episodeLengthSec: 1420,
          blacklist: {'bad-uuid'});
      expect(r.length, 2);
      expect(r.any((e) => e.skipId == 'bad-uuid'), isFalse);
    });

    test('模板标记透传 (不丢弃, 供日志/学习排除)', () {
      final r = SkipTimeService.applyGuards([
        _iv('op', 0, 90, skipId: 't1', isTemplate: true),
      ], episodeLengthSec: 1420);
      expect(r.length, 1);
      expect(r.first.isTemplate, isTrue);
    });
  });
}
