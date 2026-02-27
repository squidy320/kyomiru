import 'dart:async';

import 'package:dio/dio.dart';

import '../core/app_logger.dart';

class AniSkipRange {
  const AniSkipRange({required this.start, required this.end});

  final double start;
  final double end;
}

class _AniSkipCacheEntry {
  const _AniSkipCacheEntry({required this.value, required this.expiresAt});

  final AniSkipRange? value;
  final DateTime expiresAt;

  bool get isFresh => DateTime.now().isBefore(expiresAt);
}

class AniSkipService {
  AniSkipService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;
  static const Duration _ttl = Duration(minutes: 30);
  final Map<String, _AniSkipCacheEntry> _cache = {};
  final Set<String> _refreshing = <String>{};

  String _key(int malId, int episode) => '$malId:$episode';

  Future<AniSkipRange?> getOpeningRange({
    required int mediaId,
    required int episode,
    required int? malId,
  }) async {
    if (malId == null || malId <= 0) {
      AppLogger.w(
        'AniSkip',
        'Skipping fetch: missing MAL id for media=$mediaId ep=$episode',
      );
      return null;
    }

    final key = _key(malId, episode);
    final cached = _cache[key];
    if (cached != null) {
      if (cached.isFresh) return cached.value;
      _refreshInBackground(key, () async {
        final fresh = await _fetch(malId, mediaId, episode);
        _cache[key] = _AniSkipCacheEntry(
          value: fresh,
          expiresAt: DateTime.now().add(_ttl),
        );
      });
      return cached.value;
    }

    final fresh = await _fetch(malId, mediaId, episode);
    _cache[key] = _AniSkipCacheEntry(
      value: fresh,
      expiresAt: DateTime.now().add(_ttl),
    );
    return fresh;
  }

  Future<void> prefetchOpeningRange({
    required int mediaId,
    required int episode,
    required int? malId,
  }) async {
    unawaited(getOpeningRange(mediaId: mediaId, episode: episode, malId: malId));
  }

  void _refreshInBackground(String key, Future<void> Function() refresh) {
    if (_refreshing.contains(key)) return;
    _refreshing.add(key);
    unawaited(() async {
      try {
        await refresh();
      } catch (_) {
      } finally {
        _refreshing.remove(key);
      }
    }());
  }

  Future<AniSkipRange?> _fetch(int malId, int mediaId, int episode) async {
    final url =
        'https://api.aniskip.com/v1/skip-times/$malId/$episode?types[]=op';
    try {
      AppLogger.i('AniSkip', 'Fetching OP timestamps url=$url');
      final res = await _dio.get(
        url,
        options: Options(validateStatus: (_) => true),
      );
      AppLogger.i('AniSkip', 'Response status=${res.statusCode}');
      if ((res.statusCode ?? 0) >= 400) return null;

      final data = res.data;
      if (data is! Map<String, dynamic>) return null;
      final results = (data['results'] as List?) ?? const [];

      for (final item in results) {
        if (item is! Map<String, dynamic>) continue;
        if ((item['skip_type'] ?? '').toString().toLowerCase() != 'op') {
          continue;
        }
        final interval = item['interval'];
        if (interval is! Map<String, dynamic>) continue;

        final start = (interval['start_time'] as num?)?.toDouble();
        final end = (interval['end_time'] as num?)?.toDouble();
        if (start == null || end == null || end <= start) continue;

        AppLogger.i(
          'AniSkip',
          'Loaded OP timestamps media=$mediaId ep=$episode start=$start end=$end',
        );
        return AniSkipRange(start: start, end: end);
      }

      AppLogger.w(
        'AniSkip',
        'No OP range found in AniSkip results for media=$mediaId ep=$episode',
      );
      return null;
    } catch (e, st) {
      AppLogger.w('AniSkip', 'Failed to fetch skip-times', error: e, stackTrace: st);
      rethrow;
    }
  }
}
