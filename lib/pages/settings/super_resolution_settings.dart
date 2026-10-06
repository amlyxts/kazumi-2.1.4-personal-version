import 'package:flutter/material.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/pages/player/controller/player_super_resolution.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:card_settings_ui/card_settings_ui.dart';

class SuperResolutionSettings extends StatefulWidget {
  const SuperResolutionSettings({super.key});

  @override
  State<SuperResolutionSettings> createState() =>
      _SuperResolutionSettingsState();
}

class _SuperResolutionSettingsState extends State<SuperResolutionSettings> {
  late bool disableWarning;
  late bool debandEnable;
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
    superResolutionMode = SuperResolutionMode.fromStorageValue(
      GStorage.getSetting<int>(SettingsKeys.defaultSuperResolutionMode),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fontFamily = Theme.of(context).textTheme.bodyMedium?.fontFamily;
    return Scaffold(
      appBar: const SysAppBar(
        title: Text('超分辨率'),
      ),
      body: SettingsList(
        maxWidth: 1000,
        sections: [
          SettingsSection(
              title: Text('超分辨率需要启用硬件解码, 若启用硬件解码后仍然不生效, 尝试切换视频渲染器为 gpu',
                  style: TextStyle(fontFamily: fontFamily)),
              tiles: [
                for (final mode in SuperResolutionMode.values)
                  SettingsTile<SuperResolutionMode>.radioTile(
                    title: Text(
                      mode.label,
                      style: TextStyle(fontFamily: fontFamily),
                    ),
                    description: Text(
                      mode.description,
                      style: TextStyle(fontFamily: fontFamily),
                    ),
                    radioValue: mode,
                    groupValue: superResolutionMode,
                    onChanged: (SuperResolutionMode? value) {
                      if (value == null) return;
                      GStorage.putSetting<int>(
                        SettingsKeys.defaultSuperResolutionMode,
                        value.storageValue,
                      );
                      setState(() {
                        superResolutionMode = value;
                      });
                    },
                  ),
              ]),
          // [my修改] 画质增强：去色带，低清/老片源建议开启
          SettingsSection(
              title: Text('画质增强 (下次播放时生效)',
                  style: TextStyle(fontFamily: fontFamily)),
              tiles: [
                SettingsTile.switchTile(
                  title: Text('去色带 (deband)',
                      style: TextStyle(fontFamily: fontFamily)),
                  description: Text(
                      '减轻低清片源的色块断层与色带, 老电视剧/低清源建议开启',
                      style: TextStyle(fontFamily: fontFamily)),
                  initialValue: debandEnable,
                  onToggle: (value) async {
                    debandEnable = value ?? !debandEnable;
                    await GStorage.putSetting<bool>(
                      SettingsKeys.playerDebandEnable,
                      debandEnable,
                    );
                    setState(() {});
                  },
                ),
              ]),
          SettingsSection(
            title: Text('默认行为', style: TextStyle(fontFamily: fontFamily)),
            tiles: [
              SettingsTile.switchTile(
                title: Text('关闭提示', style: TextStyle(fontFamily: fontFamily)),
                description: Text('关闭每次启用超分辨率时的提示',
                    style: TextStyle(fontFamily: fontFamily)),
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
