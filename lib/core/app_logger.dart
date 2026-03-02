import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Lightweight app logger with levels and tags.
class AppLogger {
  AppLogger._();

  static bool enabled = true;
  static const int _maxEntries = 1000;
  static final ValueNotifier<List<String>> entries =
      ValueNotifier<List<String>>(<String>[]);
  static IOSink? _sessionSink;
  static Future<void> _fileQueue = Future<void>.value();
  static String? _sessionLogPath;

  static void d(String tag, String message,
      {Object? error, StackTrace? stackTrace}) {
    _log('DEBUG', tag, message, error: error, stackTrace: stackTrace);
  }

  static void i(String tag, String message,
      {Object? error, StackTrace? stackTrace}) {
    _log('INFO', tag, message, error: error, stackTrace: stackTrace);
  }

  static void w(String tag, String message,
      {Object? error, StackTrace? stackTrace}) {
    _log('WARN', tag, message, error: error, stackTrace: stackTrace);
  }

  static void e(String tag, String message,
      {Object? error, StackTrace? stackTrace}) {
    _log('ERROR', tag, message, error: error, stackTrace: stackTrace);
  }

  static List<String> get snapshot => List<String>.from(entries.value);
  static String? get sessionLogPath => _sessionLogPath;

  static void clear() {
    entries.value = <String>[];
  }

  static String dumpAsText() => entries.value.join('\n');

  static void _append(String line) {
    final next = <String>[...entries.value, line];
    if (next.length > _maxEntries) {
      final removeCount = next.length - _maxEntries;
      next.removeRange(0, removeCount);
    }
    entries.value = next;
    _appendToFile(line);
  }

  static void _appendToFile(String line) {
    final sink = _sessionSink;
    if (sink == null) return;
    _fileQueue = _fileQueue.then((_) async {
      try {
        sink.writeln(line);
        await sink.flush();
      } catch (_) {}
    });
  }

  static void _log(
    String level,
    String tag,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (!enabled) return;
    final t = DateTime.now().toIso8601String();
    final line = '[$t][$level][$tag] $message';
    debugPrint(line);
    _append(line);
    if (error != null) {
      final e = '[$t][$level][$tag] error: $error';
      debugPrint(e);
      _append(e);
    }
    if (stackTrace != null) {
      final st = stackTrace.toString();
      debugPrint(st);
      for (final ln in st.split('\n')) {
        if (ln.trim().isEmpty) continue;
        _append('[$t][$level][$tag] $ln');
      }
    }
  }

  static Future<void> initializeSessionFileLogging() async {
    if (kIsWeb) return;
    try {
      final supportDir = await getApplicationSupportDirectory();
      final logsDir = Directory('${supportDir.path}/debug_logs');
      if (!await logsDir.exists()) {
        await logsDir.create(recursive: true);
      }

      final file = File('${logsDir.path}/last_run.log');
      if (await file.exists()) {
        await file.delete();
      }
      await file.create(recursive: true);

      _sessionSink?.close();
      _sessionSink = file.openWrite(mode: FileMode.writeOnlyAppend);
      _sessionLogPath = file.path;
      i('AppLogger', 'Session file logging enabled', error: file.path);
    } catch (e, st) {
      debugPrint('AppLogger file logging init failed: $e');
      debugPrint(st.toString());
    }
  }

  static Future<void> disposeSessionFileLogging() async {
    final sink = _sessionSink;
    _sessionSink = null;
    if (sink == null) return;
    try {
      await _fileQueue;
      await sink.flush();
      await sink.close();
    } catch (_) {}
  }

  /// Hook global handlers early in app startup.
  static void installGlobalHandlers() {
    FlutterError.onError = (FlutterErrorDetails details) {
      e(
        'FlutterError',
        details.exceptionAsString(),
        error: details.exception,
        stackTrace: details.stack,
      );
    };

    PlatformDispatcher.instance.onError = (error, stackTrace) {
      e('PlatformError', 'Unhandled platform error',
          error: error, stackTrace: stackTrace);
      return true;
    };
  }
}
