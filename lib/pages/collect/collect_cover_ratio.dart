part of 'collect_library_view.dart';

/// [my新增] 封面自然比例解析器 (仅瀑布流档使用): 经 flutter_cache_manager
/// 取封面字节 (磁盘命中为快路径, 未命中顺带下载 — 与 CachedNetworkImage
/// 共用同一缓存, 等于预热带封面), ui 解码头部得 w/h → 比例。
/// [my修复] 比例持久化到设置框: 首次遇到新封面时异步解析会逐卡跳动,
/// 持久化后二次进页按存值直接首建, 不再当场变形。失败/无图保持兜底
/// 比例 0.65。
class _CoverRatioResolver {
  _CoverRatioResolver._();

  static final Map<String, double> _cache = {};
  static bool _loaded = false;
  static Timer? _persistDebounce;

  static const int _maxEntries = 500;

  static double ratioFor(String url) {
    _ensureLoaded();
    return _cache[url] ?? _CollectPosterCard._coverRatio;
  }

  static void _ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw =
          GStorage.getSetting(SettingsKeys.collectCoverRatioCache).trim();
      if (raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        decoded.forEach((k, v) {
          final r = (v as num?)?.toDouble();
          if (k.toString().isNotEmpty && r != null && r > 0) {
            _cache[k.toString()] = r;
          }
        });
      }
    } catch (_) {
      // 坏数据按无缓存处理, 后续解析会重写
    }
  }

  static void _schedulePersist() {
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(milliseconds: 1500), () {
      try {
        GStorage.putSetting(
            SettingsKeys.collectCoverRatioCache, jsonEncode(_cache));
      } catch (_) {}
    });
  }

  /// 解析并回填缓存; 完成后回调 (调用方 setState)。幂等: 已有结果直接回调。
  static Future<void> resolve(String url, {VoidCallback? onResolved}) async {
    _ensureLoaded();
    if (url.isEmpty || _cache.containsKey(url)) {
      onResolved?.call();
      return;
    }
    try {
      final file = await DefaultCacheManager().getSingleFile(url);
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return;
      final codec = await ui.instantiateImageCodec(bytes, targetHeight: 16);
      final frame = await codec.getNextFrame();
      final w = frame.image.width;
      final h = frame.image.height;
      frame.image.dispose();
      codec.dispose();
      if (w > 0 && h > 0) {
        _cache[url] = w / h;
        while (_cache.length > _maxEntries) {
          _cache.remove(_cache.keys.first);
        }
        _schedulePersist();
        onResolved?.call();
      }
    } catch (e) {
      // 解析失败保持兜底比例, 静默 (日志噪音不值)
    }
  }
}
