import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:async';

import 'app_shell.dart';
import 'package:kyomiru_flutter/core/app_logger.dart';

class LegacyType77Adapter extends TypeAdapter<Map<dynamic, dynamic>> {
  @override
  final int typeId = 77;

  @override
  Map<dynamic, dynamic> read(BinaryReader reader) {
    try {
      final value = reader.read();
      if (value is Map) return value;
    } catch (_) {}
    return <dynamic, dynamic>{};
  }

  @override
  void write(BinaryWriter writer, Map<dynamic, dynamic> obj) {
    writer.write(obj);
  }
}

class LegacyType78Adapter extends TypeAdapter<Map<dynamic, dynamic>> {
  @override
  final int typeId = 78;

  @override
  Map<dynamic, dynamic> read(BinaryReader reader) {
    try {
      final value = reader.read();
      if (value is Map) return value;
    } catch (_) {}
    return <dynamic, dynamic>{};
  }

  @override
  void write(BinaryWriter writer, Map<dynamic, dynamic> obj) {
    writer.write(obj);
  }
}

class LegacyType79Adapter extends TypeAdapter<Map<dynamic, dynamic>> {
  @override
  final int typeId = 79;

  @override
  Map<dynamic, dynamic> read(BinaryReader reader) {
    try {
      final value = reader.read();
      if (value is Map) return value;
    } catch (_) {}
    return <dynamic, dynamic>{};
  }

  @override
  void write(BinaryWriter writer, Map<dynamic, dynamic> obj) {
    writer.write(obj);
  }
}

void _registerHiveAdapters() {
  // Keep adapter registration centralized so all typeIds are guaranteed
  // to be available before any box is opened.
  if (!Hive.isAdapterRegistered(77)) {
    Hive.registerAdapter(LegacyType77Adapter());
  }
  if (!Hive.isAdapterRegistered(78)) {
    Hive.registerAdapter(LegacyType78Adapter());
  }
  if (!Hive.isAdapterRegistered(79)) {
    Hive.registerAdapter(LegacyType79Adapter());
  }
  AppLogger.i(
    'Boot',
    'Hive adapters registered: type77=${Hive.isAdapterRegistered(77)} '
        'type78=${Hive.isAdapterRegistered(78)} '
        'type79=${Hive.isAdapterRegistered(79)}',
  );
}

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

Future<void> _openHiveBoxSafe(String name, {bool critical = true}) async {
  Future<void> closeIfOpen() async {
    if (Hive.isBoxOpen(name)) {
      await Hive.box(name).close();
    }
  }

  bool isUnknownTypeIdError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('unknown typeid');
  }

  try {
    await Hive.openBox(name);
    return;
  } catch (e, st) {
    AppLogger.w(
      'Boot',
      'Hive open failed for "$name", deleting box and retrying once',
      error: e,
      stackTrace: st,
    );
  }

  try {
    await closeIfOpen();
    await Hive.deleteBoxFromDisk(name);
  } catch (e, st) {
    AppLogger.w(
      'Boot',
      'Hive delete failed for "$name"',
      error: e,
      stackTrace: st,
    );
  }

  try {
    await Hive.openBox(name);
  } catch (e, st) {
    AppLogger.e(
      'Boot',
      'Hive second open failed for "$name"',
      error: e,
      stackTrace: st,
    );
    if (isUnknownTypeIdError(e) && !critical) {
      // Keep app booting if optional cache boxes are corrupted or use stale adapters.
      return;
    }
    if (critical) rethrow;
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLogger.initializeSessionFileLogging();
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      minimumSize: Size(900, 600),
      size: Size(1280, 800),
      center: true,
      title: 'kyomiru',
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  AppLogger.installGlobalHandlers();
  AppLogger.startUiFreezeWatchdog();
  AppLogger.i('App', 'Boot start');
  MediaKit.ensureInitialized();
  await Hive.initFlutter();
  _registerHiveAdapters();
  await _openHiveBoxSafe('episode_progress');
  await _openHiveBoxSafe('downloads');
  await _openHiveBoxSafe('app_settings');
  await _openHiveBoxSafe('manual_matches');
  await _openHiveBoxSafe('local_library');
  await _openHiveBoxSafe('watch_history');
  await _openHiveBoxSafe('anilist_media_cache', critical: false);
  await _openHiveBoxSafe('anilist_query_cache', critical: false);
  final liquidGlassEnabled = await _runShaderWarmup();
  runApp(
    ProviderScope(
      child: KyomiruApp(liquidGlassEnabled: liquidGlassEnabled),
    ),
  );
}
