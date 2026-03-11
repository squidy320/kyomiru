import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_logger.dart';
import '../models/anilist_models.dart';
import '../models/sora_models.dart';
import '../services/sora_runtime.dart';
import 'app_settings_state.dart';
import 'auth_state.dart';

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

final episodeProvider = FutureProvider.autoDispose
    .family<EpisodeLoadResult, EpisodeQuery>((ref, query) async {
  final runtime = ref.watch(soraRuntimeProvider);
  AniListMedia? media;
  if (query.mediaId > 0) {
    try {
      media = await ref.read(anilistClientProvider).mediaDetails(query.mediaId);
    } catch (_) {}
  }

  await runtime.initialize();
  final match = query.manualMatch ??
      await runtime.autoMatchTitle(query.title, media: media);
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
      final adjusted = _applySeasonOffsetIfNeeded(
        episodes,
        media,
        query.title,
        allow: query.manualMatch == null,
      );
      return EpisodeLoadResult(match: match, episodes: adjusted);
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

String _romanToArabic(String input) {
  var out = input;
  const map = {
    'x': '10',
    'ix': '9',
    'viii': '8',
    'vii': '7',
    'vi': '6',
    'v': '5',
    'iv': '4',
    'iii': '3',
    'ii': '2',
    'i': '1',
  };
  for (final entry in map.entries) {
    out = out.replaceAllMapped(
      RegExp('\\b${entry.key}\\b', caseSensitive: false),
      (_) => entry.value,
    );
  }
  return out;
}

int? _extractSeasonNumberFromTitle(String input) {
  final normalized = _romanToArabic(input);
  final seasonMatch =
      RegExp(r'\\bseason\\s*(\\d+)\\b', caseSensitive: false)
          .firstMatch(normalized);
  if (seasonMatch != null) {
    return int.tryParse(seasonMatch.group(1)!);
  }
  final shortMatch =
      RegExp(r'\\bs\\s*(\\d+)\\b', caseSensitive: false)
          .firstMatch(normalized);
  if (shortMatch != null) {
    return int.tryParse(shortMatch.group(1)!);
  }
  final ordinalMatch =
      RegExp(r'\\b(\\d+)(st|nd|rd|th)\\s*season\\b', caseSensitive: false)
          .firstMatch(normalized);
  if (ordinalMatch != null) {
    return int.tryParse(ordinalMatch.group(1)!);
  }
  final partMatch =
      RegExp(r'\\bpart\\s*(\\d+)\\b', caseSensitive: false)
          .firstMatch(normalized);
  if (partMatch != null) {
    return int.tryParse(partMatch.group(1)!);
  }
  final courMatch =
      RegExp(r'\\bcour\\s*(\\d+)\\b', caseSensitive: false)
          .firstMatch(normalized);
  if (courMatch != null) {
    return int.tryParse(courMatch.group(1)!);
  }
  return null;
}

List<SoraEpisode> _applySeasonOffsetIfNeeded(
  List<SoraEpisode> episodes,
  AniListMedia? media,
  String fallbackTitle, {
  required bool allow,
}) {
  if (!allow || media == null || episodes.isEmpty) return episodes;
  final expected = media.episodes ?? 0;
  if (expected <= 0) return episodes;
  final title = media.title.best.isNotEmpty ? media.title.best : fallbackTitle;
  final wantedSeason = _extractSeasonNumberFromTitle(title);
  if (wantedSeason == null || wantedSeason <= 1) return episodes;

  final minTotal = expected * wantedSeason;
  if (episodes.length < minTotal) return episodes;
  final offset = expected * (wantedSeason - 1);
  if (offset >= episodes.length) return episodes;

  final slice = episodes.skip(offset).take(expected).toList();
  if (slice.isEmpty) return episodes;

  AppLogger.i(
    'EpisodeMatch',
    'Series entry offset applied title="$title" season=$wantedSeason '
    'expected=$expected total=${episodes.length} offset=$offset',
  );
  return [
    for (var i = 0; i < slice.length; i++)
      SoraEpisode(
        number: i + 1,
        session: slice[i].session,
        playUrl: slice[i].playUrl,
      ),
  ];
}

final episodeSourcesProvider = FutureProvider.autoDispose
    .family<List<SoraSource>, EpisodeSourceQuery>((ref, query) async {
  final settings = ref.watch(appSettingsProvider);
  final runtime = ref.watch(soraRuntimeProvider);
  await runtime.initialize();
  final sources = await runtime.getSourcesForEpisode(
    query.playUrl,
    anilistId: query.anilistId,
    episodeNumber: query.episodeNumber,
  );
  if (sources.isEmpty) return sources;

  final audio = settings.defaultAudio.toLowerCase();
  final quality = settings.defaultQuality.toLowerCase();
  final sorted = [...sources];
  String audioKey(String value) {
    final v = value.trim().toLowerCase();
    if (v == 'any') return 'any';
    if (v.contains('dub') || v.contains('eng')) return 'dub';
    return 'sub';
  }

  int qualityRank(String q) {
    final m = RegExp(r'(\d+)').firstMatch(q);
    return int.tryParse(m?.group(1) ?? '') ?? 0;
  }

  int scoreFor(SoraSource s) {
    var score = 0;
    final sourceAudio = audioKey(s.subOrDub);
    final wantedAudio = audioKey(audio);
    final sourceQuality = s.quality.toLowerCase();
    final sourceFormat = s.format.toLowerCase();
    if (sourceFormat == 'm3u8' && sourceQuality.contains('auto')) {
      score += 1000;
    }
    if (wantedAudio == 'any' || sourceAudio == wantedAudio) {
      score += 500;
    }
    if (quality == 'auto' || sourceQuality.contains(quality)) {
      score += 300;
    }
    score += qualityRank(s.quality);
    return score;
  }

  sorted.sort((a, b) {
    final scoreDiff = scoreFor(b).compareTo(scoreFor(a));
    if (scoreDiff != 0) return scoreDiff;
    return qualityRank(b.quality).compareTo(qualityRank(a.quality));
  });
  return sorted;
});
