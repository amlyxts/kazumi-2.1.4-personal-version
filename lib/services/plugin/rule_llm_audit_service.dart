// [my修改] 规则 LLM 审查服务: 高危规则安装前的 AI 审读。
// 复用 OCR 渠道轮询机制 (纯文本任务, 不需要视觉), 输出判定+证据引用,
// 供安装警告对话框展示。定位: 过滤明显恶意 + 为人工核读划重点, 不是替代人工。
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/plugin/captcha_ocr_service.dart';

class RuleLlmAuditResult {
  final String verdict; // benign | suspicious | malicious | unknown
  final String summary;
  final List<({String risk, String evidence})> findings;

  const RuleLlmAuditResult({
    required this.verdict,
    required this.summary,
    required this.findings,
  });

  bool get malicious => verdict == 'malicious';
  bool get suspicious => verdict == 'suspicious';
}

class RuleLlmAuditService {
  RuleLlmAuditService._();

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 60),
    validateStatus: (s) => s != null && s < 400,
  ));

  /// 审查规则 JSON; 无可用渠道/全部失败返回 verdict=unknown。
  /// [ruleJson] 由调用方序列化 (安装前仅拿到条目名, 需先拉规则全文)。
  static Future<RuleLlmAuditResult> audit(String ruleJson) async {
    final channels = CaptchaOcrService.loadChannels()
      ..removeWhere((c) => c.apiKey.isEmpty);
    if (channels.isEmpty) {
      return const RuleLlmAuditResult(
          verdict: 'unknown', summary: '未配置 OCR/审查渠道', findings: []);
    }
    var ruleText = ruleJson;
    const maxLen = 12000;
    if (ruleText.length > maxLen) {
      ruleText = ruleText.substring(0, maxLen);
    }
    final prompt = '你是应用安全审计员。下面是一个动漫聚合应用的"规则"JSON, 它声明了搜索/播放某网站的方式。\n'
        '风险背景: 字段 antiCrawlerConfig.captchaScript (若存在) 会在应用内 WebView 中作为 JavaScript 原样执行——这是唯一的代码执行点。\n'
        '请审查整个 JSON, 重点审 captchaScript (如有), 检查:\n'
        '1. 数据外发: 向规则站点之外的地址发送任何数据 (fetch/XHR/Image.src/WebSocket/表单)\n'
        '2. 凭据与存储: document.cookie / localStorage / sessionStorage 的读取或写入\n'
        '3. 混淆: atob/unescape/字符串拼接构造 URL 或代码/eval/Function\n'
        '4. 页面劫持: location 跳转到非规则站点 / window.open / 钓鱼内容注入\n'
        '5. SSRF: 任何 URL 字段指向内网 (localhost/127.*/10.*/192.168.*/172.16-31.*)\n'
        '6. 其他可疑行为\n'
        '注意: 脚本访问/提交到规则站点自身域名属正常验证行为, 不算外发。\n'
        '严格输出以下 JSON (不要任何其他文字):\n'
        '{"verdict":"benign|suspicious|malicious","findings":[{"risk":"简述","evidence":"原文片段 (限80字)"}],"summary":"一句话结论"}\n'
        '--- 规则 JSON ---\n'
        '$ruleText';
    for (final channel in channels) {
      try {
        final body = <String, dynamic>{
          'model': channel.models.first.model,
          'max_tokens': 2048,
          'messages': [
            {'role': 'user', 'content': prompt},
          ],
          if (channel.models.first.thinkingDisabled)
            'thinking': {'type': 'disabled'}
          else
            'temperature': 0.1,
        };
        final r = await _dio.post(
          channel.apiBase,
          options: Options(headers: {
            'Authorization': 'Bearer ${channel.apiKey}',
            'Content-Type': 'application/json',
          }),
          data: body,
        );
        final d = r.data;
        if (d is! Map || d['choices'] == null) continue;
        var content =
            (d['choices'][0]['message']['content'] as String?)?.trim() ?? '';
        if (content.isEmpty) continue;
        if (content.startsWith('```')) {
          content = content
              .replaceAll(RegExp(r'^```[a-z]*\n?'), '')
              .replaceAll(RegExp(r'\n?```$'), '');
        }
        final start = content.indexOf('{');
        final end = content.lastIndexOf('}');
        if (start < 0 || end <= start) continue;
        final parsed =
            jsonDecode(content.substring(start, end + 1)) as Map?;
        if (parsed == null) continue;
        final findings = <({String risk, String evidence})>[];
        final rawFindings = parsed['findings'];
        if (rawFindings is List) {
          for (final f in rawFindings) {
            if (f is Map) {
              findings.add((
                risk: f['risk']?.toString() ?? '',
                evidence: f['evidence']?.toString() ?? '',
              ));
            }
          }
        }
        return RuleLlmAuditResult(
          verdict: parsed['verdict']?.toString() ?? 'unknown',
          summary: parsed['summary']?.toString() ?? '',
          findings: findings,
        );
      } catch (e) {
        KazumiLogger().w('RuleLlmAudit: ${channel.name} 失败: $e');
      }
    }
    return const RuleLlmAuditResult(
        verdict: 'unknown', summary: '审查渠道全部失败', findings: []);
  }

  static bool get configured {
    try {
      return CaptchaOcrService.configured;
    } catch (_) {
      return false;
    }
  }
}
