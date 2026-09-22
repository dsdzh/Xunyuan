import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';

import '../core/source_health.dart';
import '../models/book_source.dart';
import '../state/app_state.dart';
import 'search_page.dart';

class SourcePage extends StatelessWidget {
  const SourcePage({super.key});

  Future<void> _importFromText(BuildContext context, String text) async {
    final state = context.read<SourceState>();
    final count = await state.importText(text);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(count > 0 ? '成功导入 $count 个书源' : '未解析到有效书源（需为 Legado JSON 格式）')),
    );
  }

  Future<void> _importFromClipboard(BuildContext context) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.trim().isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('剪贴板为空')));
      }
      return;
    }
    if (!context.mounted) return;
    await _importFromText(context, text);
  }

  Future<void> _importFromFile(BuildContext context) async {
    final String text;
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'txt'],
      );
      final file = files.isNotEmpty ? files.first : null;
      if (file == null) return;
      text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
    } catch (_) {
      // content:// 解析失败、文件被移动等都会在这里抛
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('文件读取失败')));
      }
      return;
    }
    if (text.trim().isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('文件内容为空')));
      }
      return;
    }
    if (!context.mounted) return;
    await _importFromText(context, text);
  }

  Future<void> _importFromUrl(BuildContext context) async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从 URL 导入书源'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: 'https://.../bookSource.json'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('导入')),
        ],
      ),
    );
    controller.dispose();
    if (url == null || url.trim().isEmpty) return;
    if (!context.mounted) return;
    final state = context.read<SourceState>();
    try {
      final count = await state.importFromUrl(url);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(count > 0 ? '成功导入 $count 个书源' : '链接内容中未解析到有效书源（需为 Legado JSON 格式）')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导入失败: $e')));
      }
    }
  }

  Future<void> _exportAll(BuildContext context) async {
    final state = context.read<SourceState>();
    final json = state.exportAll();
    await Clipboard.setData(ClipboardData(text: json));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('全部书源已复制到剪贴板')));
    }
  }

  Future<void> _checkHealthAll(BuildContext context) async {
    final state = context.read<SourceState>();
    final targets = state.sources.where((s) => s.enabled).toList();
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('没有已启用的书源')));
      return;
    }
    unawaited(state.checkHealth(targets));
  }

  Widget _healthBadge(BuildContext context, SourceState state, BookSource s) {
    final h = state.health[s.bookSourceUrl];
    if (h == null) {
      return state.healthChecking
          ? const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : const SizedBox.shrink();
    }
    final (color, label) = switch (h.level) {
      HealthLevel.ok => (Colors.green, '可用'),
      HealthLevel.searchOnly => (Colors.orange, '仅搜索'),
      HealthLevel.tocNoContent => (Colors.deepOrange, '缺正文'),
      _ => (Colors.red, '不可用'),
    };
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: InkWell(
        onTap: () => _showHealthDetail(context, s, h),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: .15),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(label, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }

  Future<void> _showHealthDetail(BuildContext context, BookSource s, SourceHealth h) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${s.bookSourceName} · ${HealthLevel.label(h.level)}'),
        content: Text('耗时：${h.latencyMs}ms\n'
            '结果：${h.message.isEmpty ? '无附加信息' : h.message}\n'
            '时间：${DateTime.fromMillisecondsSinceEpoch(h.checkedAt).toString().substring(0, 19)}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
          FilledButton.tonal(
            onPressed: () {
              Navigator.pop(ctx);
              unawaited(context.read<SourceState>().checkHealth([s]));
            },
            child: const Text('重新检测此书源'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<SourceState>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('书源管理'),
        centerTitle: true,
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              switch (v) {
                case 'clipboard':
                  _importFromClipboard(context);
                case 'file':
                  _importFromFile(context);
                case 'url':
                  _importFromUrl(context);
                case 'export':
                  _exportAll(context);
                case 'health':
                  _checkHealthAll(context);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'clipboard', child: Text('从剪贴板导入')),
              const PopupMenuItem(value: 'file', child: Text('从文件导入')),
              const PopupMenuItem(value: 'url', child: Text('从 URL 导入')),
              const PopupMenuItem(value: 'export', child: Text('导出全部到剪贴板')),
              PopupMenuItem(
                value: 'health',
                enabled: !state.healthChecking,
                child: Text(state.healthChecking ? '健康度检测中…' : '检测书源健康度'),
              ),
            ],
          ),
        ],
      ),
      body: state.sources.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_upload_outlined, size: 64, color: Colors.grey.shade400),
                  const SizedBox(height: 12),
                  const Text('还没有书源，点击右上角导入'),
                  const SizedBox(height: 6),
                  const Text('支持 Legado（阅读3.0）书源 JSON 格式', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    icon: const Icon(Icons.content_paste_go),
                    label: const Text('从剪贴板导入'),
                    onPressed: () => _importFromClipboard(context),
                  ),
                ],
              ),
            )
          : ListView.separated(
              itemCount: state.sources.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final s = state.sources[i];
                final hasRule = (s.searchUrl?.isNotEmpty ?? false) || (s.exploreUrl?.isNotEmpty ?? false);
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: s.enabled && hasRule
                        ? const Color(0xFF2E7D5B)
                        : Colors.grey.shade400,
                    child: Icon(_typeIcon(s), size: 18, color: Colors.white),
                  ),
                  title: Text(s.bookSourceName, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        [
                          s.bookSourceGroup.isEmpty ? '未分组' : s.bookSourceGroup,
                          if ((s.searchUrl ?? '').isNotEmpty) '搜索' else '无搜索',
                          if ((s.exploreUrl ?? '').isNotEmpty) '发现',
                          if (!s.isNovel) _typeName(s),
                        ].join(' · '),
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      ),
                      if (!hasRule)
                        Text('无可用规则', style: TextStyle(fontSize: 11, color: Colors.orange.shade800)),
                    ],
                  ),
                  isThreeLine: !hasRule,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _healthBadge(context, state, s),
                      Switch(
                        value: s.enabled,
                        onChanged: (v) => state.toggle(s.bookSourceUrl, v),
                      ),
                    ],
                  ),
                  onTap: (s.searchUrl?.isNotEmpty ?? false)
                      ? () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => _SingleSourceSearch(source: s),
                          ))
                      : null,
                  onLongPress: () => _confirmDelete(context, state, s),
                );
              },
            ),
    );
  }

  IconData _typeIcon(BookSource s) => switch (s.sourceType) {
        1 => Icons.auto_stories_outlined,
        2 => Icons.audiotrack,
        3 => Icons.movie_outlined,
        _ => Icons.menu_book_outlined,
      };

  String _typeName(BookSource s) => switch (s.sourceType) {
        1 => '漫画源',
        2 => '音频源',
        3 => '视频源',
        _ => '小说源',
      };

  Future<void> _confirmDelete(BuildContext context, SourceState state, BookSource s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除书源「${s.bookSourceName}」？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton.tonal(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) await state.remove(s.bookSourceUrl);
  }
}

/// 单书源搜索入口
class _SingleSourceSearch extends StatelessWidget {
  final BookSource source;
  const _SingleSourceSearch({required this.source});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(source.bookSourceName)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.travel_explore, size: 56, color: Colors.grey.shade400),
              const SizedBox(height: 16),
              Text('在「搜索」页中可通过右上角"选择书源"只勾选「${source.bookSourceName}」进行搜索',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade700)),
              const SizedBox(height: 20),
              FilledButton.tonal(
                onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(
                  builder: (_) => const SearchPage(),
                )),
                child: const Text('前往搜索页'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
