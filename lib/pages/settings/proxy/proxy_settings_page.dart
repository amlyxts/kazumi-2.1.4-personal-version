import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/network_mirror_settings.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/pages/settings/proxy/ocr_channel_editor.dart';
import 'package:kazumi/pages/settings/proxy/rule_repo_editor.dart';
import 'package:kazumi/request/apis/plugin_catalog_api.dart';
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
