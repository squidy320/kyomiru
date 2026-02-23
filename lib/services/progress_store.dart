import 'package:hive/hive.dart';

class EpisodeProgress {
  const EpisodeProgress({
    required this.positionMs,
    required this.durationMs,
    required this.updatedAtMs,
  });

  final int positionMs;
  final int durationMs;
  final int updatedAtMs;

  double get percent {
    if (durationMs <= 0) return 0;
    return (positionMs / durationMs).clamp(0, 1);
  }

  Map<String, dynamic> toJson() => {
        'positionMs': positionMs,
        'durationMs': durationMs,
        'updatedAtMs': updatedAtMs,
      };

  static EpisodeProgress fromJson(Map<dynamic, dynamic> json) {
    return EpisodeProgress(
      positionMs: (json['positionMs'] as num?)?.toInt() ?? 0,
      durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      updatedAtMs: (json['updatedAtMs'] as num?)?.toInt() ?? 0,
    );
  }
}

class ProgressStore {
  ProgressStore({Box? box}) : _box = box ?? Hive.box('episode_progress');

  final Box _box;

  String _key(int mediaId, int episode) => '$mediaId:$episode';

  EpisodeProgress? read(int mediaId, int episode) {
    final raw = _box.get(_key(mediaId, episode));
    if (raw is Map) return EpisodeProgress.fromJson(raw);
    return null;
  }

  Future<void> write({
    required int mediaId,
    required int episode,
    required int positionMs,
    required int durationMs,
  }) async {
    final clampedPosition =
        positionMs.clamp(0, durationMs > 0 ? durationMs : positionMs);
    await _box.put(
      _key(mediaId, episode),
      EpisodeProgress(
        positionMs: clampedPosition,
        durationMs: durationMs,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      ).toJson(),
    );
  }

  List<MapEntry<int, EpisodeProgress>> allForMedia(int mediaId) {
    final prefix = '$mediaId:';
    final out = <MapEntry<int, EpisodeProgress>>[];
    for (final key in _box.keys) {
      final s = key.toString();
      if (!s.startsWith(prefix)) continue;
      final episodeStr = s.substring(prefix.length);
      final episode = int.tryParse(episodeStr);
      final raw = _box.get(key);
      if (episode == null || raw is! Map) continue;
      out.add(MapEntry(episode, EpisodeProgress.fromJson(raw)));
    }
    out.sort((a, b) => a.key.compareTo(b.key));
    return out;
  }
}
