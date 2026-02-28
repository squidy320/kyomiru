import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'app_shell.dart';
import 'package:kyomiru_flutter/core/app_logger.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  AppLogger.installGlobalHandlers();
  AppLogger.i('App', 'Boot start');
  await Hive.initFlutter();
  await Hive.openBox('episode_progress');
  await Hive.openBox('downloads');
  await Hive.openBox('app_settings');
  await Hive.openBox('manual_matches');
  await Hive.openBox('local_library');
  runApp(const ProviderScope(child: KyomiruApp()));
}





