import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'pages/main_page.dart';
import 'state/app_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = AppServices();
  await services.init();
  runApp(
    MultiProvider(providers: [
      Provider<AppServices>.value(value: services),
      ChangeNotifierProvider<SourceState>.value(value: services.sourceState),
      ChangeNotifierProvider<ShelfState>.value(value: services.shelfState),
      ChangeNotifierProvider<ReaderSettings>.value(value: services.readerSettings),
    ], child: const XunyuanApp()),
  );
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
