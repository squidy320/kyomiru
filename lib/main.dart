import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';

import 'app/app_shell.dart';
import 'core/app_logger.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  AppLogger.installGlobalHandlers();
  AppLogger.i('App', 'Boot start');
  await Hive.initFlutter();
  await Hive.openBox('episode_progress');
  await Hive.openBox('downloads');
  await Hive.openBox('app_settings');
  runApp(const ProviderScope(child: KyomiruApp()));
}
