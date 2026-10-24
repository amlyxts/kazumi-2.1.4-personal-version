import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/services/sync/bangumi_sync_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/sync/webdav.dart';
import 'package:kazumi/repositories/collect_crud_repository.dart';
import 'package:mobx/mobx.dart';
import 'package:kazumi/services/logging/logger.dart';

part 'collect_controller.g.dart';

enum _BangumiDeleteSyncAction {
  deleteLocalOnly,
  markAbandoned,
  openWeb,
  cancel,
}

class CollectController = _CollectController with _$CollectController;

abstract class _CollectController with Store {
  _CollectController(this._collectCrudRepository);

  final ICollectCrudRepository _collectCrudRepository;

  @observable
  ObservableList<CollectedBangumi> collectibles =
      ObservableList<CollectedBangumi>();

  void loadCollectibles() {
    collectibles.clear();
    collectibles.addAll(_collectCrudRepository.getAllCollectibles());
  }

  int getCollectType(BangumiItem bangumiItem) {
    return _collectCrudRepository.getCollectType(bangumiItem.id);
  }

  /// [my修改] 仅本地收藏 (跳过 Bangumi 同步): 用于无真实 bangumi id 的
  /// 直连源条目 (本地哈希 id), 同步对不存在条目无意义。
  @action
  Future<void> addCollectLocalOnly(BangumiItem bangumiItem,
      {type = 1, int section = 0}) async {
    await _collectCrudRepository.addCollectible(bangumiItem, type,
        section: section);
    await GStorage.appendCollectChange(
      bangumiId: bangumiItem.id,
      action: 1,
      type: type,
    );
    loadCollectibles();
  }

  /// [my新增] 迁移收藏分区 (0=表番 ⇄ 1=里番), 保留原类型与时间
  @action
  Future<void> setCollectSection(int id, int section) async {
    await _collectCrudRepository.setCollectSection(id, section);
    loadCollectibles();
  }

  @action
  Future<void> deleteCollectLocalOnly(BangumiItem bangumiItem) async {
    await _collectCrudRepository.deleteCollectible(bangumiItem.id);
    await GStorage.appendCollectChange(
      bangumiId: bangumiItem.id,
      action: 2,
      type: 0,
    );
    loadCollectibles();
  }

  @action
  Future<void> addCollect(BangumiItem bangumiItem, {type = 1}) async {
    if (type == 0) {
      await deleteCollect(bangumiItem);
      return;
    }

    // [my修改] 本地优先: 先落本地与变更日志 (WebDAV 增量随日志走), Bangumi
    // 同步尽力而为 — 失败只提示不回滚 (此前同步失败会取消本次修改, 网络
    // 抖动时本地也改不动)。未同步的差异由后续手动/自动全量同步收敛。
    final int currentCollectType = getCollectType(bangumiItem);
    final int collectChangeAction = currentCollectType == 0 ? 1 : 2;

    await _collectCrudRepository.addCollectible(bangumiItem, type);
    await GStorage.appendCollectChange(
      bangumiId: bangumiItem.id,
      action: collectChangeAction,
      type: type,
    );
    loadCollectibles();

    await _syncBangumiCollectIfEnabled(
      bangumiItem.id,
      type,
    );
  }

  @action
  Future<void> deleteCollect(BangumiItem bangumiItem) async {
    final action = await _resolveBangumiDeleteSyncAction(bangumiItem);
    switch (action) {
      case _BangumiDeleteSyncAction.markAbandoned:
        await addCollect(
          bangumiItem,
          type: CollectType.abandoned.value,
        );
        return;

      case _BangumiDeleteSyncAction.openWeb:
        await _deleteCollectLocally(bangumiItem);
        await _openBangumiSubjectPage(bangumiItem.id);
        return;

      case _BangumiDeleteSyncAction.deleteLocalOnly:
        await _deleteCollectLocally(bangumiItem);
        return;

      case _BangumiDeleteSyncAction.cancel:
      case null:
        return;
    }
  }

  Future<void> _deleteCollectLocally(BangumiItem bangumiItem) async {
    await _collectCrudRepository.deleteCollectible(bangumiItem.id);
    await GStorage.appendCollectChange(
      bangumiId: bangumiItem.id,
      action: 3,
      type: 5,
    );
    loadCollectibles();
  }

  Future<_BangumiDeleteSyncAction?> _resolveBangumiDeleteSyncAction(
      BangumiItem bangumiItem) async {
    final bool syncEnable = GStorage.getSetting(SettingsKeys.bangumiSyncEnable);
    if (!syncEnable) {
      return _BangumiDeleteSyncAction.deleteLocalOnly;
    }

    return KazumiDialog.show<_BangumiDeleteSyncAction>(
      clickMaskDismiss: true,
      builder: (context) => AlertDialog(
        title: const Text('Bangumi 不支持删除收藏'),
        content: const Text(
          '因为安全考虑，Bangumi 未提供删除接口，您可以选择把本地和远端标记为“抛弃”，或者选择仅删除本地收藏并打开网页后手动删除 Bangumi 数据。',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop(_BangumiDeleteSyncAction.cancel);
            },
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop(_BangumiDeleteSyncAction.openWeb);
            },
            child: const Text('打开网页'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop(_BangumiDeleteSyncAction.markAbandoned);
            },
            child: const Text('标记为抛弃'),
          ),
        ],
      ),
    );
  }

  Future<void> _openBangumiSubjectPage(int bangumiId) async {
    final url = Uri.parse('https://bangumi.tv/subject/$bangumiId');
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
      return;
    }
    KazumiDialog.showToast(message: '无法打开 Bangumi 网页');
  }

  Future<bool> _syncBangumiCollectIfEnabled(
      int bangumiId, int localType) async {
    final bool syncEnable = GStorage.getSetting(SettingsKeys.bangumiSyncEnable);
    final bool showImmediateSyncToast =
        GStorage.getSetting(SettingsKeys.bangumiImmediateSyncToastEnable);

    if (!syncEnable) {
      return true;
    }

    final bangumi = BangumiSyncService();
    try {
      if (showImmediateSyncToast) {
        KazumiDialog.showToast(message: '正在同步到 Bangumi...');
      }
      final bool synced =
          await bangumi.syncCollectibleWhenIdle(bangumiId, localType);
      if (synced && showImmediateSyncToast) {
        KazumiDialog.showToast(message: '已同步到 Bangumi');
        return true;
      } else if (!synced) {
        KazumiDialog.showToast(message: '本地已保存；同步到 Bangumi 失败，稍后同步会自动重试');
        KazumiLogger().w(
          'Bangumi: immediate collect sync did not complete. bangumiId=$bangumiId, type=$localType',
        );
        return false;
      }
      return true;
    } catch (e, stackTrace) {
      KazumiDialog.showToast(
          message:
              '本地已保存；同步到 Bangumi 失败：${BangumiSyncService.describeError(e)}');
      KazumiLogger().e(
        'Bangumi: immediate collect sync failed. bangumiId=$bangumiId, type=$localType',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<void> updateLocalCollect(BangumiItem bangumiItem) async {
    await _collectCrudRepository.updateCollectible(bangumiItem);
    loadCollectibles();
  }

  void _reportSyncError(String message, ValueChanged<String> onError,
      {Object? error}) {
    if (error != null) {
      KazumiLogger().e(message, error: error);
    }
    onError(message);
  }

  Future<bool> _connectWebDav(ValueChanged<String> onError) async {
    final bool webDavCollectEnable =
        GStorage.getSetting(SettingsKeys.webDavEnableCollect);
    if (!webDavCollectEnable) {
      _reportSyncError('请开启 WebDAV 收藏同步', onError);
      return false;
    }
    if (!WebDav().initialized) {
      _reportSyncError('WebDAV 未连接，请检查配置', onError);
      return false;
    }
    try {
      await WebDav().ping();
    } catch (e) {
      _reportSyncError('WebDAV 连接失败，请检查网络或配置', onError, error: e);
      return false;
    }
    return true;
  }

  Future<bool> syncCollectibles({
    required ValueChanged<String> onError,
  }) async {
    if (!await _connectWebDav(onError)) return false;
    try {
      await WebDav().syncCollectibles();
    } catch (e) {
      _reportSyncError('WebDAV 同步失败，请检查连接', onError, error: e);
      return false;
    }
    loadCollectibles();
    return true;
  }

  // Upload without merging again after Bangumi updates the local collection.
  Future<bool> uploadCollectiblesToWebDav({
    required ValueChanged<String> onError,
  }) async {
    if (!await _connectWebDav(onError)) return false;
    try {
      await WebDav().updateCollectibles();
    } catch (e) {
      _reportSyncError('WebDAV 回传失败，请检查连接', onError, error: e);
      return false;
    }
    return true;
  }

  Future<void> migrateCollect() async {
    final favorites = _collectCrudRepository.getFavorites();
    if (favorites.isNotEmpty) {
      int count = 0;
      for (BangumiItem bangumiItem in favorites) {
        // Migration must work before Bangumi is initialized.
        final int currentCollectType = getCollectType(bangumiItem);
        final int collectChangeAction = currentCollectType == 0 ? 1 : 2;
        await _collectCrudRepository.addCollectible(bangumiItem, 1);
        await GStorage.appendCollectChange(
          bangumiId: bangumiItem.id,
          action: collectChangeAction,
          type: 1,
        );
        count++;
      }
      await _collectCrudRepository.clearFavorites();
      loadCollectibles();
      KazumiLogger().d(
          'GStorage: detected $count uncategorized favorites, migrated to collectibles');
    }
  }

  Future<bool> syncCollectiblesBangumi({
    required void Function(String message, int current, int total) onProgress,
    required ValueChanged<String> onError,
  }) async {
    final bool syncEnable = GStorage.getSetting(SettingsKeys.bangumiSyncEnable);
    if (!syncEnable) {
      _reportSyncError('请开启 Bangumi 同步', onError);
      return false;
    }

    try {
      await BangumiSyncService().syncCollectibles(onProgress: onProgress);
    } catch (e) {
      _reportSyncError(BangumiSyncService.describeError(e), onError, error: e);
      return false;
    }
    loadCollectibles();
    return true;
  }
}
