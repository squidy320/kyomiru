import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../core/app_logger.dart';
import '../core/image_cache.dart';
import 'anilist_client.dart';
import 'sora_runtime.dart';

final cacheServiceProvider = Provider<CacheService>((ref) => CacheService());

final cacheStatsProvider = FutureProvider<CacheStats>((ref) {
  return ref.watch(cacheServiceProvider).stats();
});

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  final gb = mb / 1024;
  return '${gb.toStringAsFixed(2)} GB';
}

class CacheService {
  static const List<String> _hiveCacheBoxes = <String>[
    'anilist_media_cache',
    'anilist_query_cache',
    'anilist_tracking_id_map',
    'manual_matches',
  ];

  Future<void> clearAll({
    AniListClient? anilistClient,
    SoraRuntime? soraRuntime,
  }) async {
    anilistClient?.clearRuntimeCaches();
    soraRuntime?.reset();

    // Clear Hive cache boxes
    for (final name in _hiveCacheBoxes) {
      try {
        await _clearHiveBoxSafe(name);
      } catch (e, st) {
        AppLogger.w('Cache', 'Failed to clear box $name', error: e, stackTrace: st);
      }
    }

    // Clear network image cache
    try {
      await KyomiruImageCache.manager.emptyCache();
    } catch (e, st) {
      AppLogger.w('Cache', 'Failed to clear network image cache', error: e, stackTrace: st);
    }

    // Clear temporary HLS and other streaming files
    try {
      final temp = await getTemporaryDirectory();
      if (await temp.exists()) {
        await for (final entity in temp.list(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          final path = entity.path.toLowerCase();
          if (path.endsWith('.m3u8') || path.endsWith('.ts') || path.contains('hls') || path.contains('.mp4')) { // Added .mp4 to clear temporary video files
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
    } catch (e, st) {
      AppLogger.w('Cache', 'Failed to clear temporary streaming cache', error: e, stackTrace: st);
    }
  }

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

  Future<void> _clearHiveBoxSafe(String name) async {
    bool isUnknownTypeIdError(Object error) {
      final text = error.toString().toLowerCase();
      return text.contains('unknown typeid');
    }

    Future<void> closeIfOpen() async {
      if (Hive.isBoxOpen(name)) {
        await Hive.box(name).close();
      }
    }

    try {
      if (Hive.isBoxOpen(name)) {
        await Hive.box(name).clear();
        return;
      }
      final box = await Hive.openBox(name);
      await box.clear();
      await box.close();
      return;
    } catch (e, st) {
      AppLogger.w(
        'Cache',
        'Primary clear failed for $name, attempting delete-and-recreate',
        error: e,
        stackTrace: st,
      );
      if (!isUnknownTypeIdError(e)) rethrow;
    }

    await closeIfOpen();
    await Hive.deleteBoxFromDisk(name);
    final box = await Hive.openBox(name);
    await box.clear();
    await box.close();
    AppLogger.i('Cache', 'Recovered Hive box $name via delete-and-recreate');
  }

  Future<int> _hiveBoxBytes(String name) async {
    try {
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

class CacheStats {
  final int totalBytes;

  final Map<String, int> breakdown;
  const CacheStats({
    required this.totalBytes,
    required this.breakdown,
  });
}
