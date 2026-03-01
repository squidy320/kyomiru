import 'package:hive/hive.dart';

class WatchHistoryEntry {
  const WatchHistoryEntry({
    required this.storageKey,
    required this.episodeId,
    required this.mediaId,
    required this.episodeNumber,
    required this.mediaTitle,
    required this.episodeTitle,
    required this.sourceUrl,
    required this.lastPositionMs,
    required this.totalDurationMs,
    required this.isDownloaded,
    required this.updatedAtMs,
    this.coverImageUrl,
    this.headers = const {},
  });

  final String storageKey;
  final String episodeId;
  final int mediaId;
  final int episodeNumber;
  final String mediaTitle;
  final String episodeTitle;
  final String sourceUrl;
  final int lastPositionMs;
  final int totalDurationMs;
  final bool isDownloaded;
  final int updatedAtMs;
  final String? coverImageUrl;
  final Map<String, String> headers;

  double get progress {
    if (totalDurationMs <= 0) return 0;
    return (lastPositionMs / totalDurationMs).clamp(0, 1);
  }

  Map<String, dynamic> toJson() => {
        'episodeId': episodeId,
        'mediaId': mediaId,
        'episodeNumber': episodeNumber,
        'mediaTitle': mediaTitle,
        'episodeTitle': episodeTitle,
        'sourceUrl': sourceUrl,
        'lastPositionMs': lastPositionMs,
        'totalDurationMs': totalDurationMs,
        'isDownloaded': isDownloaded,
        'updatedAtMs': updatedAtMs,
        'coverImageUrl': coverImageUrl,
        'headers': headers,
      };

  static WatchHistoryEntry? fromJson(
    String storageKey,
    Map<dynamic, dynamic> json,
  ) {
    final sourceUrl = (json['sourceUrl'] as String?)?.trim() ?? '';
    if (sourceUrl.isEmpty) return null;

    final rawHeaders = json['headers'];
    final parsedHeaders = <String, String>{};
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        final key = entry.key?.toString();
        final value = entry.value?.toString();
        if (key == null || value == null) continue;
        parsedHeaders[key] = value;
      }
    }

    return WatchHistoryEntry(
      storageKey: storageKey,
      episodeId: (json['episodeId'] as String?) ?? storageKey,
      mediaId: (json['mediaId'] as num?)?.toInt() ?? 0,
      episodeNumber: (json['episodeNumber'] as num?)?.toInt() ?? 0,
      mediaTitle: (json['mediaTitle'] as String?) ?? 'Unknown',
      episodeTitle: (json['episodeTitle'] as String?) ?? 'Episode',
      sourceUrl: sourceUrl,
      lastPositionMs: (json['lastPositionMs'] as num?)?.toInt() ?? 0,
      totalDurationMs: (json['totalDurationMs'] as num?)?.toInt() ?? 0,
      isDownloaded: (json['isDownloaded'] as bool?) ?? false,
      updatedAtMs:
          (json['updatedAtMs'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
      coverImageUrl: json['coverImageUrl'] as String?,
      headers: parsedHeaders,
    );
  }
}

class WatchHistoryStore {
  WatchHistoryStore({Box? box}) : _box = box ?? Hive.box('watch_history');

  final Box _box;

  String _key(int mediaId, int episodeNumber) => '$mediaId:$episodeNumber';

  Future<void> upsert({
    required int mediaId,
    required int episodeNumber,
    required String mediaTitle,
    required String episodeTitle,
    required String sourceUrl,
    required int lastPositionMs,
    required int totalDurationMs,
    required bool isDownloaded,
    String? coverImageUrl,
    Map<String, String> headers = const {},
  }) async {
    if (sourceUrl.trim().isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final key = _key(mediaId, episodeNumber);
    final entry = WatchHistoryEntry(
      storageKey: key,
      episodeId: key,
      mediaId: mediaId,
      episodeNumber: episodeNumber,
      mediaTitle: mediaTitle,
      episodeTitle: episodeTitle,
      sourceUrl: sourceUrl.trim(),
      lastPositionMs: lastPositionMs,
      totalDurationMs: totalDurationMs,
      isDownloaded: isDownloaded,
      updatedAtMs: now,
      coverImageUrl: coverImageUrl,
      headers: headers,
    );
    await _box.put(key, entry.toJson());
  }

  Future<void> remove({
    required int mediaId,
    required int episodeNumber,
  }) async {
    await _box.delete(_key(mediaId, episodeNumber));
  }

  Future<void> removeByStorageKey(String key) async {
    await _box.delete(key);
  }

  List<WatchHistoryEntry> allEntries() {
    final out = <WatchHistoryEntry>[];
    for (final key in _box.keys) {
      final keyString = key.toString();
      final raw = _box.get(key);
      if (raw is! Map) continue;
      final parsed = WatchHistoryEntry.fromJson(keyString, raw);
      if (parsed == null) continue;
      out.add(parsed);
    }
    out.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    return out;
  }
}
