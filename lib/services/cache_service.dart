import 'dart:io';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../core/app_logger.dart';
import 'anilist_client.dart';

class CacheStats {
  const CacheStats({
    required this.totalBytes,
    required this.breakdown,
  });

  final int totalBytes;
  final Map<String, int> breakdown;
}

class CacheService {
  static const List<String> _hiveCacheBoxes = <String>[
    'anilist_media_cache',
    'anilist_query_cache',
  ];

  Future<CacheStats> stats() async {
    final breakdown = <String, int>{};
    var total = 0;

    for (final name in _hiveCacheBoxes) {
      final bytes = await _hiveBoxBytes(name);
      breakdown['Hive:$name'] = bytes;
      total += bytes;
    }

    final imageBytes = await _cachedImageBytes();
    breakdown['Images'] = imageBytes;
    total += imageBytes;

    final tempHlsBytes = await _tempHlsBytes();
    breakdown['Temp HLS'] = tempHlsBytes;
    total += tempHlsBytes;

    return CacheStats(totalBytes: total, breakdown: breakdown);
  }

  Future<void> clearAll({AniListClient? anilistClient}) async {
    anilistClient?.clearRuntimeCaches();

    for (final name in _hiveCacheBoxes) {
      try {
        if (Hive.isBoxOpen(name)) {
          await Hive.box(name).clear();
        } else {
          await Hive.openBox(name);
          await Hive.box(name).clear();
          await Hive.box(name).close();
        }
      } catch (e, st) {
        AppLogger.w('Cache', 'Failed to clear box $name', error: e, stackTrace: st);
      }
    }

    try {
      await DefaultCacheManager().emptyCache();
    } catch (e, st) {
      AppLogger.w('Cache', 'Failed to clear image cache', error: e, stackTrace: st);
    }

    try {
      final temp = await getTemporaryDirectory();
      if (await temp.exists()) {
        await for (final entity in temp.list(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          final path = entity.path.toLowerCase();
          if (path.endsWith('.m3u8') || path.endsWith('.ts') || path.contains('hls')) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
    } catch (e, st) {
      AppLogger.w('Cache', 'Failed to clear temp HLS cache', error: e, stackTrace: st);
    }
  }

  Future<int> _hiveBoxBytes(String name) async {
    try {
      if (!Hive.isBoxOpen(name)) {
        await Hive.openBox(name);
        await Hive.box(name).close();
      }
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(docs.path);
      if (!await dir.exists()) return 0;
      var total = 0;
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final base = entity.uri.pathSegments.isNotEmpty
            ? entity.uri.pathSegments.last
            : entity.path;
        if (!base.contains(name)) continue;
        try {
          total += await entity.length();
        } catch (_) {}
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  Future<int> _cachedImageBytes() async {
    try {
      final temp = await getTemporaryDirectory();
      if (!await temp.exists()) return 0;
      var total = 0;
      await for (final entity in temp.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final path = entity.path.toLowerCase();
        if (!(path.contains('libcachedimagedata') || path.contains('cache'))) {
          continue;
        }
        try {
          total += await entity.length();
        } catch (_) {}
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  Future<int> _tempHlsBytes() async {
    try {
      final temp = await getTemporaryDirectory();
      if (!await temp.exists()) return 0;
      var total = 0;
      await for (final entity in temp.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final path = entity.path.toLowerCase();
        if (!(path.endsWith('.m3u8') || path.endsWith('.ts') || path.contains('hls'))) {
          continue;
        }
        try {
          total += await entity.length();
        } catch (_) {}
      }
      return total;
    } catch (_) {
      return 0;
    }
  }
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  final gb = mb / 1024;
  return '${gb.toStringAsFixed(2)} GB';
}

final cacheServiceProvider = Provider<CacheService>((ref) => CacheService());

final cacheStatsProvider = FutureProvider<CacheStats>((ref) {
  return ref.watch(cacheServiceProvider).stats();
});
