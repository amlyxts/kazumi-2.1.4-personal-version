// 验证码自动识别服务 (方案A: WebView 内自动填码的 OCR 后端)
// 渠道列表用户可自定义 (网络设置 → 验证码自动识别 → OCR 渠道管理)。
// 一个渠道一个块: 同网关多模型写在渠道的 models 列表里 (按顺序轮询),
// 不同网关才分开渠道。存储 JSON 示例:
// [{"name","apiBase","apiKey","models":[{"model","maxTokens","thinkingDisabled"}]}]
// 旧版扁平格式 (渠道级 model 字段) 兼容解析并按 apiBase+apiKey 自动归并。
// 未配置时使用内置种子模板 (key 为空, 静默跳过)。
// 测试器同款经验: 思考型模型必须关思考+大 max_tokens; 统一浏览器 UA 过 CF。
// 密钥只存本地设置, 不进版本控制。
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 渠道内的单个模型配置
class OcrModelConfig {
  String model;
  int maxTokens;
  bool thinkingDisabled;

  OcrModelConfig({
    required this.model,
    this.maxTokens = 2048,
    this.thinkingDisabled = false,
  });

  factory OcrModelConfig.fromJson(dynamic json) {
    if (json is String) {
      return OcrModelConfig(model: json);
    }
    if (json is Map) {
      final map = Map<String, dynamic>.from(json);
      return OcrModelConfig(
        model: map['model']?.toString() ?? '',
        maxTokens: int.tryParse(map['maxTokens']?.toString() ?? '') ?? 2048,
        thinkingDisabled: map['thinkingDisabled'] == true,
      );
    }
    return OcrModelConfig(model: '');
  }

  Map<String, dynamic> toJson() => {
        'model': model,
        'maxTokens': maxTokens,
        'thinkingDisabled': thinkingDisabled,
      };

  bool get valid => model.isNotEmpty;
}

/// 单个 OCR 渠道 (一个网关一块, 内含多模型)
class OcrChannelConfig {
  String name;
  String apiBase;
  String apiKey;
  List<OcrModelConfig> models;

  OcrChannelConfig({
    required this.name,
    required this.apiBase,
    this.apiKey = '',
    required this.models,
  });

  factory OcrChannelConfig.fromJson(Map<String, dynamic> json) {
    final models = <OcrModelConfig>[];
    if (json['models'] is List) {
      models.addAll(
          (json['models'] as List).map(OcrModelConfig.fromJson));
    } else if (((json['model'] as String?) ?? '').isNotEmpty) {
      // 旧版扁平格式: 渠道级 model/maxTokens/thinkingDisabled
      models.add(OcrModelConfig(
        model: json['model'].toString(),
        maxTokens:
            int.tryParse(json['maxTokens']?.toString() ?? '') ?? 2048,
        thinkingDisabled: json['thinkingDisabled'] == true,
      ));
    }
    return OcrChannelConfig(
      name: json['name']?.toString() ?? '',
      apiBase: json['apiBase']?.toString() ?? '',
      apiKey: json['apiKey']?.toString() ?? '',
      models: models,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'apiBase': apiBase,
        'apiKey': apiKey,
        'models': [for (final m in models) m.toJson()],
      };

  bool get valid =>
      name.isNotEmpty && apiBase.isNotEmpty && models.isNotEmpty;

  String get modelNames => models.map((m) => m.model).join(' / ');
}

class CaptchaOcrService {
  CaptchaOcrService._();

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 30),
    validateStatus: (s) => s != null && s < 400,
  ));

  static const _browserUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  static const _prompt =
      '识别图中验证码, 验证码为4位字符, 仅由数字0-9和英文字母组成。只输出这4个字符, 不要任何其他内容';

  /// 内置种子模板: 用户未自定义时的渠道列表 (key 为空, 填上即用)
  static List<OcrChannelConfig> defaultChannels() => [
        OcrChannelConfig(
          name: 'bigmodel',
          apiBase: 'https://open.bigmodel.cn/api/paas/v4/chat/completions',
          models: [
            OcrModelConfig(
                model: 'glm-4.6v',
                maxTokens: 2048,
                thinkingDisabled: true),
            OcrModelConfig(model: 'glm-4v-flash', maxTokens: 1024),
          ],
        ),
        OcrChannelConfig(
          name: 'doulor',
          apiBase: 'https://api.doulor.cn/v1/chat/completions',
          models: [OcrModelConfig(
              model: 'workbuddy-glm-5.3-flash',
              maxTokens: 2048,
              thinkingDisabled: true)],
        ),
      ];

  /// 读取渠道列表: 设置里的 JSON 优先, 未配置/解析失败回落种子模板。
  /// 兼容旧扁平格式, 并把同 apiBase+apiKey 的条目自动归并为一个渠道。
  static List<OcrChannelConfig> loadChannels() {
    final raw = GStorage.getSetting(SettingsKeys.captchaOcrChannels);
    if (raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          final parsed = [
            for (final item in list)
              if (item is Map)
                OcrChannelConfig.fromJson(Map<String, dynamic>.from(item)),
          ];
          final merged = <OcrChannelConfig>[];
          for (final channel in parsed) {
            if (!channel.valid) continue;
            final existing = merged.indexWhere((c) =>
                c.apiBase == channel.apiBase && c.apiKey == channel.apiKey);
            if (existing >= 0) {
              merged[existing].models.addAll(channel.models);
            } else {
              merged.add(channel);
            }
          }
          final valid =
              merged.where((c) => c.models.isNotEmpty).toList();
          if (valid.isNotEmpty) return valid;
        }
      } catch (e) {
        KazumiLogger().w('CaptchaOcr: 渠道配置解析失败, 使用默认模板: $e');
      }
    }
    return defaultChannels();
  }

  /// 用户开关 (默认开); 所有渠道都没配 key 时视为功能不可用
  static bool get enabled =>
      !kDisableCaptchaOcr && GStorage.getSetting(SettingsKeys.captchaOcrEnable);

  static bool get configured =>
      loadChannels().any((c) => c.apiKey.isNotEmpty);

  /// 是否应自动尝试 (开关开 且 已配置至少一个渠道)
  static bool get autoEnabled => enabled && configured;

  /// 上次成功渠道名 (会话内记忆): 优先重试上次成功的渠道,
  /// 省去不稳定渠道逐个超时等待; 渠道被删除后自然失效
  static String? _lastSuccessChannelName;

  /// 识别验证码图片, 返回 4 位字母数字码; 全渠道失败返回 null。
  /// 渠道按列表顺序 (粘性优先), 渠道内模型按配置顺序轮询。
  static Future<String?> solve(Uint8List imageBytes) async {
    final imgB64 = base64Encode(imageBytes);
    final channels = loadChannels()..removeWhere((c) => c.apiKey.isEmpty);
    final sticky = _lastSuccessChannelName;
    if (sticky != null) {
      final idx = channels.indexWhere((c) => c.name == sticky);
      if (idx > 0) {
        channels.insert(0, channels.removeAt(idx));
      }
    }
    for (final channel in channels) {
      for (final model in channel.models) {
        try {
          final code = _sanitize(
              await _request(channel, model, imgB64)
                  .timeout(const Duration(seconds: 30)));
          if (code != null) {
            _lastSuccessChannelName = channel.name;
            return code;
          }
          KazumiLogger().w(
              'CaptchaOcr: ${channel.name}/${model.model} 结果位数异常, 换下一模型');
        } catch (e) {
          KazumiLogger()
              .w('CaptchaOcr: ${channel.name}/${model.model} 失败: $e');
        }
      }
    }
    return null;
  }

  static String? _sanitize(String raw) {
    final code = raw.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
    return code.length == 4 ? code : null;
  }

  static Future<String> _request(
      OcrChannelConfig channel, OcrModelConfig model, String imgB64) async {
    final body = <String, dynamic>{
      'model': model.model,
      'max_tokens': model.maxTokens,
      'messages': [
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': _prompt},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,$imgB64'},
            },
          ],
        },
      ],
    };
    if (model.thinkingDisabled) {
      body['thinking'] = {'type': 'disabled'};
    }
    final r = await _dio.post(
      channel.apiBase,
      options: Options(headers: {
        'Authorization': 'Bearer ${channel.apiKey}',
        'Content-Type': 'application/json',
        'User-Agent': _browserUa,
      }),
      data: body,
    );
    final d = r.data;
    if (d is Map && d['choices'] != null) {
      final content =
          (d['choices'][0]['message']['content'] as String?)?.trim() ?? '';
      if (content.isNotEmpty) return content;
    }
    throw Exception('OCR 响应无内容 (${model.model})');
  }
}
