// [my新增] 插件/设置云同步服务 — WebDAV 第五、六路。
// 插件: 并集合并 (按插件名), 修复侧载重装后逐个重装规则源之痛。
// 设置: 快照式同步 (排除名单外的键), 最近写入优先。
// 机制仿弹幕对齐/屏蔽词: 启动拉取一次 + 变更防抖推送。
import 'dart:async';

import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/sync/webdav.dart';

class AssetsSyncService {
  AssetsSyncService._();

  static final AssetsSyncService instance = AssetsSyncService._();

  Timer? _pushTimer;
  bool _started = false;
  StreamSubscription<void>? _settingsSub;

  void start() {
    if (_started) return;
    _started = true;
    // 启动拉取 (延迟, 避开启动网络高峰; 弹幕预热同款)
    Future.delayed(const Duration(seconds: 8), () {
      unawaited(_pullPlugins());
      unawaited(_pullSettings());
    });
    // 插件变更防抖推送
    try {
      final controller = inject<PluginsController>();
      controller.pluginList.observe((_) => _schedulePush());
    } catch (_) {}
    // 设置变更防抖推送 (设置框任何写入都触发; 排除名单在导出时过滤)
    _settingsSub ??= GStorage.settingChanges.listen((_) => _schedulePush());
  }

  void _schedulePush() {
    _pushTimer?.cancel();
    _pushTimer = Timer(const Duration(seconds: 3), () {
      unawaited(_pushPlugins());
      unawaited(_pushSettings());
    });
  }

  // ====== 插件 ======

  PluginsController? _pluginsController() {
    try {
      return inject<PluginsController>();
    } catch (_) {
      return null;
    }
  }

  Future<void> _pullPlugins() async {
    final webDav = _webDav();
    if (webDav == null || !webDav.isPluginSyncEnabled) return;
    final controller = _pluginsController();
    if (controller == null) return;
    try {
      await webDav.syncPlugins(
        merge: (remoteJson) async {
          // 并集: 云端有本地没有的插件落本地; 本地为准的重名保留本地
          final localJson = controller.exportPluginsJson();
          final merged = controller.mergePluginsJson(localJson, remoteJson);
          if (merged.imported > 0) {
            await controller.importPluginsJson(merged.json);
            KazumiLogger().i(
                'AssetsSync: plugins pulled from webdav, imported ${merged.imported}');
          }
          return merged.json;
        },
        export: () => controller.exportPluginsJson(),
      );
    } catch (e) {
      KazumiLogger().w('AssetsSync: plugin sync failed', error: e);
    }
  }

  Future<void> _pushPlugins() async {
    final webDav = _webDav();
    if (webDav == null || !webDav.isPluginSyncEnabled) return;
    final controller = _pluginsController();
    if (controller == null) return;
    try {
      await webDav.syncPlugins(
        merge: (remoteJson) async => controller.exportPluginsJson(),
        export: () => controller.exportPluginsJson(),
      );
    } catch (e) {
      KazumiLogger().w('AssetsSync: plugin push failed', error: e);
    }
  }

  // ====== 设置 ======

  Map<String, dynamic> _exportSettings() {
    final out = <String, dynamic>{};
    for (final key in SettingsKeys.all) {
      if (SettingsKeys.settingsSyncExcluded.contains(key.name)) continue;
      final v = GStorage.getSettingRaw(key);
      if (v != null) out[key.name] = v;
    }
    return out;
  }

  Future<void> _pullSettings() async {
    final webDav = _webDav();
    if (webDav == null || !webDav.isSettingsSyncEnabled) return;
    try {
      await webDav.syncSettings(
        merge: (remote, remoteUpdatedAt) async {
          final localUpdatedAt =
              GStorage.getSetting(SettingsKeys.webDavSettingsSyncUpdatedAt);
          // 最近写入优先; 首次 (本地 0) 采用云端
          if (remoteUpdatedAt > localUpdatedAt && remote.isNotEmpty) {
            var applied = 0;
            for (final e in remote.entries) {
              if (SettingsKeys.settingsSyncExcluded.contains(e.key)) {
                continue;
              }
              final key = SettingsKeys.byName(e.key);
              if (key == null) continue; // 版本差异: 云端有本地无的键
              await GStorage.putSettingRaw(key, e.value);
              applied++;
            }
            KazumiLogger().i(
                'AssetsSync: settings pulled from webdav, applied $applied');
          }
          GStorage.putSetting(SettingsKeys.webDavSettingsSyncUpdatedAt,
              DateTime.now().millisecondsSinceEpoch);
          return _exportSettings();
        },
        export: _exportSettings,
        localUpdatedAt: () => DateTime.now().millisecondsSinceEpoch,
      );
    } catch (e) {
      KazumiLogger().w('AssetsSync: settings sync failed', error: e);
    }
  }

  Future<void> _pushSettings() async {
    final webDav = _webDav();
    if (webDav == null || !webDav.isSettingsSyncEnabled) return;
    try {
      await webDav.syncSettings(
        merge: (remote, remoteUpdatedAt) async => _exportSettings(),
        export: _exportSettings,
        localUpdatedAt: () => DateTime.now().millisecondsSinceEpoch,
      );
      GStorage.putSetting(SettingsKeys.webDavSettingsSyncUpdatedAt,
          DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      KazumiLogger().w('AssetsSync: settings push failed', error: e);
    }
  }

  WebDav? _webDav() {
    try {
      return inject<WebDav>();
    } catch (_) {
      return null;
    }
  }
}
