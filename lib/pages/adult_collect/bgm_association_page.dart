import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/services/bgm/bgm_web_service.dart';
import 'package:kazumi/services/storage/storage.dart';

/// [my新增] bgm 已关联管理页 — 从 ✨ 弹窗分出 (原内嵌 200px 列表拥挤):
/// 搜索过滤 / 封面缩略 / 本地条目对照 / 解除关联 / 打开 bgm 条目页。
class BgmAssociationPage extends StatefulWidget {
  const BgmAssociationPage({super.key});

  @override
  State<BgmAssociationPage> createState() => _BgmAssociationPageState();
}

class _BgmAssociationPageState extends State<BgmAssociationPage> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<(String, Map<String, dynamic>, String, String?)> _rows() {
    final map = BgmWebService.loadMap();
    final localById = {
      for (final c in GStorage.collectibles.values)
        c.bangumiItem.id.toString(): c,
    };
    final out =
        <(String, Map<String, dynamic>, String, String?)>[];
    map.forEach((key, v) {
      final local = localById[key];
      final bgmName =
          ((v['nameCn'] as String?) ?? '').isNotEmpty ? v['nameCn'] as String : (v['name'] as String? ?? '?');
      final localName = local == null
          ? null
          : (local.bangumiItem.nameCn.isNotEmpty
              ? local.bangumiItem.nameCn
              : local.bangumiItem.name);
      final q = _query.trim().toLowerCase();
      if (q.isNotEmpty &&
          !bgmName.toLowerCase().contains(q) &&
          !(localName?.toLowerCase().contains(q) ?? false) &&
          !(v['bgmId'].toString().contains(q))) {
        return;
      }
      out.add((key, v, bgmName, localName));
    });
    out.sort((a, b) => a.$3.compareTo(b.$3));
    return out;
  }

  Future<void> _unlink(String key) async {
    final confirmed = await KazumiDialog.show<bool>(
      builder: (context) => AlertDialog(
        title: const Text('解除关联', style: TextStyle(fontSize: 16)),
        content: const Text('解除后该条目的改分类/删除不再同步 bgm。确定？'),
        actions: [
          TextButton(
            onPressed: KazumiDialog.dismiss,
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('解除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    BgmWebService.removeAssociation(key);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows();
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('bgm 已关联 (${rows.length} 条)',
            style: const TextStyle(fontSize: 16)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                hintText: '搜名称 / bgm ID',
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 16),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Expanded(
            child: rows.isEmpty
                ? Center(
                    child: Text('暂无关联',
                        style: TextStyle(
                            fontSize: 13,
                            color: theme.colorScheme.onSurfaceVariant)))
                : ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final (key, v, bgmName, localName) = rows[index];
                      final bgmId = (v['bgmId'] as num?)?.toInt() ?? 0;
                      final score = v['score'];
                      final cover = (v['coverUrl'] as String?) ?? '';
                      return ListTile(
                        dense: true,
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: SizedBox(
                            width: 40,
                            height: 56,
                            child: cover.isEmpty
                                ? const ColoredBox(
                                    color: Colors.black12,
                                    child: SizedBox.shrink())
                                : CachedNetworkImage(
                                    imageUrl: cover,
                                    fit: BoxFit.cover,
                                    errorWidget: (_, __, ___) =>
                                        const ColoredBox(
                                            color: Colors.black12,
                                            child: SizedBox.shrink()),
                                  ),
                          ),
                        ),
                        title: Text(bgmName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13)),
                        subtitle: Text(
                          'bgm $bgmId · 评分 $score'
                          '${localName == null ? ' · 本地条目不存在' : ' · $localName'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 11),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.open_in_new, size: 18),
                              tooltip: '打开 bgm 条目页',
                              onPressed: bgmId <= 0
                                  ? null
                                  : () => launchUrl(
                                        Uri.parse(
                                            'https://bgm.tv/subject/$bgmId'),
                                        mode: LaunchMode.externalApplication,
                                      ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.link_off, size: 18),
                              tooltip: '解除关联',
                              onPressed: () => _unlink(key),
                            ),
                          ],
                        ),
                        onTap: bgmId <= 0
                            ? null
                            : () => launchUrl(
                                  Uri.parse('https://bgm.tv/subject/$bgmId'),
                                  mode: LaunchMode.externalApplication,
                                ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
