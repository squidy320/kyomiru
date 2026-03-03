import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../models/anilist_models.dart';

class AnimeEntry {
  const AnimeEntry({
    required this.mediaId,
    required this.title,
    required this.coverImage,
    required this.episodesWatched,
    required this.totalEpisodes,
    required this.status,
    required this.userScore,
  });

  final int mediaId;
  final String title;
  final String? coverImage;
  final int episodesWatched;
  final int totalEpisodes;
  final String status;
  final double userScore;

  Map<String, dynamic> toJson() => {
        'mediaId': mediaId,
        'title': title,
        'coverImage': coverImage,
        'episodesWatched': episodesWatched,
        'totalEpisodes': totalEpisodes,
        'status': status,
        'userScore': userScore,
      };

  static AnimeEntry fromJson(Map<dynamic, dynamic> json) {
    return AnimeEntry(
      mediaId: (json['mediaId'] as num?)?.toInt() ?? 0,
      title: (json['title'] ?? '').toString(),
      coverImage: json['coverImage']?.toString(),
      episodesWatched: (json['episodesWatched'] as num?)?.toInt() ?? 0,
      totalEpisodes: (json['totalEpisodes'] as num?)?.toInt() ?? 0,
      status: (json['status'] ?? 'CURRENT').toString(),
      userScore: (json['userScore'] as num?)?.toDouble() ?? 0,
    );
  }

  AnimeEntry copyWith({
    int? episodesWatched,
    int? totalEpisodes,
    String? status,
    double? userScore,
    String? title,
    String? coverImage,
  }) {
    return AnimeEntry(
      mediaId: mediaId,
      title: title ?? this.title,
      coverImage: coverImage ?? this.coverImage,
      episodesWatched: episodesWatched ?? this.episodesWatched,
      totalEpisodes: totalEpisodes ?? this.totalEpisodes,
      status: status ?? this.status,
      userScore: userScore ?? this.userScore,
    );
  }

  AniListTrackingEntry toTrackingEntry() => AniListTrackingEntry(
        id: mediaId,
        status: status,
        progress: episodesWatched,
        score: userScore,
      );
}

class LocalLibraryStore {
  LocalLibraryStore({Box? box}) : _box = box ?? Hive.box('local_library');

  final Box _box;

  Future<List<AnimeEntry>> allEntries() async {
    final out = <AnimeEntry>[];
    for (final key in _box.keys) {
      final raw = _box.get(key);
      if (raw is Map) {
        out.add(AnimeEntry.fromJson(raw));
      }
    }
    out.sort((a, b) => a.title.compareTo(b.title));
    return out;
  }

  Future<AnimeEntry?> entryForMedia(int mediaId) async {
    final raw = _box.get(mediaId.toString());
    if (raw is! Map) return null;
    return AnimeEntry.fromJson(raw);
  }

  Future<void> upsertFromMedia(
    AniListMedia media, {
    required String status,
    required int progress,
    required double score,
  }) async {
    final current = await entryForMedia(media.id);
    final entry = (current ??
            AnimeEntry(
              mediaId: media.id,
              title: media.title.best,
              coverImage: media.cover.best,
              episodesWatched: 0,
              totalEpisodes: media.episodes ?? 0,
              status: status,
              userScore: score,
            ))
        .copyWith(
      title: media.title.best,
      coverImage: media.cover.best,
      totalEpisodes: media.episodes ?? current?.totalEpisodes ?? 0,
      status: status,
      episodesWatched: progress,
      userScore: score,
    );
    await _box.put(media.id.toString(), entry.toJson());
  }

  Future<void> upsertByMediaId(
    int mediaId, {
    String? title,
    String? coverImage,
    int? totalEpisodes,
    required String status,
    required int progress,
    required double score,
  }) async {
    final current = await entryForMedia(mediaId);
    final entry = (current ??
            AnimeEntry(
              mediaId: mediaId,
              title: title ?? 'Unknown',
              coverImage: coverImage,
              episodesWatched: 0,
              totalEpisodes: totalEpisodes ?? 0,
              status: status,
              userScore: score,
            ))
        .copyWith(
      title: title ?? current?.title ?? 'Unknown',
      coverImage: coverImage ?? current?.coverImage,
      totalEpisodes: totalEpisodes ?? current?.totalEpisodes ?? 0,
      status: status,
      episodesWatched: progress,
      userScore: score,
    );
    await _box.put(mediaId.toString(), entry.toJson());
  }

  Future<void> removeByMediaId(int mediaId) async {
    await _box.delete(mediaId.toString());
  }
}

final localLibraryStoreProvider = Provider<LocalLibraryStore>((ref) {
  return LocalLibraryStore();
});

final localLibraryEntriesProvider = FutureProvider<List<AnimeEntry>>((ref) {
  return ref.watch(localLibraryStoreProvider).allEntries();
});
