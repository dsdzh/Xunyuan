import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';

import '../core/source_health.dart';
import '../core/source_link.dart';
import '../models/book_source.dart';
import '../state/app_state.dart';
import 'search_page.dart';

class SourcePage extends StatefulWidget {
  const SourcePage({super.key});

  @override
  State<SourcePage> createState() => _SourcePageState();
}

class _SourcePageState extends State<SourcePage> {
  SourceState? _watched;
  bool _deadPromptOpen = false;

  /// 只在 build 里查 ModalRoute（InheritedWidget 依赖只能在构建期登记），
  /// 监听回调读这份缓存值：阅读页/详情页压在上面时不抢弹窗
  bool _routeIsCurrent = true;

  /// 归 State 管，而不是弹窗一关就 dispose：`showDialog` 的 Future 在点下「导入」
  /// 那一刻就完成，退场动画还要再重建弹窗子树若干帧，
  /// 提前释放会让里面的 TextField 用上已 dispose 的 controller（实测直接抛断言）。
  final TextEditingController _urlInput = TextEditingController();

  @override
  void initState() {
    super.initState();
    final state = context.read<SourceState>();
    _watched = state;
    state.addListener(_onHealthChanged);
  }

  @override
  void dispose() {
    _urlInput.dispose();
    _watched?.removeListener(_onHealthChanged);
    super.dispose();
  }

  /// 一轮健康度检测跑完，若还有不可用的源就当场问一次要不要删。
  /// 提示位是一次性的（take 过即清），不取就作废——菜单里那条「删除不可用书源（N）」
  /// 一直看得到条数，没必要攒着等下次进页面再补弹。
  void _onHealthChanged() {
    final state = _watched;
    if (state == null || _deadPromptOpen || !_routeIsCurrent) return;
    final n = state.takeUnusableNotice();
    if (n <= 0) return;
    _deadPromptOpen = true;
    // notifyListeners 可能正处在遍历监听者的中途，插路由要等本帧画完
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (mounted) await _deleteUnusableSources(context, state);
      } finally {
        _deadPromptOpen = false;
      }
    });
  }

  Future<void> _importFromText(BuildContext context, String text) async {
    final state = context.read<SourceState>();
    final r = await state.importText(text);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(r.isEmpty ? r.summary : '导入完成：${r.summary}')),
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
      // 上限护栏：数百 MB 的 .json 会让 readAsBytes+utf8.decode+jsonDecode 各分配整份副本而 OOM 崩溃
      // （http 路径有 20MB 流式限长，文件路径此前完全绕过；10000 条上限在解析后才生效，救不了）
      final p = file.path;
      if (p != null && File(p).lengthSync() > 32 * 1024 * 1024) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('文件过大（超过 32MB），请精简后再导入')));
        }
        return;
      }
      final bytes = await file.readAsBytes();
      if (bytes.length > 32 * 1024 * 1024) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('文件过大（超过 32MB），请精简后再导入')));
        }
        return;
      }
      text = utf8.decode(bytes, allowMalformed: true);
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
    _urlInput.clear();
    final pasted = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从 URL 导入书源'),
        content: TextField(
          controller: _urlInput,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: '链接、分享文案或整份书源 JSON'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, _urlInput.text), child: const Text('导入')),
        ],
      ),
    );
    if (pasted == null || pasted.trim().isEmpty) return;
    if (!context.mounted) return;
    final parsed = parsePastedSource(pasted);
    if (parsed.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('这段文字里没有链接，也不是书源内容。'
              '可以粘 http(s) 链接、带链接的分享文案，或改用「从剪贴板导入」整份 JSON')));
      return;
    }
    final state = context.read<SourceState>();
    try {
      final body = parsed.inlineBody;
      final url = parsed.url;
      final r = body != null
          ? await state.importText(body)
          : await state.importFromUrl(url!);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(r.isEmpty ? r.summary : '导入完成：${r.summary}')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败: ${parsed.url ?? '书源内容'} — $e')));
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

  Future<void> _deleteUnusableSources(BuildContext context, SourceState state) async {
    final targets = state.unusableSources;
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('没有「不可用」的书源：判死的、关着的、没规则的一个都没有')));
      return;
    }
    final counts = state.unusableCounts;
    final names = targets.take(8).map((s) => s.bookSourceName).join('、');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 ${targets.length} 个不可用书源？'),
        content: Text('${counts.entries.map((e) => '${e.key} ${e.value} 个').join('\n')}\n\n'
            '$names${targets.length > 8 ? ' 等' : ''}\n\n'
            '是真删：直接从书源列表里移除，不是把开关关掉。'
            '删除后无法恢复，需要时可重新导入同一份书源文件。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton.tonal(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final removed = await state.removeUnusableSources();
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('已删除 $removed 个不可用书源')));
    }
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
    // 徽章只报探测结果，「不可用」严格等于 HealthLevel.dead；
    // 清理的口径比它宽（还含关着的、没规则的），所以确认框里是分档列条数的，不拿徽章数当删除数。
    // 脏记录（level 读不出）单列成「记录异常」，不当成判死
    final (color, label) = switch (h.level) {
      HealthLevel.ok => (Colors.green, '可用'),
      HealthLevel.searchOnly => (Colors.orange, '仅搜索'),
      HealthLevel.tocNoContent => (Colors.deepOrange, '缺正文'),
      HealthLevel.dead => (Colors.red, '不可用'),
      _ => (Colors.grey, '记录异常'),
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
          child: Text(label,
              style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
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
    _routeIsCurrent = ModalRoute.of(context)?.isCurrent ?? true;
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
                case 'cleanup':
                  _deleteUnusableSources(context, state);
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
              PopupMenuItem(
                value: 'cleanup',
                enabled: !state.healthChecking,
                // 一条也没有也留着入口：用户点了才知道"当前没有用不了的源"，
                // 藏起来会让这个功能看起来不存在
                child: Text(state.unusableSources.isEmpty
                    ? '删除不可用书源'
                    : '删除不可用书源（${state.unusableSources.length}）'),
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
                  const Text('支持 Legado（阅读3.0）书源 JSON 及常见转换格式', style: TextStyle(fontSize: 12, color: Colors.grey)),
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
