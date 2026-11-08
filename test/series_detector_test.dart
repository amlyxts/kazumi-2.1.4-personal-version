import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/pages/direct_search/series_detector.dart';

Road _road(List<(String, String)> chapters) => Road(
      name: '播放线路1',
      data: [for (final (u, _) in chapters) u],
      identifier: [for (final (_, t) in chapters) t],
    );

void main() {
  group('SeriesDetector', () {
    test('detects series, anchors oldest episode, strips episode marker',
        () {
      final result = SeriesDetector.detect([
        _road([
          ('https://x.me/watch?v=408844', '作品名 第4话'),
          ('https://x.me/watch?v=408600', '作品名 第3话'),
          ('https://x.me/watch?v=408300', '作品名 第2话'),
          ('https://x.me/watch?v=408100', '作品名 第1话'),
        ]),
      ]);

      expect(result.isSeries, isTrue);
      expect(result.anchorUrl, 'https://x.me/watch?v=408100');
      expect(result.seriesName, '作品名');
      expect(result.chapterCount, 4);
    });

    test('deduplicates desktop/mobile DOM rows', () {
      final chapters = [
        ('https://x.me/watch?v=408844', '作品名 第2话'),
        ('https://x.me/watch?v=408100', '作品名 第1话'),
      ];
      final result = SeriesDetector.detect([
        _road([...chapters, ...chapters]),
      ]);

      expect(result.isSeries, isTrue);
      expect(result.chapterCount, 2);
      expect(result.anchorUrl, 'https://x.me/watch?v=408100');
    });

    test('rejects recommendation streams (unrelated titles)', () {
      final result = SeriesDetector.detect([
        _road([
          ('https://x.me/watch?v=900001', '深夜便利店的故事'),
          ('https://x.me/watch?v=900002', '剑与魔法学院'),
          ('https://x.me/watch?v=900003', '深海潜艇档案'),
          ('https://x.me/watch?v=900004', '办公室恋爱日常'),
          ('https://x.me/watch?v=900005', '异世界转生指南'),
          ('https://x.me/watch?v=900006', '猫咪咖啡馆'),
        ]),
      ]);

      expect(result.isSeries, isFalse);
    });

    test('single chapter is not a series', () {
      final result = SeriesDetector.detect([
        _road([('https://x.me/watch?v=408844', '某个单集作品')]),
      ]);

      expect(result.isSeries, isFalse);
    });

    test('empty roads are not a series', () {
      expect(SeriesDetector.detect(const []).isSeries, isFalse);
    });

    test('anchors oldest even when min id is not last', () {
      final result = SeriesDetector.detect([
        _road([
          ('https://x.me/watch?v=408100', '作品名 第1话'),
          ('https://x.me/watch?v=408844', '作品名 第2话'),
        ]),
      ]);

      expect(result.anchorUrl, 'https://x.me/watch?v=408100');
    });

    test('falls back to last chapter when urls carry no numeric param', () {
      final result = SeriesDetector.detect([
        _road([
          ('https://x.me/play/season-2-ep-9', '作品名 後編'),
          ('https://x.me/play/season-2-ep-8', '作品名 前編'),
        ]),
      ]);

      expect(result.isSeries, isTrue);
      expect(result.anchorUrl, 'https://x.me/play/season-2-ep-8');
    });

    test('series name strips truncated digits from common prefix', () {
      // 最长公共前缀在 "第1" 处截断 (第1话 vs 第10话)
      final result = SeriesDetector.detect([
        _road([
          ('https://x.me/watch?v=408844', '作品名 第10话'),
          ('https://x.me/watch?v=408100', '作品名 第1话'),
        ]),
      ]);

      expect(result.isSeries, isTrue);
      expect(result.seriesName, '作品名');
    });

    test('boundary ratio at threshold still detects series', () {
      final result = SeriesDetector.detect([
        _road([
          ('https://x.me/watch?v=2', 'ABCDEF 第2话'),
          ('https://x.me/watch?v=1', 'ABCDEF 第1话'),
        ]),
      ]);

      expect(result.isSeries, isTrue);
    });
  });

  group('SeriesDetector.namingName', () {
    test('strips quantified episode markers for entry naming', () {
      expect(SeriesDetector.namingName('作品名 第2话'), '作品名');
      expect(SeriesDetector.namingName('作品名 後編'), '作品名');
      expect(SeriesDetector.namingName('作品名 PART3'), '作品名');
      expect(SeriesDetector.namingName('作品名【2】'), '作品名');
      expect(SeriesDetector.namingName('作品名 その3'), '作品名');
      expect(SeriesDetector.namingName('作品名 第10回'), '作品名');
      expect(SeriesDetector.namingName('[中文字幕] 作品名 第1话'), '[中文字幕] 作品名');
    });

    test('keeps bare digits and pure titles (naming must stay accurate)', () {
      expect(SeriesDetector.namingName('作品名2'), '作品名2');
      expect(SeriesDetector.namingName('作品名 2'), '作品名 2');
      expect(SeriesDetector.namingName('作品名：温泉篇'), '作品名：温泉篇');
      expect(SeriesDetector.namingName('2012'), '2012');
      expect(SeriesDetector.namingName('第2话'), '第2话');
      expect(SeriesDetector.namingName(''), '');
    });
  });

  group('SeriesDetector.sameSeriesName', () {
    test('matches old single-episode names and subtitle variants', () {
      expect(SeriesDetector.sameSeriesName('作品名', '作品名 第2话'), isTrue);
      expect(SeriesDetector.sameSeriesName('作品名', '作品名：温泉篇'), isTrue);
      expect(SeriesDetector.sameSeriesName('作品名', '作品名'), isTrue);
    });

    test('matches bare trailing digit numbering (site convention)', () {
      expect(SeriesDetector.sameSeriesName('作品名1', '作品名2'), isTrue);
      expect(SeriesDetector.sameSeriesName('作品名', '作品名 2'), isTrue);
      expect(SeriesDetector.sameSeriesName('作品名', '作品名２'), isTrue);
      expect(SeriesDetector.sameSeriesName('某系列 第1回', '某系列 第2回'), isTrue);
    });

    test('does not match unrelated names or latin suffix variants', () {
      expect(SeriesDetector.sameSeriesName('作品名', '完全不同的一部作品'), isFalse);
      expect(SeriesDetector.sameSeriesName('作品名', '作品名R'), isFalse);
      expect(SeriesDetector.sameSeriesName('作品名', '作品名OVA'), isFalse);
      expect(SeriesDetector.sameSeriesName('', '作品名'), isFalse);
    });
  });

  group('SeriesDetector.displayNameParts (display-layer bare digit strip)', () {
    test('strips bare trailing digits with separator and reports episode', () {
      expect(SeriesDetector.displayNameParts('作品名 2'), ('作品名', 2));
      expect(SeriesDetector.displayNameParts('作品名2'), ('作品名', 2));
      expect(SeriesDetector.displayNameParts('作品名－3'), ('作品名', 3));
      expect(SeriesDetector.displayNameParts('作品名 １２'), ('作品名', 12));
    });

    test('keeps names without bare trailing digits', () {
      expect(SeriesDetector.displayNameParts('作品名'), ('作品名', null));
      expect(SeriesDetector.displayNameParts('作品名 第2话'), ('作品名 第2话', null));
      expect(SeriesDetector.displayNameParts('作品名 2nd'), ('作品名 2nd', null));
      expect(SeriesDetector.displayNameParts('作品名 2024'), ('作品名 2024', null));
    });

    test('does not strip when base would be too short', () {
      expect(SeriesDetector.displayNameParts('24'), ('24', null));
      expect(SeriesDetector.displayNameParts('X 5'), ('X 5', null));
    });

    test('does not touch matching-layer behavior', () {
      // 剥显与匹配解耦: "名 2" 显示剥成 ("名",2) 但 sameSeriesName 口径不变
      expect(SeriesDetector.sameSeriesName('作品名', '作品名 2'), isTrue);
      expect(SeriesDetector.displayNameParts(' 作品名 2 '), ('作品名', 2));
    });
  });
}
