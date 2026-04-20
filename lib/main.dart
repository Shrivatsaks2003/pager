import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:pager/firebase_options.dart';
import 'package:pager/models/active_session.dart';
import 'package:pager/models/pager_device.dart';
import 'package:pager/screens/auth_gate.dart';
import 'package:pager/services/app_config_service.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Lock portrait mode
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  await Hive.initFlutter();

  Hive.registerAdapter(PagerDeviceAdapter());
  Hive.registerAdapter(ActiveSessionAdapter());

  await Hive.openBox<PagerDevice>('pagers');
  await Hive.openBox<ActiveSession>('sessions');
  await Hive.openBox<String>(AppConfigService.boxName);

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
      home: const AuthGate(),
    );
  }
}
