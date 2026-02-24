import 'package:flutter/foundation.dart';

/// Lightweight app logger with levels and tags.
class AppLogger {
  AppLogger._();

  static bool enabled = true;
  static const int _maxEntries = 1000;
  static final ValueNotifier<List<String>> entries =
      ValueNotifier<List<String>>(<String>[]);

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
