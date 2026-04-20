import 'package:hive_flutter/hive_flutter.dart';
import '../models/pager_device.dart';
import '../models/active_session.dart';
import 'app_config_service.dart';

class HiveService {
  static Future<void> init() async {
    await Hive.initFlutter();

    Hive.registerAdapter(PagerDeviceAdapter());
    Hive.registerAdapter(ActiveSessionAdapter());

    await Hive.openBox<PagerDevice>('pagers');
    await Hive.openBox<ActiveSession>('sessions');
    await Hive.openBox<String>(AppConfigService.boxName);
  }

  static Box<PagerDevice> get pagerBox => Hive.box<PagerDevice>('pagers');

  static Box<ActiveSession> get sessionBox =>
      Hive.box<ActiveSession>('sessions');
}
