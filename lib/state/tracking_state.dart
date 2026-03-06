import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_logger.dart';
import '../models/anilist_models.dart';
import '../services/local_library_store.dart';
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

final mediaListEntryControllerProvider = StateNotifierProvider.family<
    MediaListEntryController, AniListTrackingEntry?, int>((ref, mediaId) {
  return MediaListEntryController(ref, mediaId);
});

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
      return true;
    } catch (_) {
      state = previous;
      return false;
    }
  }
}
