import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webview_windows/webview_windows.dart';

import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/services/bgm/bgm_web_service.dart';
import 'package:kazumi/services/storage/storage.dart';

/// [my新增] bgm 内嵌浏览器登录页 — bgm 登录 POST 有指纹级反爬 (非浏览器
/// 传输一律"验证码错误", 自动登录不可达), 改用真 WebView 让用户手动登录:
/// 真 Chromium 指纹 + 人填验证码 (5 位区分大小写) 必过; 轮询检测到登录态
/// cookie (chii_auth, httpOnly 也可由 WebView2 原生 CookieManager 读出)
/// 后自动提取入库, 搜索线立即可用。仅 Windows (R18 功能本就 PC 专属)。
class BgmLoginWebviewPage extends StatefulWidget {
  const BgmLoginWebviewPage({super.key});

  @override
  State<BgmLoginWebviewPage> createState() => _BgmLoginWebviewPageState();
}

class _BgmLoginWebviewPageState extends State<BgmLoginWebviewPage> {
  final WebviewController _controller = WebviewController();
  Timer? _pollTimer;
  bool _initialized = false;
  bool _saved = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await _controller.initialize();
      await _controller.setPopupWindowPolicy(
          WebviewPopupWindowPolicy.deny);
      await _controller.loadUrl('https://bgm.tv/login');
      if (mounted) setState(() => _initialized = true);
      _pollTimer = Timer.periodic(
          const Duration(milliseconds: 1500), (_) => _checkLogin());
    } catch (e) {
      if (mounted) setState(() => _error = 'WebView 初始化失败: $e');
    }
  }

  Future<void> _checkLogin() async {
    if (_saved || !mounted) return;
    try {
      final cookies = await _controller.getCookies('https://bgm.tv') ?? '';
      if (cookies.contains('chii_auth=') &&
          !cookies.contains('chii_auth=deleted')) {
        _saved = true;
        _pollTimer?.cancel();
        await GStorage.putSetting(SettingsKeys.bgmWebCookie, cookies.trim());
        BgmWebService.resetCookieOverride();
        if (!mounted) return;
        KazumiDialog.showToast(message: 'bgm 登录成功, cookie 已自动入库');
        Navigator.of(context).pop(true);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('bgm 浏览器登录', style: TextStyle(fontSize: 16)),
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(_saved),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _error.isNotEmpty
                ? Center(child: Text(_error, style: const TextStyle(fontSize: 13)))
                : !_initialized
                    ? const Center(child: CircularProgressIndicator())
                    : Webview(_controller),
          ),
          Material(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '在上方网页中登录 bgm.tv (验证码 5 位区分大小写)。'
                      '登录成功后自动提取 cookie 并返回, 无需任何手动操作。',
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
