import 'package:flutter/material.dart';

import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/services/bgm/bgm_web_service.dart';

/// [my新增] bgm 候选选择弹窗 (共享组件) — 展示条目名 + 网页搜索候选
/// (每条带 bgm ID), 用户挑一个。返回选中 ID; 取消/未选返回 null。
Future<int?> showBgmCandidateDialog(
  BuildContext context,
  String title,
  List<BgmWebSubject> candidates,
) async {
  final shown = candidates.take(30).toList();
  int? picked = shown.length == 1 ? shown.first.id : null;
  final confirmed = await KazumiDialog.show<bool>(
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text(title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16)),
        content: SizedBox(
          width: 420,
          height: 320,
          child: ListView.builder(
            itemCount: shown.length,
            itemBuilder: (context, index) {
              final c = shown[index];
              return RadioListTile<int>(
                value: c.id,
                groupValue: picked,
                title: Text(c.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13)),
                subtitle: Text('bgm ID: ${c.id}',
                    style: const TextStyle(fontSize: 11)),
                dense: true,
                onChanged: (v) => setDialogState(() => picked = v),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: KazumiDialog.dismiss,
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
  if (confirmed != true || picked == null) return null;
  return picked;
}
