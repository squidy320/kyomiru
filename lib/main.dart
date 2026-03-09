import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:async';

import 'app_shell.dart';
import 'package:kyomiru_flutter/core/app_logger.dart';

const MethodChannel _androidDiagChannel = MethodChannel('kyomiru/android_diag');

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

class _DesktopWindowStatePersistence with WindowListener {
  _DesktopWindowStatePersistence(this._prefs);

  final SharedPreferences _prefs;
  Timer? _saveDebounce;

  static const _keyX = 'desktop_window_x';
  static const _keyY = 'desktop_window_y';
  static const _keyW = 'desktop_window_w';
  static const _keyH = 'desktop_window_h';

  Future<void> restore() async {
    final x = _prefs.getDouble(_keyX);
    final y = _prefs.getDouble(_keyY);
    final w = _prefs.getDouble(_keyW);
    final h = _prefs.getDouble(_keyH);
    if (x == null || y == null || w == null || h == null) return;
    final width = w.clamp(900.0, 3840.0);
    final height = h.clamp(600.0, 2160.0);
    // If stale coordinates were saved (monitor disconnected), recenter.
    if (x < -10000 || y < -10000 || x > 100000 || y > 100000) {
      await windowManager.setSize(Size(width, height));
      await windowManager.center();
      return;
    }
    await windowManager.setBounds(Rect.fromLTWH(x, y, width, height));
  }

  @override
  void onWindowMove() => _scheduleSave();

  @override
  void onWindowResize() => _scheduleSave();

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 350), () async {
      try {
        final b = await windowManager.getBounds();
        await _prefs.setDouble(_keyX, b.left);
        await _prefs.setDouble(_keyY, b.top);
        await _prefs.setDouble(_keyW, b.width);
        await _prefs.setDouble(_keyH, b.height);
      } catch (_) {}
    });
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

Future<void> _runOneTimeMigrations() async {
  Box<dynamic>? settingsBox;
  try {
    settingsBox = Hive.box('app_settings');
  } catch (e, st) {
    AppLogger.w(
      'Boot',
      'Could not access app_settings for migrations',
      error: e,
      stackTrace: st,
    );
    return;
  }

  Future<void> runOnce(
    String key,
    Future<void> Function() migration,
  ) async {
    final done = settingsBox?.get(key) == true;
    if (done) return;
    try {
      await migration();
      await settingsBox?.put(key, true);
      AppLogger.i('Boot', 'Migration completed: $key');
    } catch (e, st) {
      AppLogger.w(
        'Boot',
        'Migration failed: $key',
        error: e,
        stackTrace: st,
      );
    }
  }

  await runOnce('migration_query_cache_reset_v1', () async {
    const boxName = 'anilist_query_cache';
    try {
      if (Hive.isBoxOpen(boxName)) {
        await Hive.box(boxName).close();
      }
    } catch (_) {}
    await Hive.deleteBoxFromDisk(boxName);
  });

  await runOnce('migration_tracking_id_title_keys_cleanup_v1', () async {
    const boxName = 'anilist_tracking_id_map';
    final wasOpen = Hive.isBoxOpen(boxName);
    final box = wasOpen
        ? Hive.box<dynamic>(boxName)
        : await Hive.openBox<dynamic>(boxName);
    final keys = box.keys.map((k) => k.toString()).toList(growable: false);
    for (final key in keys) {
      if (key.startsWith('title:')) {
        await box.delete(key);
      }
    }
    if (!wasOpen) {
      await box.close();
    }
  });

  await runOnce('migration_query_cache_reset_v2_tracking_live_only', () async {
    const boxName = 'anilist_query_cache';
    try {
      if (Hive.isBoxOpen(boxName)) {
        await Hive.box(boxName).close();
      }
    } catch (_) {}
    await Hive.deleteBoxFromDisk(boxName);
  });
}

Future<void> _runAndroidNetworkDiagnostics() async {
  if (!Platform.isAndroid) return;
  try {
    final info = await _androidDiagChannel
        .invokeMapMethod<String, dynamic>('networkDiagnostics');
    AppLogger.i('AndroidNet', 'Native diagnostics: ${info ?? const {}}');
  } catch (e, st) {
    AppLogger.w(
      'AndroidNet',
      'Failed to read Android native network diagnostics',
      error: e,
      stackTrace: st,
    );
  }

  Future<void> probeHost(String host) async {
    try {
      final results =
          await InternetAddress.lookup(host).timeout(const Duration(seconds: 6));
      final first = results.isNotEmpty ? results.first.address : 'none';
      AppLogger.i('AndroidNet', 'DNS ok host=$host resolved=$first');
    } catch (e, st) {
      AppLogger.w(
        'AndroidNet',
        'DNS failed host=$host',
        error: e,
        stackTrace: st,
      );
    }
  }

  await probeHost('anilist.co');
  await probeHost('graphql.anilist.co');
  await probeHost('git.luna-app.eu');
  await probeHost('raw.githubusercontent.com');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLogger.initializeSessionFileLogging();
  _DesktopWindowStatePersistence? desktopWindowPersistence;
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    await Window.initialize();
    const options = WindowOptions(
      minimumSize: Size(900, 600),
      size: Size(1280, 800),
      center: true,
      title: 'kyomiru',
      titleBarStyle: TitleBarStyle.hidden,
      windowButtonVisibility: false,
      backgroundColor: Colors.transparent,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      try {
        if (Platform.isWindows) {
          await Window.setEffect(
            effect: WindowEffect.mica,
            dark: true,
            color: Colors.transparent,
          );
        } else if (Platform.isMacOS) {
          await Window.setEffect(
            effect: WindowEffect.sidebar,
            color: Colors.transparent,
          );
        }
      } catch (e, st) {
        AppLogger.w(
          'Boot',
          'Window acrylic/vibrancy setup failed',
          error: e,
          stackTrace: st,
        );
      }

      final prefs = await SharedPreferences.getInstance();
      desktopWindowPersistence = _DesktopWindowStatePersistence(prefs);
      windowManager.addListener(desktopWindowPersistence!);
      await desktopWindowPersistence!.restore();
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
  await _runAndroidNetworkDiagnostics();
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
  await _runOneTimeMigrations();
  // Keep query cache lazy-open only. On some legacy iOS installs this box
  // can contain stale adapter payloads and trigger platform-level errors
  // during boot. AniListClient opens/uses it opportunistically when safe.
  final liquidGlassEnabled = await _runShaderWarmup();
  runApp(
    ProviderScope(
      child: KyomiruApp(liquidGlassEnabled: liquidGlassEnabled),
    ),
  );
}
