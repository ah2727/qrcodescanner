import 'package:flutter/material.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:qrcodescanner/storage/key_store.dart';
import 'package:provider/provider.dart';
import 'core/theme/theme_controller.dart';
import 'package:qrcodescanner/features/profiles/view/profiles_page.dart'; // your page
import 'auth/auth_service.dart';

import 'app/app_shell.dart';
import 'auth/auth_gate.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  if (!Hive.isBoxOpen(kKeysBox)) {
    await Hive.openBox(kKeysBox); // keys_box (dynamic)
  }
  if (!Hive.isBoxOpen('config_history')) {
    // Use the same generic type everywhere: String OR Map (pick one).
    await Hive.openBox<String>('config_history');
  }
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeController()),
        ChangeNotifierProvider(
          create: (_) => AuthService()..init(),
        ), // ← makes it available app-wide
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF646CFF));
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorScheme: scheme),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF646CFF),
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system,
      home: const AuthGate(), // decide Login vs Home here
    );
  }
}
