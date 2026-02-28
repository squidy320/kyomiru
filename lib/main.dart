import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'app_shell.dart';
import 'package:kyomiru_flutter/core/app_logger.dart';

class KyomiruShaderWarmUp extends ShaderWarmUp {
  const KyomiruShaderWarmUp();

  @override
  Future<void> warmUpOnCanvas(Canvas canvas) async {
    final paintA = Paint()..color = const Color(0xFFFFFFFF);
    final paintB = Paint()..color = const Color(0x80000000);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 128, 128), paintA);
    canvas.drawCircle(const Offset(64, 64), 32, paintB);
  }
}

Future<bool> _runShaderWarmup() async {
  try {
    const warmup = KyomiruShaderWarmUp();
    PaintingBinding.shaderWarmUp = warmup;
    await warmup.execute().timeout(const Duration(seconds: 2));
    return true;
  } catch (e, st) {
    AppLogger.w(
      'Boot',
      'Shader warmup timed out/failed; using fallback UI',
      error: e,
      stackTrace: st,
    );
    return false;
  }
}

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
  await Hive.openBox('anilist_media_cache');
  await Hive.openBox('anilist_query_cache');
  final liquidGlassEnabled = await _runShaderWarmup();
  runApp(
    ProviderScope(
      child: KyomiruApp(liquidGlassEnabled: liquidGlassEnabled),
    ),
  );
}
