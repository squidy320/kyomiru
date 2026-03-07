import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import '../core/app_logger.dart';
import '../models/anilist_models.dart';
import '../services/local_library_store.dart';
import 'app_settings_state.dart';
import 'auth_state.dart';
import 'library_source_state.dart';

final mediaListProvider =
    FutureProvider.family<AniListTrackingEntry?, int>((ref, mediaId) async {
  final source = ref.watch(librarySourceProvider);
  if (source == LibrarySource.local) {
    final local = await ref.watch(localLibraryStoreProvider).entryForMedia(mediaId);
    return local?.toTrackingEntry();
  }
  final auth = ref.watch(authControllerProvider);
  final token = auth.token;
  if (token == null || token.isEmpty) return null;
  return ref.watch(anilistClientProvider).trackingEntry(token, mediaId);
});

final trackingScoreFormatProvider = FutureProvider<String>((ref) async {
  final source = ref.watch(librarySourceProvider);
  if (source == LibrarySource.local) return 'POINT_10_DECIMAL';
  final auth = ref.watch(authControllerProvider);
  final token = auth.token;
  if (token == null || token.isEmpty) return 'POINT_10_DECIMAL';
  final me = await ref.watch(anilistClientProvider).me(token);
  return me.scoreFormat;
});

@Deprecated('Use aniListTrackingProvider transaction sync engine instead.')
final mediaListEntryControllerProvider = StateNotifierProvider.family<
    MediaListEntryController, AniListTrackingEntry?, int>((ref, mediaId) {
  return MediaListEntryController(ref, mediaId);
});

final librarySyncBumpProvider = StateProvider<int>((ref) => 0);

class AniListTrackingTarget {
  const AniListTrackingTarget({
    required this.sourceMediaId,
    required this.title,
    required this.episodes,
    this.englishTitle,
    this.romajiTitle,
  });

  final int sourceMediaId;
  final String title;
  final String? englishTitle;
  final String? romajiTitle;
  final int? episodes;

  @override
  bool operator ==(Object other) {
    return other is AniListTrackingTarget &&
        other.sourceMediaId == sourceMediaId &&
        other.title == title &&
        other.englishTitle == englishTitle &&
        other.romajiTitle == romajiTitle &&
        other.episodes == episodes;
  }

  @override
  int get hashCode =>
      Object.hash(sourceMediaId, title, englishTitle, romajiTitle, episodes);
}

extension AniListTrackingTargetX on AniListMedia {
  AniListTrackingTarget toTrackingTarget() => AniListTrackingTarget(
        sourceMediaId: id,
        title: title.best,
        englishTitle: title.english,
        romajiTitle: title.romaji,
        episodes: episodes,
      );
}

class TrackingDraft {
  const TrackingDraft({
    required this.status,
    required this.progress,
    required this.score,
  });

  final String status;
  final int progress;
  final double score;
}

class AniListTrackingSyncState {
  const AniListTrackingSyncState({
    this.resolvedMediaId,
    this.entry,
    this.maxEpisodes = 9999,
    this.statusDraft = 'CURRENT',
    this.progressDraft = 0,
    this.scoreDraft = 0,
    this.lastSyncedAt,
    this.errorMessage,
    this.isFetching = false,
    this.isResolvingId = false,
    this.isSaving = false,
    this.isRemoving = false,
  });

  final int? resolvedMediaId;
  final AniListTrackingEntry? entry;
  final int maxEpisodes;
  final String statusDraft;
  final int progressDraft;
  final double scoreDraft;
  final DateTime? lastSyncedAt;
  final String? errorMessage;
  final bool isFetching;
  final bool isResolvingId;
  final bool isSaving;
  final bool isRemoving;

  bool get isBusy => isFetching || isResolvingId || isSaving || isRemoving;

  AniListTrackingSyncState copyWith({
    int? resolvedMediaId,
    bool clearResolvedMediaId = false,
    AniListTrackingEntry? entry,
    bool clearEntry = false,
    int? maxEpisodes,
    String? statusDraft,
    int? progressDraft,
    double? scoreDraft,
    DateTime? lastSyncedAt,
    bool clearLastSyncedAt = false,
    String? errorMessage,
    bool clearErrorMessage = false,
    bool? isFetching,
    bool? isResolvingId,
    bool? isSaving,
    bool? isRemoving,
  }) {
    return AniListTrackingSyncState(
      resolvedMediaId:
          clearResolvedMediaId ? null : (resolvedMediaId ?? this.resolvedMediaId),
      entry: clearEntry ? null : (entry ?? this.entry),
      maxEpisodes: maxEpisodes ?? this.maxEpisodes,
      statusDraft: statusDraft ?? this.statusDraft,
      progressDraft: progressDraft ?? this.progressDraft,
      scoreDraft: scoreDraft ?? this.scoreDraft,
      lastSyncedAt: clearLastSyncedAt ? null : (lastSyncedAt ?? this.lastSyncedAt),
      errorMessage:
          clearErrorMessage ? null : (errorMessage ?? this.errorMessage),
      isFetching: isFetching ?? this.isFetching,
      isResolvingId: isResolvingId ?? this.isResolvingId,
      isSaving: isSaving ?? this.isSaving,
      isRemoving: isRemoving ?? this.isRemoving,
    );
  }
}

final aniListTrackingProvider = StateNotifierProvider.autoDispose
    .family<AniListTrackingController, AniListTrackingSyncState,
        AniListTrackingTarget>(
  (ref, target) => AniListTrackingController(ref, target),
);

class AniListTrackingController extends StateNotifier<AniListTrackingSyncState> {
  AniListTrackingController(this._ref, this._target)
      : super(AniListTrackingSyncState(
          maxEpisodes: (_target.episodes ?? 0) > 0 ? _target.episodes! : 9999,
        ));

  final Ref _ref;
  final AniListTrackingTarget _target;

  TrackingDraft? _committed;
  bool _bootstrapped = false;
  static const _idMapBoxName = 'anilist_tracking_id_map';

  Future<void> prepare({String? tokenOverride, bool forceRefresh = false}) async {
    AppLogger.i(
      'AniListSync',
      'prepare sourceMediaId=${_target.sourceMediaId} title="${_target.title}" forceRefresh=$forceRefresh',
    );
    if (_bootstrapped && !forceRefresh) return;
    _bootstrapped = true;
    await refresh(tokenOverride: tokenOverride, force: forceRefresh);
  }

  Future<void> refresh({String? tokenOverride, bool force = true}) async {
    final source = _ref.read(librarySourceProvider);
    AppLogger.i(
      'AniListSync',
      'refresh start source=$source sourceMediaId=${_target.sourceMediaId} force=$force',
    );
    state = state.copyWith(
      isFetching: true,
      clearErrorMessage: true,
    );
    try {
      if (source == LibrarySource.local) {
        final local = await _ref.read(localLibraryStoreProvider).entryForMedia(
              _target.sourceMediaId,
            );
        final maxEp =
            (_target.episodes ?? local?.totalEpisodes ?? 0) > 0 ? (_target.episodes ?? local!.totalEpisodes) : 9999;
        final draft = TrackingDraft(
          status: local?.status ?? 'CURRENT',
          progress: local?.episodesWatched ?? 0,
          score: local?.userScore ?? 0,
        );
        _committed = draft;
        state = state.copyWith(
          entry: local?.toTrackingEntry(),
          maxEpisodes: maxEp,
          statusDraft: draft.status,
          progressDraft: draft.progress.clamp(0, maxEp),
          scoreDraft: draft.score,
          lastSyncedAt: DateTime.now(),
          isFetching: false,
        );
        return;
      }

      final token = _resolveToken(tokenOverride);
      if (token == null) {
        state = state.copyWith(
          isFetching: false,
          errorMessage: 'AniList token missing.',
        );
        return;
      }

      final mediaId = await _resolveAniListMediaId();
      if (mediaId <= 0) {
        state = state.copyWith(
          isFetching: false,
          errorMessage: 'Could not resolve AniList media ID.',
        );
        return;
      }

      final client = _ref.read(anilistClientProvider);
      final futures = await Future.wait<dynamic>([
        client.trackingEntry(token, mediaId, force: force),
        client.episodeAvailability(token, mediaId),
      ]);
      final entry = futures[0] as AniListTrackingEntry?;
      final availability = futures[1] as AniListEpisodeAvailability?;
      AppLogger.i(
        'AniListSync',
        'tracking fetched sourceMediaId=${_target.sourceMediaId} resolvedMediaId=$mediaId '
            'entryStatus=${entry?.status ?? 'null'} entryProgress=${entry?.progress ?? -1} '
            'entryScore=${entry?.score ?? -1}',
      );
      final maxEpCandidate =
          availability?.episodes ?? _target.episodes ?? 0;
      final maxEp = maxEpCandidate > 0 ? maxEpCandidate : 9999;
      final draft = TrackingDraft(
        status: entry?.status ?? 'CURRENT',
        progress: (entry?.progress ?? 0).clamp(0, maxEp),
        score: entry?.score ?? 0,
      );
      _committed = draft;
      state = state.copyWith(
        resolvedMediaId: mediaId,
        entry: entry,
        maxEpisodes: maxEp,
        statusDraft: draft.status,
        progressDraft: draft.progress,
        scoreDraft: draft.score,
        lastSyncedAt: DateTime.now(),
        isFetching: false,
      );
    } catch (e, st) {
      AppLogger.e(
        'AniListSync',
        'Tracking refresh failed',
        error: e,
        stackTrace: st,
      );
      state = state.copyWith(
        isFetching: false,
        errorMessage: 'Failed to fetch tracking.',
      );
    }
  }

  Future<bool> requestStatus(String status) async {
    if (state.isBusy) return false;
    AppLogger.d(
      'AniListSync',
      'requestStatus sourceMediaId=${_target.sourceMediaId} status=$status',
    );
    state = state.copyWith(statusDraft: status, clearErrorMessage: true);
    return true;
  }

  Future<bool> requestProgress(int progress) async {
    if (state.isBusy) return false;
    final maxEp = state.maxEpisodes <= 0 ? 9999 : state.maxEpisodes;
    final clamped = progress.clamp(0, maxEp).toInt();
    AppLogger.d(
      'AniListSync',
      'requestProgress sourceMediaId=${_target.sourceMediaId} requested=$progress clamped=$clamped max=$maxEp',
    );
    state = state.copyWith(progressDraft: clamped, clearErrorMessage: true);
    return true;
  }

  Future<bool> requestScore(double score) async {
    if (state.isBusy) return false;
    final clamped = score < 0 ? 0.0 : score;
    AppLogger.d(
      'AniListSync',
      'requestScore sourceMediaId=${_target.sourceMediaId} requested=$score clamped=$clamped',
    );
    state = state.copyWith(scoreDraft: clamped, clearErrorMessage: true);
    return true;
  }

  Future<bool> commit({String? tokenOverride}) async {
    if (state.isBusy) return false;
    final source = _ref.read(librarySourceProvider);
    final previous = _committed ??
        TrackingDraft(
          status: state.statusDraft,
          progress: state.progressDraft,
          score: state.scoreDraft,
        );
    final maxEp = state.maxEpisodes <= 0 ? 9999 : state.maxEpisodes;
    var progress = state.progressDraft.clamp(0, maxEp);
    var statusToSave = state.statusDraft;
    if (statusToSave == 'CURRENT' && progress <= 0) {
      // AniList often normalizes CURRENT@0 back to PLANNING on readback.
      // Keep CURRENT stable by saving minimum progress 1.
      progress = 1;
      AppLogger.i(
        'AniListSync',
        'commit adjusted CURRENT progress from 0 to 1 sourceMediaId=${_target.sourceMediaId}',
      );
    }
    AppLogger.i(
      'AniListSync',
      'commit start sourceMediaId=${_target.sourceMediaId} resolvedMediaId=${state.resolvedMediaId ?? -1} '
          'status=${state.statusDraft} statusToSave=$statusToSave progress=$progress score=${state.scoreDraft}',
    );
    final optimistic = AniListTrackingEntry(
      id: state.entry?.id ?? 0,
      status: statusToSave,
      progress: progress,
      score: state.scoreDraft,
    );
    state = state.copyWith(
      isSaving: true,
      entry: optimistic,
      progressDraft: progress,
      clearErrorMessage: true,
    );
    try {
      if (source == LibrarySource.local) {
        if (_target.sourceMediaId > 0) {
          await _ref.read(localLibraryStoreProvider).upsertByMediaId(
                _target.sourceMediaId,
                title: _target.title,
                totalEpisodes: _target.episodes ?? maxEp,
                status: statusToSave,
                progress: progress,
                score: state.scoreDraft,
              );
        }
        _ref.invalidate(localLibraryEntriesProvider);
        _ref.invalidate(mediaListProvider(_target.sourceMediaId));
        _ref.read(librarySyncBumpProvider.notifier).state++;
        _committed = TrackingDraft(
          status: statusToSave,
          progress: progress,
          score: state.scoreDraft,
        );
        state = state.copyWith(
          statusDraft: statusToSave,
          isSaving: false,
          lastSyncedAt: DateTime.now(),
        );
        AppLogger.i(
          'AniListSync',
          'commit success local sourceMediaId=${_target.sourceMediaId} status=${state.statusDraft} progress=$progress',
        );
        return true;
      }

      final token = _resolveToken(tokenOverride);
      final mediaId = state.resolvedMediaId ?? await _resolveAniListMediaId();
      if (token == null || mediaId <= 0) {
        throw Exception('Missing AniList token or mediaId');
      }
      final saved = await _ref.read(anilistClientProvider).saveTrackingEntry(
            token: token,
            mediaId: mediaId,
            status: statusToSave,
            progress: progress,
            score: state.scoreDraft,
          );
      final verified = await _ref
          .read(anilistClientProvider)
          .trackingEntry(token, mediaId, force: true);
      final effective = verified ?? saved;
      if (verified != null &&
          (verified.status != saved.status ||
              verified.progress != saved.progress ||
              (verified.score - saved.score).abs() > 0.001)) {
        AppLogger.w(
          'AniListSync',
          'commit verification mismatch sourceMediaId=${_target.sourceMediaId} resolvedMediaId=$mediaId '
              'saved=(${saved.status},${saved.progress},${saved.score}) '
              'verified=(${verified.status},${verified.progress},${verified.score})',
        );
      }
      _committed = TrackingDraft(
        status: effective.status,
        progress: effective.progress,
        score: effective.score,
      );
      _ref.invalidate(mediaListProvider(mediaId));
      _ref.read(librarySyncBumpProvider.notifier).state++;
      state = state.copyWith(
        entry: effective,
        statusDraft: effective.status,
        progressDraft: effective.progress.clamp(0, state.maxEpisodes),
        scoreDraft: effective.score,
        isSaving: false,
        lastSyncedAt: DateTime.now(),
      );
      AppLogger.i(
        'AniListSync',
        'commit success anilist sourceMediaId=${_target.sourceMediaId} resolvedMediaId=$mediaId '
            'status=${effective.status} progress=${effective.progress} score=${effective.score}',
      );
      return true;
    } catch (e, st) {
      AppLogger.w(
        'AniListSync',
        'Tracking commit failed; rolling back',
        error: e,
        stackTrace: st,
      );
      state = state.copyWith(
        isSaving: false,
        statusDraft: previous.status,
        progressDraft: previous.progress.clamp(0, state.maxEpisodes),
        scoreDraft: previous.score,
        entry: AniListTrackingEntry(
          id: state.entry?.id ?? 0,
          status: previous.status,
          progress: previous.progress.clamp(0, state.maxEpisodes),
          score: previous.score,
        ),
        errorMessage: 'Sync Failed',
      );
      return false;
    }
  }

  Future<bool> remove({String? tokenOverride}) async {
    if (state.isBusy) return false;
    final source = _ref.read(librarySourceProvider);
    state = state.copyWith(isRemoving: true, clearErrorMessage: true);
    AppLogger.i(
      'AniListSync',
      'remove start sourceMediaId=${_target.sourceMediaId} resolvedMediaId=${state.resolvedMediaId ?? -1}',
    );
    try {
      if (source == LibrarySource.local) {
        await _ref
            .read(localLibraryStoreProvider)
            .removeByMediaId(_target.sourceMediaId);
        _ref.invalidate(localLibraryEntriesProvider);
        _ref.invalidate(mediaListProvider(_target.sourceMediaId));
        _ref.read(librarySyncBumpProvider.notifier).state++;
      } else {
        final token = _resolveToken(tokenOverride);
        final mediaId = state.resolvedMediaId ?? await _resolveAniListMediaId();
        if (token == null || mediaId <= 0) {
          throw Exception('Missing AniList token or mediaId');
        }
        final ok = await _ref.read(anilistClientProvider).deleteTrackingEntry(
              token: token,
              mediaId: mediaId,
            );
        if (!ok) throw Exception('Delete failed');
        _ref.invalidate(mediaListProvider(mediaId));
        _ref.read(librarySyncBumpProvider.notifier).state++;
      }

      _committed = const TrackingDraft(status: 'CURRENT', progress: 0, score: 0);
      state = state.copyWith(
        isRemoving: false,
        clearEntry: true,
        statusDraft: 'CURRENT',
        progressDraft: 0,
        scoreDraft: 0,
        lastSyncedAt: DateTime.now(),
      );
      AppLogger.i(
        'AniListSync',
        'remove success sourceMediaId=${_target.sourceMediaId}',
      );
      return true;
    } catch (e, st) {
      AppLogger.w('AniListSync', 'Remove failed', error: e, stackTrace: st);
      state = state.copyWith(
        isRemoving: false,
        errorMessage: 'Sync Failed',
      );
      return false;
    }
  }

  Future<bool> autoAdvanceToEpisode({
    required int episodeNumber,
    required String mediaTitle,
  }) async {
    AppLogger.i(
      'AniListSync',
      'autoAdvance trigger sourceMediaId=${_target.sourceMediaId} episode=$episodeNumber mediaTitle="$mediaTitle"',
    );
    final source = _ref.read(librarySourceProvider);
    if (source == LibrarySource.local) {
      try {
        final current = await _ref
            .read(localLibraryStoreProvider)
            .entryForMedia(_target.sourceMediaId);
        final maxEp = _target.episodes ?? current?.totalEpisodes ?? 0;
        final nextProgress = episodeNumber > (current?.episodesWatched ?? 0)
            ? episodeNumber
            : (current?.episodesWatched ?? 0);
        final clamped = maxEp > 0 ? nextProgress.clamp(0, maxEp) : nextProgress;
        await _ref.read(localLibraryStoreProvider).upsertByMediaId(
              _target.sourceMediaId,
              title: mediaTitle,
              totalEpisodes: maxEp,
              status: (maxEp > 0 && clamped >= maxEp) ? 'COMPLETED' : 'CURRENT',
              progress: clamped,
              score: current?.userScore ?? 0,
            );
        _ref.invalidate(localLibraryEntriesProvider);
        _ref.invalidate(mediaListProvider(_target.sourceMediaId));
        _ref.read(librarySyncBumpProvider.notifier).state++;
        AppLogger.i(
          'AniListSync',
          'autoAdvance success local sourceMediaId=${_target.sourceMediaId} progress=$clamped',
        );
        return true;
      } catch (_) {
        return false;
      }
    }

    final token = _resolveToken(null);
    if (token == null || token.isEmpty) return false;
    if (!_ref.read(appSettingsProvider).autoSyncProgressToAniList) return false;

    try {
      final mediaId = state.resolvedMediaId ?? await _resolveAniListMediaId();
      if (mediaId <= 0) return false;
      final client = _ref.read(anilistClientProvider);
      final current = await client.trackingEntry(token, mediaId);
      final availability = await client.episodeAvailability(token, mediaId);
      final maxEp = availability?.episodes ?? _target.episodes ?? 0;
      final nextProgress = episodeNumber > (current?.progress ?? 0)
          ? episodeNumber
          : (current?.progress ?? 0);
      final clamped = maxEp > 0 ? nextProgress.clamp(0, maxEp) : nextProgress;
      final isReleasing =
          (availability?.status.toUpperCase() ?? '') == 'RELEASING';
      final isFinalEpisode = !isReleasing && maxEp > 0 && clamped >= maxEp;
      await client.saveTrackingEntry(
        token: token,
        mediaId: mediaId,
        status: isFinalEpisode ? 'COMPLETED' : 'CURRENT',
        progress: clamped,
        score: current?.score ?? 0,
      );
      _ref.invalidate(mediaListProvider(mediaId));
      _ref.read(librarySyncBumpProvider.notifier).state++;
      AppLogger.i(
        'AniListSync',
        'autoAdvance success anilist sourceMediaId=${_target.sourceMediaId} resolvedMediaId=$mediaId progress=$clamped',
      );
      return true;
    } catch (e, st) {
      AppLogger.w(
        'AniListSync',
        'Auto-advance transaction failed',
        error: e,
        stackTrace: st,
      );
      return false;
    }
  }

  String? _resolveToken(String? tokenOverride) {
    if (tokenOverride != null && tokenOverride.isNotEmpty) return tokenOverride;
    final auth = _ref.read(authControllerProvider);
    final token = auth.token;
    if (token == null || token.isEmpty) return null;
    return token;
  }

  Future<int> _resolveAniListMediaId() async {
    final current = state.resolvedMediaId;
    if (current != null && current > 0) return current;
    state = state.copyWith(isResolvingId: true, clearErrorMessage: true);
    try {
      if (_target.sourceMediaId > 0) {
        await _persistResolvedMediaId(
          _target.sourceMediaId,
          includeTitleKeys: false,
        );
        AppLogger.i(
          'AniListSync',
          'using source media id directly: ${_target.sourceMediaId}',
        );
        state = state.copyWith(
          resolvedMediaId: _target.sourceMediaId,
          isResolvingId: false,
        );
        return _target.sourceMediaId;
      }

      final mapped = await _mappedMediaIdFromCache();
      if (mapped > 0) {
        state = state.copyWith(resolvedMediaId: mapped, isResolvingId: false);
        return mapped;
      }

      final query = _target.englishTitle?.trim().isNotEmpty == true
          ? _target.englishTitle!.trim()
          : (_target.romajiTitle?.trim().isNotEmpty == true
              ? _target.romajiTitle!.trim()
              : _target.title.trim());
      if (query.isEmpty) {
        state = state.copyWith(isResolvingId: false);
        return 0;
      }
      final results = await _ref.read(anilistClientProvider).searchAnime(query);
      final chosen = _pickBestMatch(results);
      final resolved = chosen?.id ?? 0;
      if (resolved > 0) {
        await _persistResolvedMediaId(
          resolved,
          includeTitleKeys: true,
        );
      }
      AppLogger.i(
        'AniListSync',
        'resolved media id by title: sourceMediaId=${_target.sourceMediaId} '
            'query="$query" resolved=$resolved',
      );
      state = state.copyWith(resolvedMediaId: resolved, isResolvingId: false);
      return resolved;
    } catch (e, st) {
      AppLogger.w(
        'AniListSync',
        'Media ID resolution failed',
        error: e,
        stackTrace: st,
      );
      state = state.copyWith(
        isResolvingId: false,
        errorMessage: 'Could not resolve AniList ID.',
      );
      return 0;
    }
  }

  AniListMedia? _pickBestMatch(List<AniListMedia> candidates) {
    if (candidates.isEmpty) return null;
    final needle = _norm(_target.title);
    final en = _norm(_target.englishTitle ?? '');
    final ro = _norm(_target.romajiTitle ?? '');
    for (final item in candidates) {
      final c1 = _norm(item.title.english ?? '');
      final c2 = _norm(item.title.romaji ?? '');
      final c3 = _norm(item.title.native ?? '');
      if (needle.isNotEmpty && (c1 == needle || c2 == needle || c3 == needle)) {
        return item;
      }
      if (en.isNotEmpty && (c1 == en || c2 == en || c3 == en)) return item;
      if (ro.isNotEmpty && (c1 == ro || c2 == ro || c3 == ro)) return item;
    }
    return candidates.first;
  }

  String _norm(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '')
        .trim();
  }

  Future<Box<dynamic>> _idMapBox() async {
    if (Hive.isBoxOpen(_idMapBoxName)) return Hive.box<dynamic>(_idMapBoxName);
    return Hive.openBox<dynamic>(_idMapBoxName);
  }

  List<String> _cacheKeys({bool includeTitleKeys = true}) {
    final out = <String>[];
    if (_target.sourceMediaId > 0) {
      out.add('source:${_target.sourceMediaId}');
    }
    if (!includeTitleKeys) {
      return out.toSet().toList(growable: false);
    }
    final titles = <String>[
      _target.title,
      _target.englishTitle ?? '',
      _target.romajiTitle ?? '',
    ];
    for (final title in titles) {
      final n = _norm(title);
      if (n.isNotEmpty) out.add('title:$n');
    }
    return out.toSet().toList(growable: false);
  }

  Future<int> _mappedMediaIdFromCache() async {
    final box = await _idMapBox();
    final keys = _cacheKeys(includeTitleKeys: _target.sourceMediaId <= 0);
    for (final key in keys) {
      final value = (box.get(key) as num?)?.toInt() ?? 0;
      if (value > 0) {
        AppLogger.i(
          'AniListSync',
          'id-map hit key="$key" -> $value',
        );
        return value;
      }
    }
    AppLogger.d(
      'AniListSync',
      'id-map miss sourceMediaId=${_target.sourceMediaId} keys=${keys.join(',')}',
    );
    return 0;
  }

  Future<void> _persistResolvedMediaId(
    int mediaId, {
    required bool includeTitleKeys,
  }) async {
    final box = await _idMapBox();
    final keys = _cacheKeys(includeTitleKeys: includeTitleKeys);
    for (final key in keys) {
      await box.put(key, mediaId);
    }
    AppLogger.i(
      'AniListSync',
      'id-map write mediaId=$mediaId includeTitleKeys=$includeTitleKeys keys=${keys.join(',')}',
    );
  }
}

@Deprecated('Use AniListTrackingController via aniListTrackingProvider.')
class MediaListEntryController extends StateNotifier<AniListTrackingEntry?> {
  MediaListEntryController(this._ref, this.mediaId) : super(null);

  final Ref _ref;
  final int mediaId;

  Future<void> loadFresh({bool force = false}) async {
    final source = _ref.read(librarySourceProvider);
    if (source == LibrarySource.local) {
      final local = await _ref.read(localLibraryStoreProvider).entryForMedia(mediaId);
      state = local?.toTrackingEntry();
      return;
    }
    final auth = _ref.read(authControllerProvider);
    final token = auth.token;
    if (token == null || token.isEmpty) {
      state = null;
      return;
    }
    state = await _ref
        .read(anilistClientProvider)
        .trackingEntry(token, mediaId, force: force);
  }

  void setLocal({
    required String status,
    required int progress,
    required double score,
  }) {
    state = AniListTrackingEntry(
      id: state?.id ?? 0,
      status: status,
      progress: progress,
      score: score,
    );
  }

  Future<bool> save({
    required String status,
    required int progress,
    required double score,
    AniListMedia? media,
    String? tokenOverride,
  }) async {
    final source = _ref.read(librarySourceProvider);
    if (source == LibrarySource.local) {
      final previous = state;
      setLocal(status: status, progress: progress, score: score);
      try {
        if (media != null) {
          await _ref.read(localLibraryStoreProvider).upsertFromMedia(
                media,
                status: status,
                progress: progress,
                score: score,
              );
        } else {
          await _ref.read(localLibraryStoreProvider).upsertByMediaId(
                mediaId,
                status: status,
                progress: progress,
                score: score,
              );
        }
        _ref.invalidate(localLibraryEntriesProvider);
        _ref.invalidate(mediaListProvider(mediaId));
        _ref.read(librarySyncBumpProvider.notifier).state++;
        return true;
      } catch (_) {
        state = previous;
        return false;
      }
    }

    final auth = _ref.read(authControllerProvider);
    final token = (tokenOverride != null && tokenOverride.isNotEmpty)
        ? tokenOverride
        : auth.token;
    if (token == null || token.isEmpty) {
      AppLogger.e('AniList', 'AniList Update Failed: No Token');
      return false;
    }

    final previous = state;
    setLocal(status: status, progress: progress, score: score);
    try {
      final saved = await _ref.read(anilistClientProvider).saveTrackingEntry(
            token: token,
            mediaId: mediaId,
            status: status,
            progress: progress,
            score: score,
          );
      state = saved;
      _ref.invalidate(mediaListProvider(mediaId));
      _ref.read(librarySyncBumpProvider.notifier).state++;
      return true;
    } catch (_) {
      state = previous;
      AppLogger.w('AniList', 'SaveMediaListEntry failed in controller.save');
      return false;
    }
  }

  Future<bool> remove({String? tokenOverride}) async {
    final source = _ref.read(librarySourceProvider);
    final previous = state;
    state = null;
    if (source == LibrarySource.local) {
      try {
        await _ref.read(localLibraryStoreProvider).removeByMediaId(mediaId);
        _ref.invalidate(localLibraryEntriesProvider);
        _ref.invalidate(mediaListProvider(mediaId));
        _ref.read(librarySyncBumpProvider.notifier).state++;
        return true;
      } catch (_) {
        state = previous;
        return false;
      }
    }

    final auth = _ref.read(authControllerProvider);
    final token = (tokenOverride != null && tokenOverride.isNotEmpty)
        ? tokenOverride
        : auth.token;
    if (token == null || token.isEmpty) {
      AppLogger.e('AniList', 'AniList Update Failed: No Token');
      state = previous;
      return false;
    }
    try {
      final ok = await _ref
          .read(anilistClientProvider)
          .deleteTrackingEntry(token: token, mediaId: mediaId);
      if (!ok) {
        state = previous;
        return false;
      }
      _ref.invalidate(mediaListProvider(mediaId));
      _ref.read(librarySyncBumpProvider.notifier).state++;
      return true;
    } catch (_) {
      state = previous;
      return false;
    }
  }
}
