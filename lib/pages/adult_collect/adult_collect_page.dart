import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_type.dart';
import 'package:kazumi/modules/collect/collect_layout.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/collect/collect_repair.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/services/bgm/bgm_web_service.dart';
import 'package:kazumi/pages/adult_collect/bgm_login_webview_page.dart';
import 'package:kazumi/services/skip/skip_time_service.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/pages/direct_search/series_detector.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/pages/adult_collect/adult_random_pick_sheet.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/pages/collect/collect_library_view.dart';
import 'package:kazumi/services/collect/collect_export_service.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/device.dart';

// [my重写] 里番收藏页 — 与追番页同构 (复用 CollectLibraryView 全套:
// 分类 Tab/搜索/排序/双布局/卡片交互), 数据源只喂 section==1。
// 布局记忆独立 (adultCollectLayout); 卡片点击: 有 bgm 匹配开条目页,
// 未匹配直接播放; 长按菜单含"移回追番"。
class AdultCollectPage extends StatefulWidget {
  const AdultCollectPage({super.key});

  @override
  State<AdultCollectPage> createState() => _AdultCollectPageState();
}

class _AdultCollectPageState extends State<AdultCollectPage>
    with KazumiDialogOwner {
  final CollectController _collectController = inject<CollectController>();
  late CollectLayout _layout;

  @override
  void initState() {
    super.initState();
    _collectController.loadCollectibles();
    _layout = CollectLayout.fromValue(
        GStorage.getSetting(SettingsKeys.adultCollectLayout));
  }

  void _changeLayout(CollectLayout layout) {
    setState(() => _layout = layout);
    // [my修复] putSetting 是异步 Future — 未 await 时页面销毁可能中断
    // 落盘; 补 await + 日志 (布局记忆丢失排查)
    () async {
      await GStorage.putSetting(SettingsKeys.adultCollectLayout, layout.name);
      KazumiLogger().i(
          'AdultCollect: layout saved = ${layout.name}');
    }();
  }

  /// 卡片点击: 匹配 bgm 开条目页 (同追番); 未匹配凭收藏内嵌的播放地址
  /// (BangumiItem.info = 播放页 URL, 收藏时随库落 WebDAV) 直接恢复播放 —
  /// 跨设备收藏也能从收藏页一键播。
  Future<void> _open(CollectedBangumi entry) async {
    final item = entry.bangumiItem;
    final isRealBgmEntry = _collectController.collectibles
        .any((c) => c.bangumiItem.id == item.id && c.section != 1);
    if (isRealBgmEntry) {
      if (context.mounted) context.pushNamed('/info/', arguments: item);
      return;
    }
    final src = item.info.trim();
    if (src.isEmpty) {
      // 旧收藏 (info 落库前收的) 或跨设备来的: 指引用户去源直连页重收
      KazumiDialog.showToast(message: '此收藏缺播放地址, 请从源直连浏览页重新收藏');
      return;
    }
    final plugins = inject<PluginsController>().pluginList;
    final siteHost = Uri.tryParse(src)?.host ?? '';
    Plugin? plugin;
    for (final p in plugins) {
      if ((Uri.tryParse(p.baseUrl)?.host ?? '') == siteHost) {
        plugin = p;
        break;
      }
    }
    if (plugin == null) {
      KazumiDialog.showToast(message: '未找到与收藏站点同域的规则源');
      return;
    }
    // 收藏页内直接跑播放任务 (取线路 → 播放页), 与源搜索同款交互
    if (dialogs.isRunning) return;
    await dialogs.run((task) async {
      final roads = await task.loading(
        message: '正在获取播放列表',
        barrierDismissible: isDesktop(),
        action: () => plugin!.queryChapterRoads(src),
      );
      if (roads.isEmpty) {
        throw Exception('未获取到播放线路');
      }
      // [my新增] 旧格式条目惰性升级: 打开时取到播放列表并判定为系列 →
      // 把该条目改写为作品条目 (id/名称/锚点), 并合并同作品的其他旧收藏;
      // 之后播放/历史/收藏均按作品归一。类型沿用被升级条目。
      BangumiItem playItem = item;
      if (entry.type != 0) {
        // [my优化·抽取] 惰性升级走共享 upgradeToSeries (与收藏/迁移同源)
        final (status, upgradedItem, _) =
            await SeriesDetector.upgradeToSeries(
          pluginName: plugin!.name,
          item: item,
          roads: roads,
          type: entry.type,
          add: (it, t) => _collectController.addCollectLocalOnly(it,
              type: t, section: 1),
          delete: (it) => _collectController.deleteCollectLocalOnly(it),
          all: _collectController.collectibles,
        );
        if (status == SeriesDetector.seriesUpgradeCreated) {
          playItem = upgradedItem;
        }
      }
      // [my新增] 起始集 = 收藏条目指向的链接 (系列条目=锚点即第一集,
      // 旧单集条目=所收的那集); 有历史时播放页自动恢复上次看到的集数
      var startRoad = 0;
      int? startEpisode;
      final roadIndex = roads.indexWhere((r) => r.data.contains(src));
      if (roadIndex >= 0) {
        startRoad = roadIndex;
        startEpisode = roads[roadIndex].data.lastIndexOf(src) + 1;
      }
      if (mounted) {
        task.withContext((context) => context.pushNamed(
              '/video/',
              arguments: OnlineVideoPlaybackArgs(
                bangumiItem: playItem,
                plugin: plugin!,
                title: playItem.nameCn.isNotEmpty ? playItem.nameCn : playItem.name,
                src: src,
                roads: roads,
                startEpisode: startEpisode,
                startRoad: startRoad,
              ),
            ));
      }
    }, onError: (error, stackTrace) {
      KazumiLogger().w('AdultCollect: play failed', error: error);
      KazumiDialog.showToast(message: '获取播放列表失败，请重试');
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: SysAppBar(
        needTopOffset: false,
        toolbarHeight: 72,
        title: Text(
          '里番收藏',
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            tooltip: '随机选片',
            icon: const Icon(Icons.casino_rounded),
            onPressed: _showRandomPick,
          ),
          IconButton(
            tooltip: '从追番导入',
            icon: const Icon(Icons.move_down_rounded),
            onPressed: _showImportPicker,
          ),
          IconButton(
            tooltip: '修复误迁移条目',
            icon: const Icon(Icons.healing_rounded),
            onPressed: _showSectionRepair,
          ),
          IconButton(
            tooltip: '全部作品化迁移',
            icon: const Icon(Icons.merge_type_rounded),
            onPressed: _migrateAllToSeries,
          ),
          IconButton(
            tooltip: '导出收藏 JSON',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: _exportCollectibles,
          ),
          IconButton(
            tooltip: 'bgm 关联 (自动匹配元数据)',
            icon: const Icon(Icons.auto_awesome_rounded),
            onPressed: _showBgmAssociate,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        // [my修复] Observer 包裹: loadCollectibles 改的是 ObservableList,
        // 页面不包 Observer 时切分类/移回追番/修复迁回后列表不刷新
        // (追番页同位置一直有 Observer)
        child: Observer(
          builder: (_) => CollectLibraryView(
            // 只喂里番区条目 (section 过滤在页面层, 与追番页对称)
            entries: _collectController.collectibles
                .where((c) => c.section == 1)
                .toList(),
            showRating: GStorage.getSetting(SettingsKeys.showRating),
            layout: _layout,
            onLayoutChanged: _changeLayout,
            canEdit: (_) => true,
            onOpen: (item) {
              final entry = _collectController.collectibles.firstWhere(
                (c) => c.bangumiItem.id == item.id,
                orElse: () => CollectedBangumi(item, DateTime.now(), 0),
              );
              _open(entry);
            },
            onChangeType: (item, type) => unawaited(_changeType(item, type)),
            isAdultSection: true,
            onMoveToMain: (item) async {
              await _collectController.setCollectSection(item.id, 0);
              if (mounted) KazumiDialog.showToast(message: '已移回追番 (表番区)');
            },
          ),
        ),
      ),
    );
  }

  /// [my新增] 导出里番区收藏为 JSON (手动备份/跨设备分享, 免服务器):
  /// 仅 section==1; 空库提示不弹文件框; 对话只报条目数 (敏感纪律)。
  Future<void> _exportCollectibles() async {
    final entries = _collectController.collectibles
        .where((c) => c.section == 1)
        .toList(growable: false);
    if (entries.isEmpty) {
      KazumiDialog.showToast(message: '没有可导出的直连收藏');
      return;
    }
    try {
      final result = await CollectExportService.exportDirectCollectibles(
          _collectController.collectibles);
      if (result == null) return; // 用户取消
      if (mounted) {
        KazumiDialog.showToast(message: '已导出 ${result.count} 条直连收藏');
      }
    } catch (e) {
      KazumiLogger().w('AdultCollect: export failed', error: e);
      if (mounted) KazumiDialog.showToast(message: '导出失败，请稍后重试');
    }
  }

  // —— [my新增] bgm 关联 (cookie 网页搜索自动匹配 + 手动 ID + 管理) ——

  final TextEditingController _bgmEmailController = TextEditingController();
  final TextEditingController _bgmPasswordController = TextEditingController();
  // [my新增] 贴 ID 直连收藏输入 + 手动 cookie 粘贴
  final TextEditingController _bgmIdController = TextEditingController();
  final TextEditingController _bgmCookieController = TextEditingController();
  String _bgmMatchProgress = '';

  Future<void> _showBgmAssociate() async {
    _bgmEmailController.text =
        GStorage.getSetting(SettingsKeys.bgmAccountEmail).trim();
    _bgmPasswordController.text =
        GStorage.getSetting(SettingsKeys.bgmAccountPassword).trim();
    _bgmCookieController.text =
        GStorage.getSetting(SettingsKeys.bgmWebCookie).trim();
    await KazumiDialog.show(
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final map = BgmWebService.loadMap();
          final hasAccount = _bgmEmailController.text.trim().isNotEmpty &&
              _bgmPasswordController.text.trim().isNotEmpty;
          final unmapped = _collectController.collectibles
              .where((c) =>
                  c.section == 1 &&
                  !map.containsKey(c.bangumiItem.id.toString()))
              .toList();
          return AlertDialog(
            title: const Text('bgm 关联 (里番)'),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('bgm.tv 账号 (自动登录, 密码仅存本地):',
                      style: TextStyle(fontSize: 12)),
                  TextField(
                    controller: _bgmEmailController,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(hintText: '邮箱'),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _bgmPasswordController,
                    obscureText: true,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(hintText: '密码'),
                  ),
                  const SizedBox(height: 8),
                  Row(children: [
                    ElevatedButton(
                      onPressed: () async {
                        GStorage.putSetting(SettingsKeys.bgmAccountEmail,
                            _bgmEmailController.text.trim());
                        GStorage.putSetting(SettingsKeys.bgmAccountPassword,
                            _bgmPasswordController.text.trim());
                        // [my修复] 保存即验证登录 (自动登录闭环接线):
                        // 成功 cookie 落库, 失败屏显原因 (密码错/验证码等)
                        setDialogState(
                            () => _bgmMatchProgress = '正在登录 bgm…');
                        try {
                          await BgmWebService.ensureCookie();
                          setDialogState(() =>
                              _bgmMatchProgress = 'bgm 登录成功, cookie 已就绪');
                        } catch (e) {
                          setDialogState(() => _bgmMatchProgress =
                              'bgm 登录失败: ${e.toString()}');
                        }
                      },
                      child: const Text('保存账号'),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton(
                      // [my修改] Windows 无需账号 (搜索走 WebView 共享会话)
                      onPressed: (Platform.isWindows || hasAccount)
                          ? () async {
                              setDialogState(
                                  () => _bgmMatchProgress = '匹配并同步中…');
                              // [my修复] 匹配前先 ensureCookie (自动登录
                              // 接线): 此前裸调 search, 新会话逐条静默失败
                              try {
                                await BgmWebService.ensureCookie();
                              } catch (e) {
                                setDialogState(() => _bgmMatchProgress =
                                    'cookie 线不可用: ${e.toString()}');
                                return;
                              }
                              var done = 0;
                              var synced = 0;
                              final token = GStorage.getSetting<String>(
                                  SettingsKeys.bangumiAccessToken);
                              for (final c in unmapped) {
                                final key =
                                    c.bangumiItem.id.toString();
                                final title = c.bangumiItem.nameCn
                                        .isNotEmpty
                                    ? c.bangumiItem.nameCn
                                    : c.bangumiItem.name;
                                try {
                                  final cands = await BgmWebService.search(
                                      title);
                                  BgmWebSubject? best;
                                  var bestScore = 0.0;
                                  for (final cand in cands) {
                                    final s1 = SkipTimeService.similarity(
                                        title, cand.name);
                                    final s2 = SkipTimeService.similarity(
                                        c.bangumiItem.nameCn, cand.name);
                                    final sc = s1 > s2 ? s1 : s2;
                                    if (sc > bestScore) {
                                      bestScore = sc;
                                      best = cand;
                                    }
                                  }
                                  if (best != null && bestScore >= 0.5) {
                                    // [my修复] 认证直取: nsfw 条目未认证
                                    // 一律 404, 非认证通道永远关联不上
                                    final info = await BangumiApi
                                        .getBangumiInfoByIDAuth(best.id);
                                    if (info != null) {
                                      BgmWebService.associate(key,
                                          bgmId: best.id,
                                          nameCn: info.nameCn,
                                          name: info.name,
                                          score: info.ratingScore,
                                          coverUrl: (info.images['large'] ?? info.images['common'] ?? ''));
                                      done++;
                                      // [my新增] 同步收藏状态到 bgm 账号
                                      // (存量收藏批量补上传; type=0 跳过)
                                      if (c.type != 0 &&
                                          token.trim().isNotEmpty) {
                                        try {
                                          final ok = await BangumiApi
                                              .updateBangumiByType(
                                                  best.id, c.type);
                                          if (ok) synced++;
                                        } catch (_) {}
                                      }
                                    }
                                  }
                                } catch (_) {}
                                setDialogState(() => _bgmMatchProgress =
                                    '匹配并同步中… 关联$done/同步$synced / 共${unmapped.length} (${c.bangumiItem.nameCn})');
                              }
                              setDialogState(() => _bgmMatchProgress =
                                  '完成: 新关联 $done 条, 同步 bgm $synced 条');
                            }
                          : null,
                      child: Text(unmapped.isEmpty
                          ? '无未关联条目'
                          : '自动匹配并同步 (${unmapped.length} 条)'),
                    ),
                  ]),
                  if (_bgmMatchProgress.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_bgmMatchProgress,
                          style: const TextStyle(fontSize: 12)),
                    ),
                  // [my新增] 手动 cookie 粘贴 — bgm 登录 POST 有指纹级
                  // 反爬 (curl/dart 一律"验证码错误", 实机浏览器人工答案
                  // 才放行), 自动登录保留为尽力而为; 浏览器 DevTools 复制
                  // Cookie 头一次贴入即永久可用 (搜索只读, chii_auth 长效)
                  const Divider(height: 20),
                  const Text('手动贴 cookie (推荐, 免登录):',
                      style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _bgmCookieController,
                    style: const TextStyle(fontSize: 11),
                    maxLines: 3,
                    decoration: const InputDecoration(
                        hintText:
                            '浏览器打开 bgm.tv 登录后: F12 → 网络 → 任一请求 → 请求标头 → 复制 Cookie: 整段值'),
                  ),
                  const SizedBox(height: 6),
                  ElevatedButton(
                    onPressed: () async {
                      final c = _bgmCookieController.text.trim();
                      if (c.isEmpty) {
                        KazumiDialog.showToast(message: '请先粘贴 cookie');
                        return;
                      }
                      await GStorage.putSetting(SettingsKeys.bgmWebCookie, c);
                      BgmWebService.resetCookieOverride();
                      KazumiDialog.showToast(message: 'cookie 已保存, 网页搜索立即可用');
                    },
                    child: const Text('保存 cookie'),
                  ),
                  const SizedBox(width: 10),
                  // [my新增] 内嵌浏览器登录: 真指纹过 bgm 反爬, 登录成功
                  // 自动提取 cookie (含 httpOnly chii_auth) 入库
                  if (Platform.isWindows)
                    ElevatedButton(
                      onPressed: () async {
                        final ok = await Navigator.of(context).push<bool>(
                          MaterialPageRoute(
                              builder: (_) => const BgmLoginWebviewPage()),
                        );
                        if (ok == true) {
                          setDialogState(() => _bgmCookieController.text =
                              GStorage.getSetting(SettingsKeys.bgmWebCookie));
                        }
                      },
                      child: const Text('浏览器登录自动取'),
                    ),
                  // [my新增] 贴 ID 直连收藏: 已知 bgm ID 时跳过搜索,
                  // 认证详情 → 选类型 → 写入 bgm 账号 + 本地里番区
                  const Divider(height: 20),
                  const Text('贴 ID 收藏到 bgm (需已登录 bangumi):',
                      style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 6),
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: _bgmIdController,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(fontSize: 12),
                        decoration: const InputDecoration(
                            hintText: 'bgm 条目 ID (纯数字)'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton(
                      onPressed: _submitBgmIdCollect,
                      child: const Text('查详情收藏'),
                    ),
                  ]),
                  const Divider(height: 20),
                  const Text('已关联:', style: TextStyle(fontSize: 12)),
                  SizedBox(
                    height: 200,
                    child: map.isEmpty
                        ? const Text('暂无',
                            style: TextStyle(fontSize: 12))
                        : ListView.builder(
                            itemCount: map.length,
                            itemBuilder: (context, index) {
                              final key = map.keys.elementAt(index);
                              final m = map[key]!;
                              return ListTile(
                                dense: true,
                                title: Text(
                                    '${m['nameCn'] ?? m['name'] ?? '?'} (评分 ${m['score']})',
                                    style: const TextStyle(fontSize: 13)),
                                subtitle: Text('bgm ${m['bgmId']}',
                                    style: const TextStyle(fontSize: 11)),
                                trailing: TextButton(
                                  child: const Text('解除'),
                                  onPressed: () {
                                    BgmWebService.removeAssociation(key);
                                    setDialogState(() {});
                                  },
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  _collectController.loadCollectibles();
                  KazumiDialog.dismiss();
                  if (mounted) setState(() {});
                },
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  /// [my新增] 贴 ID 直连收藏: 认证详情 (nsfw 未认证 404) → 类型选择 →
  /// POST 写入 bgm 账号 (收藏端点对 nsfw 实测 202 放行) → 本地入里番区
  /// (真实 bgm 条目无直连播放地址, 点卡片有引导提示)。
  Future<void> _submitBgmIdCollect() async {
    final id = int.tryParse(_bgmIdController.text.trim());
    if (id == null || id <= 0) {
      KazumiDialog.showToast(message: '请输入有效的 bgm 条目 ID');
      return;
    }
    try {
      final info = await BangumiApi.getBangumiInfoByIDAuth(id);
      if (info == null) {
        KazumiDialog.showToast(message: '详情获取失败 (未登录 bangumi 或 ID 不存在)');
        return;
      }
      int selectedType = CollectType.planToWatch.value;
      final confirmed = await KazumiDialog.show<bool>(
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Text(
                info.nameCn.isNotEmpty ? info.nameCn : info.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final t in [
                  CollectType.planToWatch,
                  CollectType.watched,
                  CollectType.watching,
                  CollectType.onHold,
                  CollectType.abandoned,
                ])
                  RadioListTile<int>(
                    value: t.value,
                    groupValue: selectedType,
                    title: Text(t.label),
                    dense: true,
                    onChanged: (v) =>
                        setDialogState(() => selectedType = v ?? selectedType),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: KazumiDialog.dismiss,
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('收藏'),
              ),
            ],
          ),
        ),
      );
      if (confirmed != true) return;
      final ok = await BangumiApi.updateBangumiByType(id, selectedType);
      if (!ok) {
        KazumiDialog.showToast(message: 'bgm 收藏写入失败, 请稍后重试');
        return;
      }
      await _collectController.addCollectLocalOnly(info,
          type: selectedType, section: 1);
      KazumiDialog.showToast(message: '已收藏到 bgm 并入里番区 (ID $id)');
    } catch (e) {
      KazumiDialog.showToast(message: 'bgm 收藏失败: ${e.toString()}');
    }
  }

  /// [my新增] 解析 bgm 同步目标 id: 真实 bgm 条目用自身 id; 源直连条目
  /// (哈希 id) 按 adultBgmMap 映射寻址 (bgm 勾选收藏流入库)。null = 无
  /// 同步目标。
  int? _resolveBgmSyncId(BangumiItem item) {
    if (!CollectSectionRepair.isDirectSourceItem(item)) return item.id;
    final assoc = BgmWebService.loadMap()[item.id.toString()];
    if (assoc == null) return null;
    return (assoc['bgmId'] as num?)?.toInt();
  }

  Future<void> _changeType(BangumiItem item, CollectType type) async {    if (type == CollectType.none) {
      // [my新增] bgm 联动删除: API 无删除端点 (实测 405/404), 走 webview
      // GET /subject/{id}/remove?gh= (eraseSubjectCollect 复刻, GET 不触
      // 发指纹墙)
      final bgmId = _resolveBgmSyncId(item);
      await _collectController.deleteCollectLocalOnly(item);
      if (mounted) KazumiDialog.showToast(message: '已取消收藏');
      if (bgmId != null && Platform.isWindows) {
        final removed = await BgmWebService.removeSubjectCollectWeb(bgmId);
        if (mounted) {
          KazumiDialog.showToast(
              message: removed
                  ? '已在 bgm 同步删除收藏'
                  : 'bgm 删除未成功 (可网页端手动删)');
        }
      }
      return;
    }
    try {
      // 里番区改类型: 本地落库 (section 保持 1, 不进 Bangumi 拉取合并)
      await _collectController.addCollectLocalOnly(item,
          type: type.value, section: 1);
      // [my新增] 类型变更同步 bgm: 真实 bgm 条目用自身 id; 源直连条目按
      // adultBgmMap 映射寻址 (bgm 勾选收藏流入库)
      final bgmId = _resolveBgmSyncId(item);
      if (bgmId != null) {
        final token =
            GStorage.getSetting<String>(SettingsKeys.bangumiAccessToken);
        if (token.trim().isNotEmpty) {
          try {
            final ok =
                await BangumiApi.updateBangumiByType(bgmId, type.value);
            if (mounted && ok) {
              KazumiDialog.showToast(message: '已同步到 bgm (${type.label})');
            }
          } catch (e) {
            KazumiLogger().w('AdultCollect: bgm type sync failed', error: e);
          }
        }
      }
    } catch (_) {
      KazumiDialog.showToast(message: '修改收藏状态失败，请稍后重试');
    }
  }

  /// 随机选片: 加权轮盘从"想看"抽三选一, 点选即播 (复用卡片播放链)
  Future<void> _showRandomPick() async {
    await showAdultRandomPickSheet(
      context,
      collectController: _collectController,
      historyController: inject<HistoryController>(),
      onPlay: (item) => _open(CollectedBangumi(item, DateTime.now(),
          CollectType.planToWatch.value, section: 1)),
    );
  }

  /// [my新增] 全部作品化迁移: 逐条解析播放列表判定系列, 旧格式单集收藏
  /// 升级为作品条目 (类型沿用), 并合并同作品重复收藏。耗时与条目数成正比。
  Future<void> _migrateAllToSeries() async {
    if (dialogs.isRunning) return;
    final entries = _collectController.collectibles
        .where((c) =>
            c.section == 1 &&
            CollectSectionRepair.isDirectSourceItem(c.bangumiItem) &&
            c.bangumiItem.info.trim().isNotEmpty)
        .toList();
    if (entries.isEmpty) {
      KazumiDialog.showToast(message: '没有可迁移的条目');
      return;
    }
    final confirmed = await KazumiDialog.show<bool>(
      builder: (context) => AlertDialog(
        title: const Text('全部作品化迁移', style: TextStyle(fontSize: 16)),
        content: Text(
          '将逐条解析 ${entries.length} 个收藏的播放列表, 把旧格式单集收藏'
          '升级为作品条目, 并合并同作品的重复收藏。\n\n'
          '需要网络, 每条约数秒, 期间请保持应用开启。',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('开始迁移'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await dialogs.run((task) async {
      await task.loading(
        message: '正在批量作品化收藏…',
        barrierDismissible: isDesktop(),
        // [my优化] 批量区间挂起逐条刷新, 结束统一刷一次
        action: () => _collectController.suppressLoads(() async {
          final plugins = inject<PluginsController>().pluginList;
          var upgraded = 0;
          var merged = 0;
          var cleaned = 0;
          var failed = 0;
          final doneIds = <int>{};
          for (final entry in entries) {
            final item = entry.bangumiItem;
            if (doneIds.contains(item.id)) continue;
            doneIds.add(item.id);
            try {
              final src = item.info.trim();
              final host = Uri.tryParse(src)?.host ?? '';
              Plugin? plugin;
              for (final p in plugins) {
                if ((Uri.tryParse(p.baseUrl)?.host ?? '') == host) {
                  plugin = p;
                  break;
                }
              }
              if (plugin == null) {
                failed++;
                continue;
              }
              final roads = await plugin.queryChapterRoads(src);
              final (status, upgradedItem, mergedCount) =
                  await SeriesDetector.upgradeToSeries(
                pluginName: plugin.name,
                item: item,
                roads: roads,
                type: entry.type,
                add: (it, t) => _collectController.addCollectLocalOnly(it,
                    type: t, section: 1),
                delete: (it) =>
                    _collectController.deleteCollectLocalOnly(it),
                all: _collectController.collectibles,
              );
              if (status == SeriesDetector.seriesUpgradeCreated) {
                upgraded++;
                merged += mergedCount;
                doneIds.add(item.id);
                for (final sibling in SeriesDetector.findSameSeriesSiblings(
                    upgradedItem, _collectController.collectibles)) {
                  doneIds.add(sibling.bangumiItem.id);
                }
                continue;
              }
              if (status == SeriesDetector.seriesUpgradeUnchanged) {
                doneIds.add(item.id);
                continue;
              }
              // NoChange = 非系列/空线路: 只做命名清洗 (剥带量词的
                // 集数标记; id 不变 → 历史不脱钩)
                final currentName = item.nameCn.isNotEmpty
                    ? item.nameCn
                    : item.name;
                final cleanName = SeriesDetector.namingName(currentName);
                if (cleanName != currentName && cleanName.length >= 2) {
                  await _collectController.updateLocalCollect(
                    BangumiItem(
                      id: item.id,
                      type: item.type,
                      name: cleanName,
                      nameCn: cleanName,
                      summary: item.summary,
                      airDate: item.airDate,
                      airWeekday: item.airWeekday,
                      rank: item.rank,
                      images: item.images,
                      tags: item.tags,
                      alias: item.alias,
                      ratingScore: item.ratingScore,
                      votes: item.votes,
                      votesCount: item.votesCount,
                      info: item.info,
                    ),
                  );
                  cleaned++;
                }
            } catch (error) {
              failed++;
              KazumiLogger().w('AdultCollect: migrate entry failed',
                  error: error);
            }
          }
          if (!mounted) return;
          KazumiDialog.showToast(
              message: '作品化完成：升级 $upgraded 条，合并 $merged 条'
                  '${cleaned > 0 ? "，改名 $cleaned 条" : ""}'
                  '${failed > 0 ? "，失败 $failed 条" : ""}');
        }),
      );
    }, onError: (error, stackTrace) {
      KazumiLogger().w('AdultCollect: migrate all failed', error: error);
      KazumiDialog.showToast(message: '迁移中断，请稍后重试');
    });
  }

  /// [my新增] 修复旧版同步 bug 留下的分区错乱: 源直连条目 (info 带
  /// 播放页地址 / 哈希 id) 被错误记成表番时, 批量迁回里番区。
  Future<void> _showSectionRepair() async {
    final candidates = CollectSectionRepair.findMisplacedDirectCollectibles(
        _collectController.collectibles);
    if (candidates.isEmpty) {
      KazumiDialog.showToast(message: '未发现误迁移条目');
      return;
    }
    final confirmed = await KazumiDialog.show<bool>(
      builder: (context) => AlertDialog(
        title: Text(
          '发现 ${candidates.length} 条误迁移条目',
          style: const TextStyle(fontSize: 16),
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '这些条目由源直连页收藏, 本应属于里番区, 但被旧版同步写成了表番。',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final c in candidates)
                      Text(
                        '· ${c.bangumiItem.nameCn.isNotEmpty ? c.bangumiItem.nameCn : c.bangumiItem.name}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('迁回里番区 (${candidates.length})'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final c in candidates) {
      await _collectController.setCollectSection(c.bangumiItem.id, 1);
    }
    if (!mounted) return;
    KazumiDialog.showToast(
      message: '已迁回 ${candidates.length} 条；请到 WebDAV 设置重建收藏云快照',
    );
  }

  /// 从追番 (表番区) 批量导入
  Future<void> _showImportPicker() async {
    final candidates = _collectController.collectibles
        .where((c) => c.section != 1)
        .toList()
      ..sort((a, b) => b.time.compareTo(a.time));
    if (candidates.isEmpty) {
      KazumiDialog.showToast(message: '表番区没有可导入的收藏');
      return;
    }
    final selected = <int>{};
    await KazumiDialog.show(
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('从追番导入到里番区', style: TextStyle(fontSize: 16)),
          content: SizedBox(
            width: 420,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final c in candidates)
                  CheckboxListTile(
                    dense: true,
                    value: selected.contains(c.bangumiItem.id),
                    title: Text(
                      c.bangumiItem.nameCn.isNotEmpty
                          ? c.bangumiItem.nameCn
                          : c.bangumiItem.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                    onChanged: (v) => setDialogState(() => v == true
                        ? selected.add(c.bangumiItem.id)
                        : selected.remove(c.bangumiItem.id)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: KazumiDialog.dismiss,
              child: Text('取消',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.outline)),
            ),
            TextButton(
              onPressed: () async {
                for (final id in selected) {
                  await _collectController.setCollectSection(id, 1);
                }
                KazumiDialog.dismiss();
                KazumiDialog.showToast(message: '已导入 ${selected.length} 条');
              },
              child: Text('导入 (${selected.length})'),
            ),
          ],
        ),
      ),
    );
  }
}
