import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';

import 'package:kazumi/bean/dialog/adaptive_bottom_sheet.dart';
import 'package:kazumi/bean/dialog/material_bottom_sheet.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/bean/widget/connected_tabs.dart';
import 'package:kazumi/bean/widget/content_section.dart';
import 'package:kazumi/pages/settings/danmaku/danmaku_ch_convert_tile.dart';
import 'package:kazumi/pages/settings/danmaku/danmaku_shield_settings_sheet.dart';
import 'package:kazumi/pages/settings/danmaku/danmaku_time_offset_sheet.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/services/danmaku/danmaku_alignment_service.dart';
import 'package:kazumi/services/storage/storage.dart';

enum _DanmakuSettingsDestination {
  timeOffset,
  shield,
}

Future<void> showDanmakuSettingsSheet({
  required BuildContext context,
  required DanmakuController danmakuController,
  required VoidCallback onUpdateDanmakuSpeed,
  VoidCallback? onTimelineOffsetChanged,
}) async {
  final destination =
      await showAdaptiveBottomSheet<_DanmakuSettingsDestination>(
    context: context,
    builder: (context) {
      return _DanmakuSettingsSheet(
        danmakuController: danmakuController,
        onUpdateDanmakuSpeed: onUpdateDanmakuSpeed,
      );
    },
  );

  if (!context.mounted || destination == null) return;
  await showAdaptiveBottomSheet<void>(
    context: context,
    builder: (context) => switch (destination) {
      _DanmakuSettingsDestination.shield => const DanmakuShieldSettingsSheet(),
      _DanmakuSettingsDestination.timeOffset => DanmakuTimeOffsetSheet(
          onTimelineOffsetChanged: onTimelineOffsetChanged,
        ),
    },
  );
}

class _DanmakuSettingsSheet extends StatefulWidget {
  final DanmakuController danmakuController;
  final VoidCallback onUpdateDanmakuSpeed;

  const _DanmakuSettingsSheet({
    required this.danmakuController,
    required this.onUpdateDanmakuSpeed,
  });

  @override
  State<_DanmakuSettingsSheet> createState() => _DanmakuSettingsSheetState();
}

class _DanmakuSettingsSheetState extends State<_DanmakuSettingsSheet> {
  // The slider uses stored duration, before playback speed scales it.
  late double _duration;

  DanmakuOption get _option => widget.danmakuController.option;

  @override
  void initState() {
    super.initState();
    _duration = GStorage.getSetting(SettingsKeys.danmakuDuration);
  }

  Widget _buildMatchStatusTile(BuildContext context) {
    final match = DanmakuAlignmentService.instance.lastMatch;
    if (match == null) {
      return const ListTile(
        dense: true,
        title: Text('当前集：未加载弹幕', style: TextStyle(fontSize: 13)),
        subtitle: Text('开始播放后此处显示匹配来源', style: TextStyle(fontSize: 11)),
      );
    }
    final isSuspect = match.source == 'suspect';
    final isInferred = match.source == 'inferred';
    return ListTile(
      dense: true,
      leading: Icon(
        isSuspect
            ? Icons.warning_amber_rounded
            : isInferred
                ? Icons.auto_awesome_rounded
                : Icons.verified_rounded,
        size: 20,
        color: isSuspect
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).colorScheme.primary,
      ),
      title: Text(
        '当前集：${match.sourceLabel}'
        '${match.episodeTitle != null && match.episodeTitle!.isNotEmpty ? ' · ${match.episodeTitle}' : ''}',
        style: const TextStyle(fontSize: 13),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        isSuspect
            ? (match.note ?? '自动命中非正片条目, 建议用「弹幕切换」手动匹配')
            : isInferred
                ? '由锚点推断 — 如有误请手动匹配一次即纠正'
                : '第 ${match.srcEp} 集 · ${match.pluginName}',
        style: const TextStyle(fontSize: 11),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: isInferred && match.episodeId != null
          ? TextButton(
              onPressed: () async {
                await DanmakuAlignmentService.instance.writeAnchor(
                  match.bgmId,
                  match.pluginName,
                  match.srcEp,
                  match.episodeId!,
                  match.episodeTitle ?? '',
                );
                if (context.mounted) {
                  setState(() {});
                  KazumiDialog.showToast(message: '已确认, 本集起为锚点匹配');
                }
              },
              child: const Text('确认'),
            )
          : null,
    );
  }

  void _applyOption(DanmakuOption option) {
    setState(() => widget.danmakuController.updateOption(option));
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          MaterialBottomSheetHeader(
            title: '弹幕设置',
            onClose: () => Navigator.of(context).pop(),
          ),
          const ConnectedTabs(
              padding: materialBottomSheetTabsPadding, labels: ['外观', '播放']),
          Expanded(
              child: TabBarView(children: [
            ListView(
              key: const PageStorageKey('danmaku-appearance'),
              padding: materialBottomSheetContentPadding,
              children: [
                // [my新增] 当前集弹幕匹配状态: 锚点/推断可确认转正,
                // 疑似错配提示手动处理 (机制见 DanmakuAlignmentService)
                ContentSection.group(title: '弹幕匹配', children: [
                  _buildMatchStatusTile(context),
                ]),
                ContentSection.group(title: '显示效果', children: [
                  SettingsSliderTile(
                    title: Text('字体大小'),
                    value: _option.fontSize,
                    min: 10,
                    max: 48,
                    valueLabel: '${_option.fontSize.floor()}',
                    onChanged: (value) {
                      final fontSize = value.floorToDouble();
                      _applyOption(_option.copyWith(fontSize: fontSize));
                      GStorage.putSetting<double>(
                          SettingsKeys.danmakuFontSize, fontSize);
                    },
                  ),
                  SettingsSliderTile(
                    title: Text('不透明度'),
                    value: _option.opacity,
                    min: 0.1,
                    max: 1,
                    valueLabel: '${(_option.opacity * 100).round()}%',
                    onChanged: (value) {
                      _applyOption(_option.copyWith(opacity: value));
                      GStorage.putSetting<double>(SettingsKeys.danmakuOpacity,
                          double.parse(value.toStringAsFixed(2)));
                    },
                  ),
                  SettingsSliderTile(
                    title: Text('显示区域'),
                    value: _option.area,
                    min: 0,
                    max: 1,
                    divisions: 8,
                    valueLabel: '${(_option.area * 100).round()}%',
                    onChanged: (value) {
                      _applyOption(_option.copyWith(area: value));
                      GStorage.putSetting<double>(
                          SettingsKeys.danmakuArea, value);
                    },
                  ),
                  SettingsSliderTile(
                    title: Text('行间距'),
                    value: _option.lineHeight,
                    min: 0,
                    max: 3,
                    divisions: 30,
                    valueLabel: _option.lineHeight.toStringAsFixed(1),
                    onChanged: (value) {
                      final lineHeight = double.parse(value.toStringAsFixed(1));
                      _applyOption(_option.copyWith(lineHeight: lineHeight));
                      GStorage.putSetting<double>(
                          SettingsKeys.danmakuLineHeight, lineHeight);
                    },
                  ),
                ]),
                const SizedBox(height: 24),
                ContentSection(
                  title: '弹幕类型',
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    _typeChip('滚动', !_option.hideScroll, (show) {
                      _applyOption(_option.copyWith(hideScroll: !show));
                      GStorage.putSetting<bool>(
                          SettingsKeys.danmakuScroll, show);
                    }),
                    _typeChip('顶部', !_option.hideTop, (show) {
                      _applyOption(_option.copyWith(hideTop: !show));
                      GStorage.putSetting<bool>(SettingsKeys.danmakuTop, show);
                    }),
                    _typeChip('底部', !_option.hideBottom, (show) {
                      _applyOption(_option.copyWith(hideBottom: !show));
                      GStorage.putSetting<bool>(
                          SettingsKeys.danmakuBottom, show);
                    }),
                  ]),
                ),
              ],
            ),
            ListView(
              key: const PageStorageKey('danmaku-playback'),
              padding: materialBottomSheetContentPadding,
              children: [
                ContentSection.group(title: '速度', children: [
                  SettingsSliderTile(
                    title: Text('停留时间'),
                    value: _duration,
                    min: 2,
                    max: 16,
                    divisions: 14,
                    valueLabel: '${_duration.round()} 秒',
                    onChanged: (value) {
                      final duration = value.roundToDouble();
                      setState(() => _duration = duration);
                      GStorage.putSetting<double>(
                          SettingsKeys.danmakuDuration, duration);
                      widget.onUpdateDanmakuSpeed();
                    },
                  ),
                  SettingsTile.switchTile(
                    onToggle: (value) {
                      bool followSpeed = value ??
                          !GStorage.getSetting<bool>(
                              SettingsKeys.danmakuFollowSpeed);
                      GStorage.putSetting<bool>(
                          SettingsKeys.danmakuFollowSpeed, followSpeed);
                      widget.onUpdateDanmakuSpeed();
                      setState(() {});
                    },
                    title: Text('跟随视频倍速'),
                    initialValue: GStorage.getSetting<bool>(
                        SettingsKeys.danmakuFollowSpeed),
                  ),
                ]),
                const SizedBox(height: 24),
                ContentSection.group(title: '校准与过滤', children: [
                  const DanmakuChConvertTile(),
                  SettingsTile(
                    leading: Icons.sync_rounded,
                    title: const Text('时间校准'),
                    description: Text(formatDanmakuTimeOffset(
                      normalizeDanmakuTimeOffset(GStorage.getSetting<double>(
                          SettingsKeys.danmakuTimeOffset)),
                    )),
                    onPressed: (context) => Navigator.of(context)
                        .pop(_DanmakuSettingsDestination.timeOffset),
                  ),
                  SettingsTile(
                    leading: Icons.filter_alt_outlined,
                    title: const Text('屏蔽规则'),
                    description: const Text('关键词与正则表达式'),
                    onPressed: (context) => Navigator.of(context)
                        .pop(_DanmakuSettingsDestination.shield),
                  ),
                ]),
              ],
            ),
          ])),
        ],
      ),
    );
  }

  Widget _typeChip(String label, bool selected, ValueChanged<bool> onSelected) {
    return FilterChip(
        label: Text(label), selected: selected, onSelected: onSelected);
  }
}
