import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_dropdown_tile.dart';
import 'package:kazumi/pages/player/controller/player_aspect_ratio.dart';
import 'package:kazumi/pages/settings/low_memory_mode_settings.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/player/pip_utils.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/utils/device.dart';
import 'package:kazumi/services/skip/skip_time_service.dart';

class PlayerSettingsPage extends StatefulWidget {
  const PlayerSettingsPage({super.key});

  @override
  State<PlayerSettingsPage> createState() => _PlayerSettingsPageState();
}

class _PlayerSettingsPageState extends State<PlayerSettingsPage> {
  static const double _minPlayerControllerLayerDisappearSeconds = 1;
  static const double _maxPlayerControllerLayerDisappearSeconds = 10;
  static const int _playerControllerLayerDisappearDivisions = 18;

  late double defaultPlaySpeed;
  late double defaultShortcutForwardPlaySpeed;
  late PlayerAspectRatio defaultAspectRatioMode;
  late bool hAenable;
  late bool androidEnableOpenSLES;
  late bool androidAutoEnterPIP;
  late bool playResume;
  late bool showPlayerError;
  late bool privateMode;

  /// [my新增] 隐藏直连历史 (默认关)
  late bool hideDirectHistory;
  late bool playerDebugMode;
  late bool playerDisableAnimations;
  late bool forceAdBlocker;
  late bool autoPlayNext;
  late bool backgroundPlayback;
  late bool brightnessVolumeGesture;
  late int playerButtonSkipTime;
  late int playerArrowKeySkipTime;
  // [my新增] 自动跳过片头片尾
  late bool autoSkipOpEd;
  late int autoSkipOpManualSeconds;
  late int autoSkipEdManualSeconds;
  late int playerLogLevel;
  late int playerControllerLayerDisappearTime;

  @override
  void initState() {
    super.initState();
    _loadSettingsFromStorage();
  }

  void _loadSettingsFromStorage() {
    defaultPlaySpeed =
        GStorage.getSetting<double>(SettingsKeys.defaultPlaySpeed);
    defaultShortcutForwardPlaySpeed = GStorage.getSetting<double>(
        SettingsKeys.defaultShortcutForwardPlaySpeed);
    defaultAspectRatioMode = PlayerAspectRatio.fromStorageValue(
      GStorage.getSetting<int>(SettingsKeys.defaultAspectRatioType),
    );
    hAenable = GStorage.getSetting<bool>(SettingsKeys.hAenable);
    androidEnableOpenSLES =
        GStorage.getSetting<bool>(SettingsKeys.androidEnableOpenSLES);
    androidAutoEnterPIP =
        GStorage.getSetting<bool>(SettingsKeys.androidAutoEnterPIP);
    playResume = GStorage.getSetting<bool>(SettingsKeys.playResume);
    privateMode = GStorage.getSetting<bool>(SettingsKeys.privateMode);
    hideDirectHistory =
        GStorage.getSetting<bool>(SettingsKeys.hideDirectHistory);
    showPlayerError = GStorage.getSetting<bool>(SettingsKeys.showPlayerError);
    playerDebugMode = GStorage.getSetting<bool>(SettingsKeys.playerDebugMode);
    autoPlayNext = GStorage.getSetting<bool>(SettingsKeys.autoPlayNext);
    backgroundPlayback =
        GStorage.getSetting<bool>(SettingsKeys.backgroundPlayback);
    playerDisableAnimations =
        GStorage.getSetting<bool>(SettingsKeys.playerDisableAnimations);
    forceAdBlocker = GStorage.getSetting<bool>(SettingsKeys.forceAdBlocker);
    playerLogLevel = GStorage.getSetting<int>(SettingsKeys.playerLogLevel);

    brightnessVolumeGesture =
        GStorage.getSetting<bool>(SettingsKeys.brightnessVolumeGesture);

    playerButtonSkipTime =
        GStorage.getSetting<int>(SettingsKeys.buttonSkipTime);
    playerArrowKeySkipTime =
        GStorage.getSetting<int>(SettingsKeys.arrowKeySkipTime);

    // [my新增] 自动跳过片头片尾
    autoSkipOpEd = GStorage.getSetting<bool>(SettingsKeys.autoSkipOpEd);
    autoSkipOpManualSeconds =
        GStorage.getSetting<int>(SettingsKeys.autoSkipOpManualSeconds);
    autoSkipEdManualSeconds =
        GStorage.getSetting<int>(SettingsKeys.autoSkipEdManualSeconds);

    playerControllerLayerDisappearTime = GStorage.getSetting<int>(
        SettingsKeys.playerControllerLayerDisappearTime);
  }

  Future<void> resetPlayerSettings() async {
    final bool shouldReset = await KazumiDialog.show<bool>(
          builder: (context) => AlertDialog(
            title: const Text('恢复默认播放设置'),
            content: const Text('播放设置、硬件解码器、视频渲染器和超分辨率设置将恢复为默认值。'),
            actions: [
              TextButton(
                onPressed: () => KazumiDialog.dismiss(popWith: false),
                child: Text('取消'),
              ),
              TextButton(
                onPressed: () => KazumiDialog.dismiss(popWith: true),
                child: Text('恢复默认'),
              ),
            ],
          ),
        ) ??
        false;
    if (!shouldReset) return;

    await GStorage.resetPlayerSettings();
    if (Platform.isAndroid) {
      await PipUtils.setAndroidAutoEnterPIPEnabled(false);
    }
    if (!mounted) return;
    setState(_loadSettingsFromStorage);
    KazumiDialog.showToast(message: '已恢复默认播放设置');
  }

  void updateDefaultPlaySpeed(double speed) {
    GStorage.putSetting<double>(SettingsKeys.defaultPlaySpeed, speed);
    setState(() {
      defaultPlaySpeed = speed;
    });
  }

  void updateDefaultShortcutForwardPlaySpeed(double speed) {
    GStorage.putSetting<double>(
        SettingsKeys.defaultShortcutForwardPlaySpeed, speed);
    setState(() {
      defaultShortcutForwardPlaySpeed = speed;
    });
  }

  void updatePlayerLogLevel(int level) {
    GStorage.putSetting<int>(SettingsKeys.playerLogLevel, level);
    setState(() {
      playerLogLevel = level;
    });
  }

  void updateDefaultAspectRatioMode(PlayerAspectRatio mode) {
    GStorage.putSetting<int>(
      SettingsKeys.defaultAspectRatioType,
      mode.storageValue,
    );
    setState(() {
      defaultAspectRatioMode = mode;
    });
  }

  // [my新增] 错标黑名单管理: 查看/解除
  Future<void> _showSkipBlacklist() async {
    await KazumiDialog.show(
      builder: (context) {
        var entries =
            SkipTimeService.loadBlacklist().entries.toList();
        return AlertDialog(
          title: Text('错标黑名单 (${entries.length})'),
          content: entries.isEmpty
              ? const Text('空 — 播放时在跳过操作条上点两次可将错标拉黑')
              : SizedBox(
                  width: 400,
                  height: 300,
                  child: StatefulBuilder(
                      builder: (context, setDialogState) {
                    return ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final skipId = entries[index].key;
                        final m = entries[index].value;
                        final type =
                            (m['type'] ?? '').toString() == 'ed' ? 'ED' : 'OP';
                        return ListTile(
                          dense: true,
                          title: Text(
                              '${m['seriesName'] ?? '未知'} 第${m['episode']}集 '
                              '$type ${(m['start'] as num?)?.toInt() ?? 0}'
                              '-${(m['end'] as num?)?.toInt() ?? 0}s',
                              style: const TextStyle(fontSize: 13)),
                          trailing: TextButton(
                            child: const Text('解除'),
                            onPressed: () {
                              SkipTimeService.removeBlacklist(skipId);
                              setDialogState(() {
                                entries.removeWhere(
                                    (e) => e.key == skipId);
                              });
                            },
                          ),
                        );
                      },
                    );
                  }),
                ),
          actions: [
            TextButton(
              onPressed: () => KazumiDialog.dismiss(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  /// [my新增] 跳过镜像编辑: 地址+token 同框填写; 「清除」一键置空两键
  /// 恢复直连/走代理 (存储保持两键, 服务侧零改动)
  Future<void> _editSkipMirror() async {
    final baseController = TextEditingController(
        text: GStorage.getSetting(SettingsKeys.skipMirrorBase));
    final tokenController = TextEditingController(
        text: GStorage.getSetting(SettingsKeys.skipMirrorToken));
    Future<void> save(String base, String token) async {
      await GStorage.putSetting(SettingsKeys.skipMirrorBase, base);
      await GStorage.putSetting(SettingsKeys.skipMirrorToken, token);
      KazumiDialog.dismiss();
      if (mounted) setState(() {});
    }

    await KazumiDialog.show(
      builder: (dialogContext) => AlertDialog(
        title: const Text('跳过数据源镜像', style: TextStyle(fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: baseController,
              decoration: const InputDecoration(
                  labelText: '镜像地址', hintText: 'http://host:31033'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: tokenController,
              decoration: const InputDecoration(
                  labelText: '访问 Token', hintText: '与服务端一致'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => save('', ''),
            child: const Text('清除'),
          ),
          TextButton(
            onPressed: KazumiDialog.dismiss,
            child: Text('取消',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.outline)),
          ),
          TextButton(
            onPressed: () => save(baseController.text.trim(),
                tokenController.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  /// [my新增] 片头/片尾手动跳过秒数 (复用快进时长数字输入对话框)
  Future<void> _updateSkipSeconds({required bool isOp}) async {
    final current = isOp ? autoSkipOpManualSeconds : autoSkipEdManualSeconds;
    final newValue = await _showSkipTimeChangeDialog(
      title: isOp ? '片头手动跳过秒数' : '片尾手动跳过秒数',
      initialValue: current.toString(),
    );
    if (newValue == null) return;
    if (isOp) {
      await GStorage.putSetting<int>(
          SettingsKeys.autoSkipOpManualSeconds, newValue);
      setState(() => autoSkipOpManualSeconds = newValue);
    } else {
      await GStorage.putSetting<int>(
          SettingsKeys.autoSkipEdManualSeconds, newValue);
      setState(() => autoSkipEdManualSeconds = newValue);
    }
  }

  Future<void> updateButtonSkipTime() async {    final int? newButtonSkipTime = await _showSkipTimeChangeDialog(
        title: '顶部按钮快进时长', initialValue: playerButtonSkipTime.toString());

    if (newButtonSkipTime != null &&
        newButtonSkipTime != playerButtonSkipTime) {
      GStorage.putSetting<int>(SettingsKeys.buttonSkipTime, newButtonSkipTime);
      setState(() {
        playerButtonSkipTime = newButtonSkipTime;
      });
    }
  }

  Future<int?> _showSkipTimeChangeDialog(
      {required String title, required String initialValue}) async {
    return KazumiDialog.show<int>(builder: (context) {
      String input = "";
      return AlertDialog(
        title: Text(title),
        content: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
          return TextField(
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
            ],
            decoration: InputDecoration(
              floatingLabelBehavior: FloatingLabelBehavior.never,
              labelText: initialValue,
            ),
            onChanged: (value) {
              input = value;
            },
          );
        }),
        actions: <Widget>[
          TextButton(
            onPressed: () => KazumiDialog.dismiss(),
            child: Text(
              '取消',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ),
          TextButton(
            onPressed: () async {
              final int? newValue = int.tryParse(input);

              if (newValue == null) {
                KazumiDialog.showToast(message: '请输入数字');
                return;
              }

              if (newValue <= 0) {
                KazumiDialog.showToast(message: '请输入大于0的数字');
                return;
              }
              KazumiDialog.dismiss(popWith: newValue);
            },
            child: const Text('确定'),
          ),
        ],
      );
    });
  }

  double get playerControllerLayerDisappearSeconds =>
      (playerControllerLayerDisappearTime / Duration.millisecondsPerSecond)
          .clamp(_minPlayerControllerLayerDisappearSeconds,
              _maxPlayerControllerLayerDisappearSeconds)
          .toDouble();

  String formatPlayerControllerLayerDisappearSeconds(double seconds) {
    if (seconds == seconds.roundToDouble()) {
      return '${seconds.toInt()} 秒';
    }
    return '${seconds.toStringAsFixed(1)} 秒';
  }

  void updatePlayerControllerLayerDisappearSeconds(double seconds) {
    final int newDisappearTime =
        (seconds * Duration.millisecondsPerSecond).round();
    if (newDisappearTime == playerControllerLayerDisappearTime) {
      return;
    }
    GStorage.putSetting<int>(
        SettingsKeys.playerControllerLayerDisappearTime, newDisappearTime);
    setState(() {
      playerControllerLayerDisappearTime = newDisappearTime;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SettingsDetailScaffold(
      title: const Text('播放设置'),
      body: SettingsList(
        sections: [
          SettingsSection(
            title: Text('解码与渲染'),
            tiles: [
              SettingsTile.switchTile(
                leading: Icons.memory_rounded,
                onToggle: (value) async {
                  hAenable = value ?? !hAenable;
                  await GStorage.putSetting<bool>(
                      SettingsKeys.hAenable, hAenable);
                  setState(() {});
                },
                title: Text('硬件解码'),
                initialValue: hAenable,
              ),
              SettingsTile(
                leading: Icons.developer_board_rounded,
                onPressed: (_) async {
                  await context.pushNamed('/settings/player/decoder');
                },
                title: Text('硬件解码器'),
                description: Text('仅在硬件解码启用时生效'),
              ),
              if (Platform.isAndroid) ...[
                SettingsTile(
                  leading: Icons.tv_rounded,
                  onPressed: (_) async {
                    await context.pushNamed('/settings/player/renderer');
                  },
                  title: Text('视频渲染器'),
                  description: Text('选择视频输出方式'),
                ),
              ],
              const LowMemoryModeSettingsTile(),
              if (Platform.isAndroid) ...[
                SettingsTile.switchTile(
                  leading: Icons.graphic_eq_rounded,
                  onToggle: (value) async {
                    androidEnableOpenSLES = value ?? !androidEnableOpenSLES;
                    await GStorage.putSetting<bool>(
                        SettingsKeys.androidEnableOpenSLES,
                        androidEnableOpenSLES);
                    setState(() {});
                  },
                  title: Text('低延迟音频'),
                  description: Text('启用OpenSLES音频输出以降低延时'),
                  initialValue: androidEnableOpenSLES,
                ),
              ],
              SettingsTile(
                leading: Icons.auto_awesome_rounded,
                onPressed: (_) async {
                  context.pushNamed('/settings/player/super');
                },
                title: Text('超分辨率'),
              ),
            ],
          ),
          SettingsSection(
            title: Text('播放行为'),
            tiles: [
              SettingsTile.switchTile(
                leading: Icons.headphones_rounded,
                onToggle: (value) async {
                  backgroundPlayback = value ?? !backgroundPlayback;
                  await GStorage.putSetting<bool>(
                      SettingsKeys.backgroundPlayback, backgroundPlayback);
                  setState(() {});
                },
                title: Text('后台播放'),
                description: Text('应用退到后台或熄屏时继续播放音频'),
                initialValue: backgroundPlayback,
              ),
              SettingsTile.switchTile(
                leading: Icons.history_rounded,
                onToggle: (value) async {
                  playResume = value ?? !playResume;
                  await GStorage.putSetting<bool>(
                      SettingsKeys.playResume, playResume);
                  setState(() {});
                },
                title: Text('自动跳转'),
                description: Text('跳转到上次播放位置'),
                initialValue: playResume,
              ),
              SettingsTile.switchTile(
                leading: Icons.playlist_play_rounded,
                onToggle: (value) async {
                  autoPlayNext = value ?? !autoPlayNext;
                  await GStorage.putSetting<bool>(
                      SettingsKeys.autoPlayNext, autoPlayNext);
                  setState(() {});
                },
                title: Text('自动连播'),
                description: Text('当前视频播放完毕后自动播放下一集'),
                initialValue: autoPlayNext,
              ),
              // [my新增] 自动跳过片头片尾: 社区数据 (aniskip) 优先, 无数据
              // 回退手动秒数 (0 = 不跳)
              SettingsTile.switchTile(
                leading: Icons.skip_next_rounded,
                onToggle: (value) async {
                  autoSkipOpEd = value ?? !autoSkipOpEd;
                  await GStorage.putSetting<bool>(
                      SettingsKeys.autoSkipOpEd, autoSkipOpEd);
                  setState(() {});
                },
                title: Text('自动跳过片头片尾'),
                description:
                    Text('播放到社区数据的片头/片尾区间时自动跳过 (Syncplay 会话中不生效)'),
                initialValue: autoSkipOpEd,
              ),
              SettingsTile(
                leading: Icons.slow_motion_video_rounded,
                onPressed: (_) => _updateSkipSeconds(isOp: true),
                title: Text('片头手动跳过秒数'),
                description: Text('无社区数据时自动跳过开头 N 秒 (当前: '
                    '$autoSkipOpManualSeconds 秒, 0 为不跳)'),
              ),
              SettingsTile(
                leading: Icons.fast_forward_rounded,
                onPressed: (_) => _updateSkipSeconds(isOp: false),
                title: Text('片尾手动跳过秒数'),
                description: Text('无社区数据时跳过结尾 N 秒 (当前: '
                    '$autoSkipEdManualSeconds 秒, 0 为不跳)'),
              ),
              // [my新增] 错标黑名单管理
              SettingsTile(
                leading: Icons.block_rounded,
                onPressed: (_) => _showSkipBlacklist(),
                title: Text('错标黑名单 (${SkipTimeService.loadBlacklist().length})'),
                description: const Text(
                    '播放时在跳过操作条上拉黑的错误区间 (点击解除恢复自动跳过)'),
              ),
              // [my新增] 自建镜像 (iOS 无代理环境): 地址+token 同框填写,
              // 三端通用; 清除/留空维持直连/走代理
              SettingsTile(
                leading: Icons.dns_rounded,
                onPressed: (_) => _editSkipMirror(),
                title: Text('跳过数据源镜像'),
                description: Text(() {
                  final base =
                      GStorage.getSetting(SettingsKeys.skipMirrorBase);
                  return base.isEmpty
                      ? '留空=直连/走代理 (iOS 无代理环境可填自建镜像)'
                      : '已配置: $base';
                }()),
              ),
              if (Platform.isAndroid)
                SettingsTile.switchTile(
                  leading: Icons.picture_in_picture_alt_rounded,
                  onToggle: (value) async {
                    androidAutoEnterPIP = value ?? !androidAutoEnterPIP;
                    await GStorage.putSetting<bool>(
                        SettingsKeys.androidAutoEnterPIP, androidAutoEnterPIP);
                    await PipUtils.setAndroidAutoEnterPIPEnabled(
                        androidAutoEnterPIP);
                    setState(() {});
                  },
                  title: Text('自动进入画中画'),
                  description: Text('切到后台时，自动进入画中画'),
                  initialValue: androidAutoEnterPIP,
                ),
              SettingsTile.switchTile(
                leading: Icons.block_rounded,
                onToggle: (value) async {
                  forceAdBlocker = value ?? !forceAdBlocker;
                  await GStorage.putSetting<bool>(
                      SettingsKeys.forceAdBlocker, forceAdBlocker);
                  setState(() {});
                },
                title: Text('广告过滤'),
                description: Text('强制启用HLS广告过滤，忽略规则设置'),
                initialValue: forceAdBlocker,
              ),
              SettingsTile.switchTile(
                leading: Icons.animation_rounded,
                onToggle: (value) async {
                  playerDisableAnimations = value ?? !playerDisableAnimations;
                  await GStorage.putSetting<bool>(
                      SettingsKeys.playerDisableAnimations,
                      playerDisableAnimations);
                  setState(() {});
                },
                title: Text('禁用动画'),
                description: Text('禁用播放器内的过渡动画'),
                initialValue: playerDisableAnimations,
              ),
              if (!isDesktop())
                SettingsTile.switchTile(
                  leading: Icons.swipe_vertical_rounded,
                  onToggle: (value) async {
                    brightnessVolumeGesture = value ?? !brightnessVolumeGesture;
                    await GStorage.putSetting<bool>(
                        SettingsKeys.brightnessVolumeGesture,
                        brightnessVolumeGesture);
                    setState(() {});
                  },
                  title: Text('滑动手势'),
                  description: Text('竖向滑动调节音量和亮度'),
                  initialValue: brightnessVolumeGesture,
                ),
              SettingsTile.switchTile(
                leading: Icons.visibility_off_rounded,
                onToggle: (value) async {
                  privateMode = value ?? !privateMode;
                  await GStorage.putSetting<bool>(
                      SettingsKeys.privateMode, privateMode);
                  setState(() {});
                },
                title: Text('隐身模式'),
                description: Text('不保留观看记录'),
                initialValue: privateMode,
              ),
              // [my新增] 隐藏直连历史: 三档过滤 + 直连档隐藏 (双平台)
              // [my调整] iOS 恒隐藏直连条目 (kSupportsR18Tabs=false 即无直连
              // 来源), 开关无意义不显示
              if (kSupportsR18Tabs)
                SettingsTile.switchTile(
                  leading: Icons.hide_image_outlined,
                  onToggle: (value) async {
                    hideDirectHistory = value ?? !hideDirectHistory;
                    await GStorage.putSetting<bool>(
                        SettingsKeys.hideDirectHistory, hideDirectHistory);
                    setState(() {});
                  },
                  title: Text('隐藏直连历史'),
                  description: Text(
                      '历史页不显示源直连来源的观看记录 (含全部/在线/缓存视图)'),
                  initialValue: hideDirectHistory,
                ),
            ],
          ),
          SettingsSection(
            title: Text('诊断'),
            tiles: [
              SettingsTile.switchTile(
                leading: Icons.error_outline_rounded,
                onToggle: (value) async {
                  showPlayerError = value ?? !showPlayerError;
                  await GStorage.putSetting<bool>(
                      SettingsKeys.showPlayerError, showPlayerError);
                  setState(() {});
                },
                title: Text('错误提示'),
                description: Text('显示播放器内部错误提示'),
                initialValue: showPlayerError,
              ),
              SettingsTile.switchTile(
                leading: Icons.bug_report_rounded,
                onToggle: (value) async {
                  playerDebugMode = value ?? !playerDebugMode;
                  await GStorage.putSetting<bool>(
                      SettingsKeys.playerDebugMode, playerDebugMode);
                  setState(() {});
                },
                title: Text('调试模式'),
                description: Text('记录播放器内部日志'),
                initialValue: playerDebugMode,
              ),
              SettingsDropdownTile<int>(
                leading: Icons.receipt_long_rounded,
                title: const Text('日志等级'),
                description: const Text('播放器内部日志等级'),
                value: playerLogLevel,
                options: playerLogLevelMap,
                fallbackLabel: '???',
                onChanged: updatePlayerLogLevel,
              ),
            ],
          ),
          SettingsSection(
            title: Text('播放参数'),
            tiles: [
              SettingsSliderTile(
                leading: Icons.speed_rounded,
                title: Text('默认倍速'),
                value: defaultPlaySpeed,
                min: 0.5,
                max: 5,
                divisions: 18,
                valueLabel: '${defaultPlaySpeed}x',
                onChanged: (value) => updateDefaultPlaySpeed(
                    double.parse(value.toStringAsFixed(2))),
              ),
              SettingsSliderTile(
                leading: Icons.fast_forward_rounded,
                title: Text('长按倍速'),
                description: Text('长按屏幕或按住方向键时的倍速'),
                value: defaultShortcutForwardPlaySpeed,
                min: 1.25,
                max: 3,
                divisions: 7,
                valueLabel: '${defaultShortcutForwardPlaySpeed}x',
                onChanged: (value) => updateDefaultShortcutForwardPlaySpeed(
                    double.parse(value.toStringAsFixed(2))),
              ),
              SettingsSliderTile(
                leading: Icons.swap_horiz_rounded,
                title: Text('方向键跳转'),
                description: Text('左右方向键的快进/快退秒数'),
                value: playerArrowKeySkipTime.toDouble(),
                min: 0,
                max: 15,
                divisions: 15,
                valueLabel: '$playerArrowKeySkipTime 秒',
                onChanged: (value) {
                  final newArrowKeySkipTime = value.toInt();
                  if (newArrowKeySkipTime == playerArrowKeySkipTime) {
                    return;
                  }
                  GStorage.putSetting<int>(
                      SettingsKeys.arrowKeySkipTime, newArrowKeySkipTime);
                  setState(() {
                    playerArrowKeySkipTime = newArrowKeySkipTime;
                  });
                },
              ),
              SettingsTile(
                leading: Icons.skip_next_rounded,
                onPressed: (_) async {
                  await updateButtonSkipTime();
                },
                title: Text('跳过时长'),
                description: Text('顶栏跳过按钮的秒数'),
                value: Text('$playerButtonSkipTime 秒'),
              ),
              SettingsSliderTile(
                leading: Icons.timer_rounded,
                title: Text('控制栏消失时间'),
                description: Text('播放控制器自动隐藏前的停留时长'),
                value: playerControllerLayerDisappearSeconds,
                min: _minPlayerControllerLayerDisappearSeconds,
                max: _maxPlayerControllerLayerDisappearSeconds,
                divisions: _playerControllerLayerDisappearDivisions,
                valueLabel: formatPlayerControllerLayerDisappearSeconds(
                    playerControllerLayerDisappearSeconds),
                onChanged: updatePlayerControllerLayerDisappearSeconds,
              ),
              SettingsDropdownTile<PlayerAspectRatio>(
                leading: Icons.aspect_ratio_rounded,
                title: const Text('默认视频比例'),
                value: defaultAspectRatioMode,
                options: {
                  for (final mode in PlayerAspectRatio.values) mode: mode.label,
                },
                onChanged: updateDefaultAspectRatioMode,
              ),
            ],
          ),
          SettingsSection(
            tiles: [
              SettingsTile(
                leading: Icons.settings_backup_restore_rounded,
                onPressed: (_) => resetPlayerSettings(),
                title: Text('恢复默认设置'),
                description: Text('将播放相关设置恢复为默认值'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
