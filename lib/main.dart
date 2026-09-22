import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'pages/main_page.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = AppServices();
  try {
    await services.init();
    runApp(
      MultiProvider(providers: [
        Provider<AppServices>.value(value: services),
        ChangeNotifierProvider<SourceState>.value(value: services.sourceState),
        ChangeNotifierProvider<ShelfState>.value(value: services.shelfState),
        ChangeNotifierProvider<ReaderSettings>.value(value: services.readerSettings),
      ], child: const XunyuanApp()),
    );
  } catch (e, st) {
    // init 抛异常时若不兜底，runApp 永不执行 → 永久白/黑屏且无任何提示
    debugPrint('Xunyuan 启动失败: $e\n$st');
    runApp(_StartupError(message: '$e'));
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
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
                const Text('若反复出现，请尝试清除应用数据后重新打开',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
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
      home: const MainPage(),
    );
  }
}
