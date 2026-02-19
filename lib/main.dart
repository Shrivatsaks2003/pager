import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:pager/models/active_session.dart';
import 'package:pager/models/pager_device.dart';
import 'theme/app_theme.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);

  await Hive.initFlutter();

  Hive.registerAdapter(PagerDeviceAdapter());
  Hive.registerAdapter(ActiveSessionAdapter());

  await Hive.openBox<PagerDevice>('pagers');
  await Hive.openBox<ActiveSession>('sessions');

  // 🔥 TEMPORARY: Clear old sessions (run once only)
  await Hive.box<ActiveSession>('sessions').clear();

  runApp(const PagerApp());
}

class PagerApp extends StatelessWidget {
  const PagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Pager',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      home: const HomeScreen(),
    );
  }
}
