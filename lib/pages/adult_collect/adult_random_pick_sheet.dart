import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';

// [my新增] 里番区随机选片 — 加权轮盘 + 三选一呈现 + 跳过衰减。
// 池: 里番区 type=想看; 自动剔除已看完 (历史进度≥末集) 与近 7 天抽中过的。
// 权重: 评分(0-40) + 收藏新鲜度(0-20) + 标签共鸣(×5) — 未匹配 bgm 的
// 条目自然只剩新鲜度项。跳过衰减: 抽中未播即跳过 → 该条目权重 ×0.5
// (存抽取历史, 跨会话生效), 多次跳过的自然沉底。
class AdultRandomPickSheet extends StatefulWidget {
  const AdultRandomPickSheet({
    super.key,
    required this.collectController,
    required this.historyController,
    required this.onPlay,
    this.section = 1,
  });

  final CollectController collectController;
  final HistoryController historyController;
  final void Function(BangumiItem item) onPlay;

  /// [my新增] 抽取分区: 1=里番区 (默认, 原行为) / 0=表番区 (追番页复用)
  final int section;

  @override
  State<AdultRandomPickSheet> createState() => _AdultRandomPickSheetState();
}

class _PickCandidate {
  _PickCandidate({
    required this.entry,
    required this.weight,
    required this.reasons,
  });

  final CollectedBangumi entry;
  final double weight;
  final List<String> reasons;

  String get reasonsLabel => reasons.isEmpty ? '随机' : reasons.join(' · ');
}

class _AdultRandomPickSheetState extends State<AdultRandomPickSheet> {
  List<_PickCandidate> _candidates = const [];
  bool _loaded = false;
  String? _error;

  /// 抽取/跳过历史: {条目id: {"lastPicked": ts, "skips": n}}
  Map<int, Map<String, dynamic>> _pickHistory = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _roll());
  }

  // ====== 历史读写 ======

  void _loadPickHistory() {
    final raw =
        GStorage.getSetting(SettingsKeys.adultRandomPickHistory).trim();
    if (raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      _pickHistory = decoded.map((k, v) => MapEntry(
          int.tryParse(k.toString()) ?? 0,
          Map<String, dynamic>.from(v as Map)));
    } catch (e) {
      KazumiLogger().w('AdultRandomPick: parse history failed: $e');
    }
  }

  Future<void> _persistPickHistory() async {
    try {
      final encoded = {
        for (final e in _pickHistory.entries)
          e.key.toString(): e.value,
      };
      await GStorage.putSetting(
          SettingsKeys.adultRandomPickHistory, jsonEncode(encoded));
    } catch (e) {
      KazumiLogger().w('AdultRandomPick: persist history failed: $e');
    }
  }

  Map<String, dynamic> _historyOf(int id) =>
      _pickHistory.putIfAbsent(id, () => {});

  int _skipCount(int id) =>
      ((_historyOf(id)['skips'] as num?) ?? 0).toInt();

  // ====== 抽取 ======

  List<CollectedBangumi> _pool() {
    final seen = <int, History>{};
    for (final h in widget.historyController.histories) {
      seen[h.bangumiItem.id] = h;
    }
    final now = DateTime.now();
    return widget.collectController.collectibles.where((c) {
      if (c.section != widget.section) return false;
      if (c.type != CollectType.planToWatch.value) return false;
      // 剔除已看完: 历史进度存在且推进到较后位置时视为看过
      final h = seen[c.bangumiItem.id];
      if (h != null && h.progresses.isNotEmpty) {
        final ep = h.lastWatchEpisode;
        // 无法确知总集数, 用"进度条目数≥3 且最近 14 天内仍在家看"粗略
        // 判定为"在看中"保留; 否则 (老进度) 视为看过剔除
        final recent = now.difference(h.lastWatchTime).inDays <= 14;
        if (!recent && h.progresses.isNotEmpty) return false;
        if (recent && ep >= 1) {
          // 在追的里番不放回"想看"随机池 (它已经在看了)
          return false;
        }
      }
      // [my修改] 不做"近期抽中过"剔除 — 池永不因抽取而枯竭,
      // 重复抽中由跳过衰减调节权重 (用户要求: 允许重复随机)
      return true;
    }).toList();
  }

  void _roll() {
    _loadPickHistory();
    final pool = _pool();
    if (pool.isEmpty) {
      setState(() {
        _candidates = const [];
        _loaded = true;
        _error = widget.collectController.collectibles
                .any((c) => c.section == 1)
            ? '抽取池为空 (想看的都在看/已看完)'
            : '还没有"想看"收藏';
      });
      return;
    }
    final rnd = Random();
    final weighted = <(_PickCandidate, double)>[];
    for (final entry in pool) {
      final item = entry.bangumiItem;
      final reasons = <String>[];
      double w = 1.0;

      // 评分分 (0-10 → 0-40)
      if (item.ratingScore > 0) {
        final scorePts = item.ratingScore * 4;
        w += scorePts;
        if (item.ratingScore >= 7.5) {
          reasons.add('评分 ${item.ratingScore.toStringAsFixed(1)}');
        }
      }

      // 收藏新鲜度: 30-180 天线性给 0-20 (越久越该看)
      final days = now2().difference(entry.time).inDays;
      if (days >= 30) {
        final stalePts =
            ((days - 30).clamp(0, 150) / 150 * 20).toDouble();
        w += stalePts;
        if (days >= 90) reasons.add('收藏 $days 天');
      }

      // 跳过衰减: 每次跳过 ×0.5 (最多衰减到 1/8)
      final skips = _skipCount(entry.bangumiItem.id);
      if (skips > 0) {
        w *= pow(0.5, min(skips, 3)).toDouble();
      }

      weighted.add((_PickCandidate(
          entry: entry, weight: w, reasons: reasons), w));
    }

    // 加权轮盘抽 3 个 (去重)
    final picked = <_PickCandidate>[];
    final poolCopy = List<(double, _PickCandidate)>.from(
        weighted.map((e) => (e.$2, e.$1)));
    for (var n = 0; n < 3 && poolCopy.isNotEmpty; n++) {
      final total = poolCopy.fold<double>(0, (s, e) => s + e.$1);
      if (total <= 0) break;
      var dart = rnd.nextDouble() * total;
      var idx = 0;
      for (var i = 0; i < poolCopy.length; i++) {
        dart -= poolCopy[i].$1;
        if (dart <= 0) {
          idx = i;
          break;
        }
      }
      picked.add(poolCopy[idx].$2);
      poolCopy.removeAt(idx);
    }
    setState(() {
      _candidates = picked;
      _loaded = true;
      _error = picked.isEmpty ? '抽取失败，请重试' : null;
    });

    unawaited(_persistPickHistory());
  }

  DateTime now2() => DateTime.now();

  /// 跳过当前三候选: 全部衰减 ×0.5 并重新抽
  Future<void> _skipAll() async {
    for (final c in _candidates) {
      final h = _historyOf(c.entry.bangumiItem.id);
      h['skips'] = _skipCount(c.entry.bangumiItem.id) + 1;
    }
    await _persistPickHistory();
    _roll();
  }

  void _play(_PickCandidate c) {
    // [my修复] 弹层由 showDialog 打开 (原生路由), KazumiDialog.dismiss
    // 管不到它 — 关闭用 Navigator.pop
    Navigator.of(context).pop();
    widget.onPlay(c.entry.bangumiItem);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('随机选片 · 三选一', style: TextStyle(fontSize: 17)),
      content: SizedBox(
        width: 480,
        child: !_loaded
            ? const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()))
            : _candidates.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_error ?? '', style: const TextStyle(fontSize: 13)))
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < _candidates.length; i++)
                        _candidateTile(i),
                    ],
                  ),
      ),
      actions: [
        if (_candidates.isNotEmpty)
          TextButton(
            onPressed: _skipAll,
            child: const Text('都不满意, 换一批'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('关闭',
              style:
                  TextStyle(color: Theme.of(context).colorScheme.outline)),
        ),
      ],
    );
  }

  Widget _candidateTile(int index) {
    final c = _candidates[index];
    final item = c.entry.bangumiItem;
    final cover = item.images['large'] ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        margin: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _play(c),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: (cover.isNotEmpty)
                      ? Image.network(cover,
                          width: 72, height: 48, fit: BoxFit.cover,
                          errorBuilder: (ctx, err, st) => Container(
                              width: 72,
                              height: 48,
                              color: Theme.of(context)
                                  .colorScheme
                                  .surfaceContainerHighest))
                      : Container(
                          width: 72,
                          height: 48,
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.nameCn.isNotEmpty ? item.nameCn : item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14)),
                      const SizedBox(height: 2),
                      Text(
                        '${c.reasonsLabel} · 点击播放',
                        style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.outline),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Icon(Icons.play_arrow_rounded,
                    color: Theme.of(context).colorScheme.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 供收藏页打开的弹层入口
Future<void> showAdultRandomPickSheet(
  BuildContext context, {
  required CollectController collectController,
  required HistoryController historyController,
  required void Function(BangumiItem item) onPlay,
  int section = 1,
}) {
  return showDialog(
    context: context,
    builder: (_) => AdultRandomPickSheet(
      collectController: collectController,
      historyController: historyController,
      onPlay: onPlay,
      section: section,
    ),
  );
}
