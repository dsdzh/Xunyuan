import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'pages/main_page.dart';
import 'state/app_state.dart';
import 'widgets/display_scale.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _BootScreen());
}

/// 启动把服务初始化包成可重试的 Future。
/// 以前 init 一抛异常就定死在"启动失败"页，唯一的建议是清除应用数据 ——
/// 而本地数据大多还能救回来，让用户清数据等于把书架和书源全扔了。
class _BootScreen extends StatefulWidget {
  const _BootScreen();

  @override
  State<_BootScreen> createState() => _BootScreenState();
}

class _BootScreenState extends State<_BootScreen> {
  late Future<AppServices> _boot = _start();

  Future<AppServices> _start() async {
    final services = AppServices();
    try {
      await services.init();
      return services;
    } catch (e, st) {
      debugPrint('Xunyuan 启动失败: $e\n$st'); // 留 logcat 线索，页面上只给人话
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppServices>(
      future: _boot,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const MaterialApp(
            debugShowCheckedModeBanner: false,
            home: Scaffold(body: Center(child: CircularProgressIndicator())),
          );
        }
        if (snap.hasError) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            home: _StartupError(
              message: '${snap.error}',
              onRetry: () => setState(() => _boot = _start()),
            ),
          );
        }
        final services = snap.requireData;
        return MultiProvider(
          providers: [
            Provider<AppServices>.value(value: services),
            ChangeNotifierProvider<SourceState>.value(value: services.sourceState),
            ChangeNotifierProvider<ShelfState>.value(value: services.shelfState),
            ChangeNotifierProvider<ReaderSettings>.value(value: services.readerSettings),
          ],
          child: const XunyuanApp(),
        );
      },
    );
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 44, color: Color(0xFFB00020)),
              const SizedBox(height: 16),
              const Text('寻源启动失败',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 12),
              const Text('重试不会清除本地数据（书架、书源、进度都还在）',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 20),
              FilledButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ),
        ),
      ),
    );
  }
}

class XunyuanApp extends StatelessWidget {
  const XunyuanApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<ReaderSettings>();
    return MaterialApp(
      title: '寻源',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2E7D5B)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D5B),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      // builder 在 Navigator 之上，所以弹层/对话框/键盘 insets 一起跟着缩放
      builder: (context, child) => DisplayScale(
        dpi: settings.dpiScale,
        screenWidthDp: settings.screenWidthDp,
        child: child!,
      ),
      home: const _BootFade(child: MainPage()),
    );
  }
}

/// 加载圈到主页之间不要整块硬切，淡入一下，读起来才像同一个启动过程
class _BootFade extends StatefulWidget {
  const _BootFade({required this.child});
  final Widget child;

  @override
  State<_BootFade> createState() => _BootFadeState();
}

class _BootFadeState extends State<_BootFade> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 320))..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: CurveTween(curve: Curves.easeOut).animate(_c),
      child: widget.child,
    );
  }
}
