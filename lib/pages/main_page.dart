import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/storage_service.dart';
import '../widgets/tab_switcher.dart';
import 'bookshelf_page.dart';
import 'explore_page.dart';
import 'search_page.dart';
import 'source_page.dart';

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  State<MainPage> createState() => _MainPageState();
}

/// 启动期抢救过坏盒就一次性说清楚：不然大半书源凭空没了，
/// 用户只会以为 App 吞数据。弹出即清空，避免重建页面重复弹。
Future<void> showRecoveryNotes(BuildContext context, List<String> notes) async {
  if (notes.isEmpty || !context.mounted) return;
  final text = notes.join('\n\n');
  notes.clear();
  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('本地数据已尽量修复'),
      content: SizedBox(width: 320, child: SingleChildScrollView(child: Text(text))),
      actions: [
        FilledButton.tonal(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
      ],
    ),
  );
}

class _MainPageState extends State<MainPage> {
  int _index = 0;
  bool _exitPromptOpen = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showRecoveryNotes(context, StorageService.instance.recoveryNotes);
    });
  }

  void _select(int i) {
    if (i == _index) return;
    setState(() => _index = i);
  }

  // 主页是根路由，返回键等于退出 App：先确认，避免误触直接杀掉进程。
  Future<void> _confirmExit() async {
    if (_exitPromptOpen) return;
    _exitPromptOpen = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出寻源'),
        content: const Text('确定退出应用吗？书架与阅读进度已保存。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton.tonal(onPressed: () => Navigator.pop(ctx, true), child: const Text('退出')),
        ],
      ),
    );
    _exitPromptOpen = false;
    if (ok == true) await SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    const pages = [
      BookshelfPage(),
      ExplorePage(),
      SearchPage(),
      SourcePage(),
    ];
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmExit();
      },
      child: Scaffold(
        body: TabSwitcher(index: _index, children: pages),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: _select,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.book_outlined), selectedIcon: Icon(Icons.book), label: '书架'),
            NavigationDestination(icon: Icon(Icons.explore_outlined), selectedIcon: Icon(Icons.explore), label: '发现'),
            NavigationDestination(icon: Icon(Icons.search), label: '搜索'),
            NavigationDestination(icon: Icon(Icons.library_books_outlined), selectedIcon: Icon(Icons.library_books), label: '书源'),
          ],
        ),
      ),
    );
  }
}
