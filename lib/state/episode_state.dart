import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/sora_models.dart';
import '../services/sora_runtime.dart';

class EpisodeQuery {
  const EpisodeQuery({
    required this.mediaId,
    required this.title,
    this.manualMatch,
  });

  final int mediaId;
  final String title;
  final SoraAnimeMatch? manualMatch;

  @override
  bool operator ==(Object other) {
    return other is EpisodeQuery &&
        other.mediaId == mediaId &&
        other.title == title &&
        other.manualMatch?.session == manualMatch?.session;
  }

  @override
  int get hashCode => Object.hash(mediaId, title, manualMatch?.session);
}

class EpisodeLoadResult {
  const EpisodeLoadResult({
    required this.match,
    required this.episodes,
  });

  final SoraAnimeMatch? match;
  final List<SoraEpisode> episodes;
}

class EpisodeSourceQuery {
  const EpisodeSourceQuery({
    required this.playUrl,
    required this.anilistId,
    required this.episodeNumber,
  });

  final String playUrl;
  final int anilistId;
  final int episodeNumber;

  @override
  bool operator ==(Object other) {
    return other is EpisodeSourceQuery &&
        other.playUrl == playUrl &&
        other.anilistId == anilistId &&
        other.episodeNumber == episodeNumber;
  }

  @override
  int get hashCode => Object.hash(playUrl, anilistId, episodeNumber);
}

final soraRuntimeProvider = Provider<SoraRuntime>((ref) {
  final runtime = SoraRuntime();
  ref.onDispose(runtime.dispose);
  return runtime;
});

final episodeProvider =
    FutureProvider.autoDispose.family<EpisodeLoadResult, EpisodeQuery>(
        (ref, query) async {
  final runtime = ref.watch(soraRuntimeProvider);

  await runtime.initialize();
  final match = query.manualMatch ?? await runtime.autoMatchTitle(query.title);
  if (match == null) {
    return const EpisodeLoadResult(match: null, episodes: []);
  }

  final backoffs = <Duration>[
    const Duration(milliseconds: 500),
    const Duration(seconds: 1),
    const Duration(seconds: 2),
  ];

  Object? lastError;
  for (var i = 0; i <= backoffs.length; i++) {
    try {
      final episodes = await runtime.getEpisodes(match);
      return EpisodeLoadResult(match: match, episodes: episodes);
    } catch (e) {
      lastError = e;
      if (i < backoffs.length) {
        await Future<void>.delayed(backoffs[i]);
        continue;
      }
    }
  }

  throw lastError ?? Exception('Failed to load episodes');
});

final episodeSourcesProvider =
    FutureProvider.autoDispose.family<List<SoraSource>, EpisodeSourceQuery>(
        (ref, query) async {
  final runtime = ref.watch(soraRuntimeProvider);
  await runtime.initialize();
  return runtime.getSourcesForEpisode(
    query.playUrl,
    anilistId: query.anilistId,
    episodeNumber: query.episodeNumber,
  );
});
