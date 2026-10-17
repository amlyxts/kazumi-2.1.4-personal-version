// OCR 渠道管理器: 验证码自动识别的渠道列表增删改/排序/持久化
// 一个渠道一个块: 同网关多模型写在渠道的 models 列表里, 不同网关才分开渠道。
// 存储格式: [{"name","apiBase","apiKey","models":[{"model","maxTokens","thinkingDisabled"}]}]
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:kazumi/services/plugin/captcha_ocr_service.dart';
import 'package:kazumi/services/storage/storage.dart';

/// 弹出渠道管理器。返回 true 表示有修改并已保存。
Future<bool> showOcrChannelManager(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => const _OcrChannelManagerDialog(),
  );
  return result == true;
}

class _OcrChannelManagerDialog extends StatefulWidget {
  const _OcrChannelManagerDialog();

  @override
  State<_OcrChannelManagerDialog> createState() =>
      _OcrChannelManagerDialogState();
}

class _OcrChannelManagerDialogState extends State<_OcrChannelManagerDialog> {
  late List<OcrChannelConfig> _channels;

  @override
  void initState() {
    super.initState();
    _channels = CaptchaOcrService.loadChannels();
  }

  void _saveAndPop() {
    final json = jsonEncode([for (final c in _channels) c.toJson()]);
    GStorage.putSetting(SettingsKeys.captchaOcrChannels, json);
    Navigator.of(context).pop(true);
  }

  Future<void> _editChannel(int index) async {
    final existing = index >= 0 ? _channels[index] : null;
    final edited = await showDialog<OcrChannelConfig>(
      context: context,
      builder: (_) => _OcrChannelEditorDialog(initial: existing),
    );
    if (edited == null) return;
    setState(() {
      if (index >= 0) {
        _channels[index] = edited;
      } else {
        _channels.add(edited);
      }
    });
  }

  void _move(int index, int delta) {
    final target = index + delta;
    if (target < 0 || target >= _channels.length) return;
    setState(() {
      final item = _channels.removeAt(index);
      _channels.insert(target, item);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      scrollable: true,
      title: const Text('OCR 渠道管理'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '同一网关的多个模型放在同一渠道内按顺序轮询，密钥为空的渠道自动跳过',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < _channels.length; i++)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  dense: true,
                  title: Text(_channels[i].name),
                  subtitle: Text(
                    '${_channels[i].modelNames}\n'
                    '${_channels[i].apiKey.isEmpty ? "未配置密钥" : "已配置密钥"}',
                    style: TextStyle(
                      color: _channels[i].apiKey.isEmpty
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  isThreeLine: true,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.arrow_upward_rounded, size: 20),
                        onPressed: i == 0 ? null : () => _move(i, -1),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon:
                            const Icon(Icons.arrow_downward_rounded, size: 20),
                        onPressed: i == _channels.length - 1
                            ? null
                            : () => _move(i, 1),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.edit_outlined, size: 20),
                        onPressed: () => _editChannel(i),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.delete_outline_rounded,
                            size: 20),
                        onPressed: () => setState(() => _channels.removeAt(i)),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 4),
            OutlinedButton.icon(
              onPressed: () => _editChannel(-1),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('添加渠道'),
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
          onPressed: _saveAndPop,
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 单渠道编辑对话框。[initial] 为 null 时是新增。
/// 渠道内模型以列表编辑: 每个模型可配 maxTokens 与"思考型"开关。
class _OcrChannelEditorDialog extends StatefulWidget {
  const _OcrChannelEditorDialog({this.initial});

  final OcrChannelConfig? initial;

  @override
  State<_OcrChannelEditorDialog> createState() =>
      _OcrChannelEditorDialogState();
}

class _OcrChannelEditorDialogState extends State<_OcrChannelEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _apiBase;
  late final TextEditingController _apiKey;
  late List<OcrModelConfig> _models;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initial?.name ?? '');
    _apiBase = TextEditingController(text: widget.initial?.apiBase ?? '');
    _apiKey = TextEditingController(text: widget.initial?.apiKey ?? '');
    _models = widget.initial == null || widget.initial!.models.isEmpty
        ? [OcrModelConfig(model: '')]
        : List.of(widget.initial!.models);
  }

  @override
  void dispose() {
    _name.dispose();
    _apiBase.dispose();
    _apiKey.dispose();
    super.dispose();
  }

  Future<void> _editModel(int index) async {
    final existing = index >= 0 ? _models[index] : null;
    final edited = await showDialog<OcrModelConfig>(
      context: context,
      builder: (_) => _OcrModelEditorDialog(initial: existing),
    );
    if (edited == null || edited.model.trim().isEmpty) return;
    setState(() {
      if (index >= 0) {
        _models[index] = edited;
      } else {
        _models.add(edited);
      }
    });
  }

  void _submit() {
    final name = _name.text.trim();
    final apiBase = _apiBase.text.trim();
    if (name.isEmpty || apiBase.isEmpty) {
      setState(() => _error = '名称与 API 地址不能为空');
      return;
    }
    final uri = Uri.tryParse(apiBase);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      setState(() => _error = 'API 地址格式无效');
      return;
    }
    final models =
        _models.where((m) => m.model.trim().isNotEmpty).toList();
    if (models.isEmpty) {
      setState(() => _error = '至少需要一个模型');
      return;
    }
    Navigator.of(context).pop(OcrChannelConfig(
      name: name,
      apiBase: apiBase,
      apiKey: _apiKey.text.trim(),
      models: models,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      scrollable: true,
      title: Text(widget.initial == null ? '添加渠道' : '编辑渠道'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(
                  labelText: '渠道名称', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _apiBase,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                  labelText: 'API 地址 (OpenAI 兼容 chat/completions)',
                  hintText: 'https://example.com/v1/chat/completions',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _apiKey,
              autocorrect: false,
              enableSuggestions: false,
              obscureText: true,
              decoration: const InputDecoration(
                  labelText: 'API Key', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
            Text('模型 (按顺序轮询)',
                style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            for (var i = 0; i < _models.length; i++)
              Card(
                margin: const EdgeInsets.only(bottom: 6),
                child: ListTile(
                  dense: true,
                  title: Text(_models[i].model.isEmpty
                      ? '(未命名模型)'
                      : _models[i].model),
                  subtitle: Text(
                    'maxTokens ${_models[i].maxTokens}'
                    '${_models[i].thinkingDisabled ? ' · 思考型' : ''}',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.edit_outlined, size: 20),
                        onPressed: () => _editModel(i),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.delete_outline_rounded,
                            size: 20),
                        onPressed: _models.length <= 1
                            ? null
                            : () => setState(() => _models.removeAt(i)),
                      ),
                    ],
                  ),
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _editModel(-1),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('添加模型'),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('确定'),
        ),
      ],
    );
  }
}

/// 单模型编辑对话框。[initial] 为 null 时是新增。
class _OcrModelEditorDialog extends StatefulWidget {
  const _OcrModelEditorDialog({this.initial});

  final OcrModelConfig? initial;

  @override
  State<_OcrModelEditorDialog> createState() => _OcrModelEditorDialogState();
}

class _OcrModelEditorDialogState extends State<_OcrModelEditorDialog> {
  late final TextEditingController _model;
  late final TextEditingController _maxTokens;
  late bool _thinkingDisabled;

  @override
  void initState() {
    super.initState();
    _model = TextEditingController(text: widget.initial?.model ?? '');
    _maxTokens = TextEditingController(
        text: widget.initial?.maxTokens.toString() ?? '2048');
    _thinkingDisabled = widget.initial?.thinkingDisabled ?? false;
  }

  @override
  void dispose() {
    _model.dispose();
    _maxTokens.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: Text(widget.initial == null ? '添加模型' : '编辑模型'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _model,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                  labelText: '模型名',
                  hintText: '如 glm-4.6v / glm-4v-flash / 自定义视觉模型',
                  border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _maxTokens,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'maxTokens', border: OutlineInputBorder()),
            ),
            SwitchListTile(
              title: const Text('思考型模型'),
              subtitle: const Text('glm-4.5v/4.6v 等需开启 (自动附加关闭思考参数)'),
              value: _thinkingDisabled,
              onChanged: (value) => setState(() => _thinkingDisabled = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(OcrModelConfig(
                model: _model.text.trim(),
                maxTokens: int.tryParse(_maxTokens.text.trim()) ?? 2048,
                thinkingDisabled: _thinkingDisabled,
              )),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
