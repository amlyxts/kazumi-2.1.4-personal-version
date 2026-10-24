import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/network_mirror_settings.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/pages/settings/proxy/ocr_channel_editor.dart';
import 'package:kazumi/pages/settings/proxy/rule_repo_editor.dart';
import 'package:kazumi/request/apis/plugin_catalog_api.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/services/network/proxy_manager.dart';
import 'package:kazumi/services/plugin/captcha_ocr_service.dart';
import 'package:kazumi/services/storage/storage.dart';

class ProxySettingsPage extends StatefulWidget {
  const ProxySettingsPage({super.key});

  @override
  State<ProxySettingsPage> createState() => _ProxySettingsPageState();
}

class _ProxySettingsPageState extends State<ProxySettingsPage> {
  Future<void> _setProxyEnabled(bool value) async {
    if (value && !GStorage.getSetting(SettingsKeys.proxyConfigured)) {
      KazumiDialog.showToast(message: '请先在代理配置中完成测试');
      return;
    }
    await GStorage.putSetting(SettingsKeys.proxyEnable, value);
    if (value) {
      ProxyManager.applyProxy();
    } else {
      ProxyManager.clearProxy();
    }
    if (mounted) setState(() {});
  }

  Future<void> _manageOcrChannels() async {
    final saved = await showOcrChannelManager(context);
    if (saved && mounted) setState(() {});
  }

  Future<void> _manageRuleRepos() async {
    final saved = await showRuleRepoManager(context);
    if (saved && mounted) setState(() {});
  }

  // [my修改] FlareSolverr 配置输入
  Future<void> _editFlareSolverrField({
    required String title,
    required SettingKey<String> settingKey,
    required String hint,
  }) async {
    final controller =
        TextEditingController(text: GStorage.getSetting(settingKey));
    await KazumiDialog.show(
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: KazumiDialog.dismiss,
            child: Text('取消',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.outline)),
          ),
          TextButton(
            onPressed: () {
              GStorage.putSetting(settingKey, controller.text.trim());
              KazumiDialog.dismiss();
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final proxyEnabled = GStorage.getSetting(SettingsKeys.proxyEnable);
    final ocrEnabled = GStorage.getSetting(SettingsKeys.captchaOcrEnable);
    return SettingsDetailScaffold(
      title: const Text('网络设置'),
      body: SettingsList(
        sections: [
          const NetworkMirrorSettings(),
          SettingsSection(
            title: const Text('验证码自动识别'),
            tiles: [
              SettingsTile.switchTile(
                leading: Icons.smart_button_outlined,
                onToggle: (value) async {
                  await GStorage.putSetting(
                      SettingsKeys.captchaOcrEnable, value ?? !ocrEnabled);
                  if (mounted) setState(() {});
                },
                title: const Text('启用验证码自动识别'),
                description: const Text(
                    '遇到图片验证码时自动 OCR 填写提交，最多尝试 3 张图；未配置密钥时自动跳过'),
                initialValue: ocrEnabled,
              ),
              SettingsTile(
                leading: Icons.key_rounded,
                onPressed: (_) => _manageOcrChannels(),
                title: const Text('OCR 渠道管理'),
                description: Text(CaptchaOcrService.configured
                    ? '已配置 ${CaptchaOcrService.loadChannels().where((c) => c.apiKey.isNotEmpty).length} 个可用渠道'
                    : '未配置 (添加渠道并填入密钥后生效)'),
              ),
            ],
          ),
          SettingsSection(
            title: const Text('规则仓库'),
            tiles: [
              SettingsTile(
                leading: Icons.inventory_2_outlined,
                onPressed: (_) => _manageRuleRepos(),
                title: const Text('自定义规则仓库'),
                description: Text(() {
                  final count =
                      PluginCatalogApi.listRepos().length;
                  return count == 0
                      ? '未配置 (仅官方仓库)'
                      : '已配置 $count 个 (插件市场顶部切换)';
                }()),
              ),
            ],
          ),
          SettingsSection(
            title: const Text('追加代理白名单'),
            tiles: [
              SettingsTile(
                leading: Icons.playlist_add_rounded,
                onPressed: (_) => _editFlareSolverrField(
                  title: '追加代理白名单',
                  settingKey: SettingsKeys.proxyWhitelistExtra,
                  hint: '域名1,域名2 (逗号分隔, 留空关闭)',
                ),
                title: const Text('追加白名单域名'),
                description: Text(() {
                  final v = GStorage.getSetting(
                      SettingsKeys.proxyWhitelistExtra);
                  return v.isEmpty
                      ? '未配置 (被墙规则源的站名走此处配置, 不写入代码)'
                      : '已配置: $v';
                }()),
              ),
            ],
          ),
          // [my修改] 源直连浏览站点配置仅非 iOS 平台显示 (iOS 无源搜索功能)
          if (kSupportsR18Tabs)
            SettingsSection(
              title: const Text('源直连浏览站点'),
              tiles: [
                SettingsTile(
                  leading: Icons.travel_explore_rounded,
                  onPressed: (_) => _editFlareSolverrField(
                    title: '源直连浏览站点',
                    settingKey: SettingsKeys.directSearchSite,
                    hint: 'https://<站点首页>',
                  ),
                  title: const Text('浏览站点首页'),
                  description: Text(() {
                    final v = GStorage.getSetting(
                        SettingsKeys.directSearchSite);
                    return v.isEmpty ? '未配置 (源直连浏览功能关闭)' : v;
                  }()),
                ),
              ],
            ),
          SettingsSection(
            title: const Text('FlareSolverr (CF 挑战求解)'),
            tiles: [
              SettingsTile(
                leading: Icons.local_fire_department_rounded,
                onPressed: (_) => _editFlareSolverrField(
                  title: 'FlareSolverr 地址',
                  settingKey: SettingsKeys.flareSolverrUrl,
                  hint: 'http://127.0.0.1:8191',
                ),
                title: const Text('服务地址'),
                description: Text(() {
                  final v = GStorage.getSetting(
                      SettingsKeys.flareSolverrUrl);
                  return v.isEmpty ? '未配置 (功能关闭)' : v;
                }()),
              ),
              SettingsTile(
                leading: Icons.alt_route_rounded,
                onPressed: (_) => _editFlareSolverrField(
                  title: 'FlareSolverr 出口代理',
                  settingKey: SettingsKeys.flareSolverrProxy,
                  hint: 'http://host.docker.internal:7897',
                ),
                title: const Text('出口代理 (建议配置)'),
                description: const Text(
                    '让 FlareSolverr 的无头浏览器与应用走同一代理出口, 否则求解的凭证因 IP 不匹配无效'),
              ),
            ],
          ),
          SettingsSection(
            title: const Text('代理'),
            tiles: [
              SettingsTile.switchTile(
                leading: Icons.vpn_key_rounded,
                onToggle: (value) => _setProxyEnabled(value ?? !proxyEnabled),
                title: const Text('启用代理'),
                description: const Text('启用后网络请求将通过代理服务器'),
                initialValue: proxyEnabled,
              ),
              SettingsTile(
                leading: Icons.tune_rounded,
                onPressed: (_) async {
                  await context.pushNamed('/settings/proxy/editor');
                  if (mounted) setState(() {});
                },
                title: const Text('代理配置'),
                description: const Text('配置代理服务器地址和认证信息'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
