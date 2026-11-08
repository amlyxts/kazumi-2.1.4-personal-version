import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/io_client.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/bangumi_ech_image_service.dart';
import 'package:kazumi/services/network/image_acceleration.dart';
import 'package:kazumi/services/network/image_file_service.dart';
import 'package:kazumi/services/network/proxy_utils.dart';
import 'package:kazumi/services/network/system_proxy_service.dart';
import 'package:kazumi/services/storage/storage.dart';

class ProxyAwareImageCacheManager extends CacheManager with ImageCacheManager {
  static final ProxyAwareImageCacheManager instance =
      ProxyAwareImageCacheManager._(
        ImageFileService(
          acceleration: () => ImageAcceleration.fromSetting(
            GStorage.getSetting(SettingsKeys.imageAcceleration),
          ),
          clientFactory: _createHttpClient,
          echService: BangumiEchImageService(proxyForUrl: _currentEchProxy),
        ),
      );

  ProxyAwareImageCacheManager._(this._fileService)
    : super(Config(DefaultCacheManager.key, fileService: _fileService));

  final ImageFileService _fileService;

  void resetNetworkClients() => _fileService.resetNetworkClients();

  @override
  Future<void> dispose() async {
    _fileService.close();
    await super.dispose();
  }

  static Uri? _currentEchProxy(Uri uri) {
    final proxy = _currentProxy();
    if (proxy != null) {
      return Uri(scheme: 'http', host: proxy.$1, port: proxy.$2);
    }
    if (Platform.isWindows) {
      final systemProxy = SystemProxyService.findProxy(uri);
      if (systemProxy.startsWith('PROXY ')) {
        return Uri.parse('http://${systemProxy.substring(6)}');
      }
    }
    return null;
  }

  static IOClient _createHttpClient() {
    final client = HttpClient();
    // [my修复·回退白名单直连] 实测: 封面 CDN 直连 TLS 握手 3.3s vs 代理
    // 0.88s; bangumi 图床直连完全不通。图片必须走代理 (Clash 对国内域自动
    // 直连, 绕本地一跳损失可忽略), 白名单直连方向相反。
    final proxy = _currentProxy();
    if (proxy != null) {
      client.findProxy = (_) => 'PROXY ${proxy.$1}:${proxy.$2}';
      client.badCertificateCallback = (cert, host, port) => true;
    } else if (Platform.isWindows) {
      client.findProxy = SystemProxyService.findProxy;
    }
    // HTTP/1.1 无多路复用: 限每主机连接数, 图墙复用连接而非每张图各付握手
    client.maxConnectionsPerHost = 8;
    return IOClient(client);
  }

  static (String, int)? _currentProxy() {
    if (!GStorage.getSetting(SettingsKeys.proxyEnable)) return null;

    final proxyUrl = GStorage.getSetting(SettingsKeys.proxyUrl);
    final parsed = ProxyUtils.parseProxyUrl(proxyUrl);
    if (parsed == null) {
      KazumiLogger().w('Proxy: 图片缓存代理地址格式错误或为空');
    }
    return parsed;
  }
}
