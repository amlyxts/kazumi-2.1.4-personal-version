import 'package:flutter/material.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/pages/player/controller/player_super_resolution.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/utils/constants.dart';

class SuperResolutionSettings extends StatefulWidget {
  const SuperResolutionSettings({super.key});

  @override
  State<SuperResolutionSettings> createState() =>
      _SuperResolutionSettingsState();
}

class _SuperResolutionSettingsState extends State<SuperResolutionSettings> {
  late bool disableWarning;
  late bool debandEnable;
  late bool motionCompensationEnable;
  late SuperResolutionMode superResolutionMode;

  @override
  void initState() {
    super.initState();
    disableWarning = GStorage.getSetting<bool>(
      SettingsKeys.disableSuperResolutionWarning,
    );
    debandEnable = GStorage.getSetting<bool>(
      SettingsKeys.playerDebandEnable,
    );
    motionCompensationEnable = GStorage.getSetting<bool>(
      SettingsKeys.playerMotionCompensationEnable,
    );
    superResolutionMode = kSupportsSuperResolution
        ? SuperResolutionMode.fromStorageValue(
            GStorage.getSetting<int>(SettingsKeys.defaultSuperResolutionMode),
          )
        : SuperResolutionMode.off;
  }

  @override
  Widget build(BuildContext context) {
    return SettingsDetailScaffold(
      title: const Text('超分辨率'),
      body: SettingsList(
        sections: [
          SettingsRadioSection<SuperResolutionMode>(
            title: Text('超分辨率需要启用硬件解码, 若启用硬件解码后仍然不生效, 尝试切换视频渲染器为 gpu'),
            groupValue: superResolutionMode,
            onChanged: kSupportsSuperResolution
                ? (SuperResolutionMode? value) {
                    if (value == null) return;
                    GStorage.putSetting<int>(
                      SettingsKeys.defaultSuperResolutionMode,
                      value.storageValue,
                    );
                    setState(() {
                      superResolutionMode = value;
                    });
                  }
                : (SuperResolutionMode? value) {},
            tiles: [
              for (final mode in SuperResolutionMode.values)
                SettingsTile<SuperResolutionMode>.radioTile(
                  title: Text(mode.label),
                  description: Text(mode.description),
                  radioValue: mode,
                ),
            ],
          ),
          SettingsSection(
            title: Text('画质增强'),
            tiles: [
              SettingsTile.switchTile(
                leading: Icons.auto_awesome_rounded,
                title: Text('去色带 (deband)'),
                description: Text('低清/老片源建议开启, 下次播放生效'),
                initialValue: debandEnable,
                onToggle: (value) async {
                  debandEnable = value ?? !debandEnable;
                  await GStorage.putSetting<bool>(
                    SettingsKeys.playerDebandEnable,
                    debandEnable,
                  );
                  if (mounted) setState(() {});
                },
              ),
              SettingsTile.switchTile(
                leading: Icons.motion_photos_on_rounded,
                title: Text('运动补偿'),
                description: Text(
                    '帧时钟对齐刷新率, 消除 24fps 源的横移顿挫 (非补帧); 120Hz 屏收益最大 (5x24 整数倍), 200Hz 屏看番建议切 120Hz, 下次播放生效'),
                initialValue: motionCompensationEnable,
                onToggle: (value) async {
                  motionCompensationEnable = value ?? !motionCompensationEnable;
                  await GStorage.putSetting<bool>(
                    SettingsKeys.playerMotionCompensationEnable,
                    motionCompensationEnable,
                  );
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
          SettingsSection(
            title: Text('默认行为'),
            tiles: [
              SettingsTile.switchTile(
                leading: Icons.notifications_off_rounded,
                title: Text('关闭提示'),
                description: Text('关闭每次启用超分辨率时的提示'),
                initialValue: disableWarning,
                onToggle: (value) async {
                  disableWarning = value ?? !disableWarning;
                  await GStorage.putSetting<bool>(
                    SettingsKeys.disableSuperResolutionWarning,
                    disableWarning,
                  );
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
