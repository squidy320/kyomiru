import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:fvp/fvp.dart' as fvp;

import 'app/app_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  fvp.registerWith(options: {'lowLatency': 1});
  await Hive.initFlutter();
  await Hive.openBox('episode_progress');
  await Hive.openBox('downloads');
  await Hive.openBox('app_settings');
  runApp(const ProviderScope(child: KyomiruApp()));
}
