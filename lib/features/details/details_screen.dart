import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:shimmer/shimmer.dart';

import '../../core/glass_widgets.dart';
import '../../core/haptics.dart';
import '../../core/image_cache.dart';
import '../../core/app_logger.dart';
import '../../models/anilist_models.dart';
import '../../models/sora_models.dart';
import '../../services/download_manager.dart';
import '../../services/local_library_store.dart';
import '../../services/progress_store.dart';
import '../../services/sora_runtime.dart';
import '../../state/app_settings_state.dart';
import '../../state/auth_state.dart';
import '../../state/episode_state.dart';
import '../../state/library_source_state.dart';
import '../../state/source_lock_state.dart';
import '../../state/tracking_state.dart';
import '../player/player_screen.dart';

class _SourceLoadFailure implements Exception {
  const _SourceLoadFailure(this.message, {this.providerDown = false});

  final String message;
  final bool providerDown;
}

class DetailsScreen extends ConsumerStatefulWidget {
  const DetailsScreen({super.key, required this.mediaId});

  final int mediaId;
  @override
  ConsumerState<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends ConsumerState<DetailsScreen> {
  int? _activeMediaId;
  SoraAnimeMatch? _manualMatch;
  int? _prefetchedForMediaId;
  bool _isBulkDownloading = false;
  int _bulkDone = 0;
  Color _detailBgSeed = const Color(0xFF090B13);
  final Map<String, Color> _detailPaletteCache = <String, Color>{};
  int _bulkTotal = 0;
  bool _sourceRequestInFlight = false;
  String? _sourceLoadError;
  SoraEpisode? _lastFailedEpisode;
  late Future<AniListMedia> _mediaDetailsFuture;
  int _visibleEpisodeCount = 24;
  bool _detailsBuildLogged = false;
  bool _detailsFirstFrameLogged = false;
  String? _bgPaletteLoadingKey;
  String? _lastPaletteRequestImage;
  AniListMedia? _previewMedia;
  bool _deferredInitStarted = false;
  bool _allowGlass = false;
  bool _emergencyResetTriggered = false;
  int _detailTabIndex = 0;
  final List<DateTime> _recentBuilds = <DateTime>[];
  String? _lastBuildSignature;
  final ValueNotifier<AsyncValue<EpisodeLoadResult>> _episodeState =
      ValueNotifier<AsyncValue<EpisodeLoadResult>>(const AsyncLoading());
  EpisodeQuery? _episodeLoadQuery;

  SoraRuntime get _sora => ref.read(soraRuntimeProvider);
  int get _currentMediaId => _activeMediaId ?? widget.mediaId;

  double _phoneDetailHeroHeight(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    return (w * 0.92).clamp(320.0, 420.0);
  }

  double _phoneEpisodeThumbWidth(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    return (w * 0.31).clamp(110.0, 138.0);
  }

  double _phoneEpisodeThumbHeight(BuildContext context) {
    final tw = _phoneEpisodeThumbWidth(context);
    return (tw * (9 / 16)).clamp(64.0, 82.0);
  }

  void _refreshPahe(AniListMedia media, {SoraAnimeMatch? manual}) {
    setState(() {
      _manualMatch = manual ?? _manualMatch;
      _visibleEpisodeCount = 24;
      _episodeLoadQuery = null;
      _episodeState.value = const AsyncLoading();
      if (_manualMatch != null) {
        _persistManualMatch(media.id, _manualMatch!);
      }
    });
    ref.invalidate(episodeProvider);
  }

  @override
  void initState() {
    super.initState();
    AppLogger.i('Details', 'initState mediaId=${widget.mediaId}');
    _previewMedia = _readCachedMediaPreview(widget.mediaId);
    _mediaDetailsFuture = Future<AniListMedia>.value(
      _previewMedia ??
          AniListMedia(
            id: widget.mediaId,
            title: AniListTitle(romaji: 'Loading...', english: 'Loading...'),
            cover: AniListCover(),
            isAdult: false,
          ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_detailsFirstFrameLogged) return;
      _detailsFirstFrameLogged = true;
      AppLogger.i('Details', 'first frame rendered mediaId=${widget.mediaId}');
      _startDeferredInit();
    });
  }

  @override
  void dispose() {
    _episodeState.dispose();
    super.dispose();
  }

  void _startDeferredInit() {
    if (_deferredInitStarted) return;
    _deferredInitStarted = true;
    ref.invalidate(episodeProvider);
    setState(() {
      _mediaDetailsFuture = _loadMediaDetails();
    });
    // Re-enable glass only after first content settles to avoid transition stalls.
    unawaited(Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      setState(() => _allowGlass = true);
    }));
  }

  Future<AniListMedia> _loadMediaDetails() async {
    final sw = Stopwatch()..start();
    final client = ref.read(anilistClientProvider);
    try {
      final media = await client
          .mediaDetails(_currentMediaId)
          .timeout(const Duration(seconds: 20));
      AppLogger.i(
        'Details',
        'mediaDetails loaded mediaId=$_currentMediaId in ${sw.elapsedMilliseconds}ms',
      );
      return media;
    } catch (e, st) {
      AppLogger.e(
        'Details',
        'mediaDetails failed mediaId=$_currentMediaId',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  void _switchWideMedia(int mediaId) {
    if (mediaId == _currentMediaId) return;
    setState(() {
      _activeMediaId = mediaId;
      _manualMatch = _readSavedMatch(mediaId);
      _prefetchedForMediaId = null;
      _visibleEpisodeCount = 24;
      _sourceLoadError = null;
      _lastFailedEpisode = null;
      _episodeLoadQuery = null;
      _episodeState.value = const AsyncLoading();
      _lastPaletteRequestImage = null;
      _mediaDetailsFuture = _loadMediaDetails();
    });
  }

  AniListMedia? _readCachedMediaPreview(int mediaId) {
    try {
      if (!Hive.isBoxOpen('anilist_media_cache')) return null;
      final box = Hive.box('anilist_media_cache');
      final raw = box.get(mediaId.toString());
      if (raw is! Map) return null;
      final data = raw['data'];
      if (data is! Map) return null;
      return AniListMedia.fromJson(Map<String, dynamic>.from(data));
    } catch (_) {
      return null;
    }
  }

  void _retryMediaDetails() {
    setState(() {
      _deferredInitStarted = true;
      _mediaDetailsFuture = _loadMediaDetails();
      _visibleEpisodeCount = 24;
      _episodeLoadQuery = null;
      _episodeState.value = const AsyncLoading();
    });
  }

  void _ensureEpisodesStreaming(EpisodeQuery query) {
    if (_episodeLoadQuery == query) return;
    Future<void>.delayed(const Duration(milliseconds: 180), () {
      if (!mounted) return;
      _loadEpisodesStreamed(query);
    });
  }

  void _loadEpisodesStreamed(EpisodeQuery query) {
    if (_episodeLoadQuery == query) return;
    _episodeLoadQuery = query;
    _episodeState.value = const AsyncLoading();
    unawaited(() async {
      try {
        final result = await ref
            .read(episodeProvider(query).future)
            .timeout(const Duration(seconds: 10));
        if (!mounted) return;
        _episodeState.value = AsyncData(result);
      } catch (e, st) {
        if (!mounted) return;
        _episodeState.value = AsyncError(e, st);
      }
    }());
  }

  void _retryEpisodesStreamed(EpisodeQuery query) {
    ref.invalidate(episodeProvider(query));
    _episodeLoadQuery = null;
    _visibleEpisodeCount = 24;
    _loadEpisodesStreamed(query);
  }

  void _watchBuildLoop(String signature) {
    if (_lastBuildSignature != signature) {
      _lastBuildSignature = signature;
      _recentBuilds.clear();
      return;
    }
    final now = DateTime.now();
    _recentBuilds.add(now);
    _recentBuilds.removeWhere((t) => now.difference(t).inMilliseconds > 100);
    if (_emergencyResetTriggered) return;
    if (_recentBuilds.length > 3) {
      _emergencyResetTriggered = true;
      AppLogger.w('Details',
          'Emergency break: excessive builds in short interval; resetting episode stream');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _episodeLoadQuery = null;
        });
        _episodeState.value = const AsyncLoading();
      });
    }
  }

  SoraAnimeMatch? _readSavedMatch(int mediaId) {
    final box = Hive.box('manual_matches');
    final raw = box.get(mediaId.toString());
    if (raw is! Map) return null;
    final title = (raw['title'] ?? '').toString();
    final image = (raw['image'] ?? '').toString();
    final href = (raw['href'] ?? '').toString();
    final session = (raw['session'] ?? '').toString();
    final animeId = (raw['animeId'] ?? '').toString();
    if (title.isEmpty || session.isEmpty || animeId.isEmpty) return null;
    return SoraAnimeMatch(
      title: title,
      image: image,
      href: href,
      session: session,
      animeId: animeId,
    );
  }

  Future<void> _persistManualMatch(int mediaId, SoraAnimeMatch match) async {
    final box = Hive.box('manual_matches');
    await box.put(mediaId.toString(), {
      'title': match.title,
      'image': match.image,
      'href': match.href,
      'session': match.session,
      'animeId': match.animeId,
    });
  }

  void _prefetchPlaybackData(AniListMedia media, List<SoraEpisode> episodes) {
    if (_prefetchedForMediaId == media.id) return;
    _prefetchedForMediaId = media.id;

    final firstThree = episodes.take(3).toList();
    final aniSkip = ref.read(aniSkipServiceProvider);

    for (final ep in firstThree) {
      if (media.idMal != null) {
        unawaited(aniSkip.prefetchOpeningRange(
          mediaId: media.id,
          episode: ep.number,
          malId: media.idMal,
        ));
      }
    }
  }

  String _episodeSpecificTitle(AniListMedia media, int episodeNumber) {
    final streamMeta = media.streamingEpisodes
        .where((se) => se.guessedEpisodeNumber == episodeNumber)
        .toList();
    if (streamMeta.isNotEmpty && streamMeta.first.title.trim().isNotEmpty) {
      return streamMeta.first.title.trim();
    }
    return '${media.title.best} - Episode $episodeNumber';
  }

  String _episodePlaybackTitle(AniListMedia media, int episodeNumber) {
    final title = _episodeSpecificTitle(media, episodeNumber).trim();
    if (title.toLowerCase().startsWith('episode ')) {
      return '${media.title.best} - $title';
    }
    return title;
  }

  String _cleanEpisodeTitle(String raw, int episodeNumber) {
    final pattern = RegExp(
      r'^(?:episode|ep)\s*0*' +
          RegExp.escape(episodeNumber.toString()) +
          r'\s*[:.\-–—]?\s*',
      caseSensitive: false,
    );
    final cleaned = raw.replaceFirst(pattern, '').trim();
    return cleaned.isEmpty ? 'Episode $episodeNumber' : cleaned;
  }

  String? _episodeThumbnailUrl(AniListMedia media, int episodeNumber) {
    for (final se in media.streamingEpisodes) {
      if (se.guessedEpisodeNumber == episodeNumber) {
        final thumb = se.thumbnail?.trim();
        if (thumb != null && thumb.isNotEmpty) return thumb;
      }
    }
    return null;
  }

  int _qualityRank(String q) {
    final m = RegExp(r'(\d+)').firstMatch(q);
    return int.tryParse(m?.group(1) ?? '') ?? 0;
  }

  SoraSource _pickSourceByPreference(
      List<SoraSource> sources, AppSettings settings,
      {String? preferredQuality, String? preferredAudio}) {
    final autoHls = sources.where((s) =>
        s.format.toLowerCase() == 'm3u8' &&
        s.quality.toLowerCase().contains('auto'));
    if (autoHls.isNotEmpty) return autoHls.first;

    var pool = [...sources]..sort(
        (a, b) => _qualityRank(b.quality).compareTo(_qualityRank(a.quality)));
    final audio = (preferredAudio ?? settings.preferredAudio).toLowerCase();
    final quality =
        (preferredQuality ?? settings.preferredQuality).toLowerCase();

    if (audio != 'any') {
      final filtered =
          pool.where((s) => s.subOrDub.toLowerCase() == audio).toList();
      if (filtered.isNotEmpty) pool = filtered;
    }
    if (quality != 'auto') {
      final exact =
          pool.where((s) => s.quality.toLowerCase().contains(quality)).toList();
      if (exact.isNotEmpty) return exact.first;
    }
    return pool.isNotEmpty ? pool.first : sources.first;
  }

  SoraSource _pickDownloadSource(List<SoraSource> sources, AppSettings settings,
      {String? preferredQuality, String? preferredAudio}) {
    return _pickSourceByPreference(
      sources,
      settings,
      preferredQuality: preferredQuality,
      preferredAudio: preferredAudio,
    );
  }

  Future<List<SoraSource>> _loadSourcesWithOverlay(
    AniListMedia media,
    SoraEpisode ep,
  ) async {
    final provider = episodeSourcesProvider(
      EpisodeSourceQuery(
        playUrl: ep.playUrl,
        anilistId: media.id,
        episodeNumber: ep.number,
      ),
    );

    var dialogOpen = false;
    final sub = ref.listenManual<AsyncValue<List<SoraSource>>>(
      provider,
      (_, next) {
        if (!mounted) return;
        if (next.isLoading && !dialogOpen) {
          dialogOpen = true;
          showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (_) => Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFA1E1E1E),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.10),
                  ),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 10),
                    Text(
                      'Loading stream...',
                      style: TextStyle(color: Colors.white),
                    ),
                  ],
                ),
              ),
            ),
          );
        } else if ((next.hasValue || next.hasError) && dialogOpen) {
          Navigator.of(context, rootNavigator: true).maybePop();
          dialogOpen = false;
        }
      },
    );

    try {
      Object? lastError;
      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          final result = await ref
              .read(provider.future)
              .timeout(const Duration(seconds: 45));
          if (result.isEmpty) {
            throw const _SourceLoadFailure(
              'Stream not found or timeout.',
              providerDown: true,
            );
          }
          return result;
        } catch (e) {
          lastError = e;
          if (attempt < 3) {
            ref.invalidate(provider);
            await Future<void>.delayed(
              Duration(milliseconds: 500 * attempt),
            );
          }
        }
      }

      if (lastError is DioException) {
        final status = lastError.response?.statusCode ?? 0;
        final timedOut = lastError.type == DioExceptionType.connectionTimeout ||
            lastError.type == DioExceptionType.receiveTimeout;
        final providerDown = timedOut || status == 429 || status >= 500;
        throw _SourceLoadFailure(
          providerDown
              ? 'Provider is unavailable right now. Try another source/episode.'
              : 'Stream not found or timeout.',
          providerDown: providerDown,
        );
      }
      if (lastError is SocketException) {
        throw const _SourceLoadFailure(
          'Network is offline or unstable. Check your connection and retry.',
          providerDown: true,
        );
      }
      if (lastError is _SourceLoadFailure) {
        throw lastError;
      }
      throw const _SourceLoadFailure('Stream not found or timeout.');
    } finally {
      sub.close();
      if (dialogOpen && mounted) {
        Navigator.of(context, rootNavigator: true).maybePop();
      }
    }
  }

  Future<SoraSource?> _showSourcePicker(List<SoraSource> sources) async {
    final sorted = [...sources]..sort(
        (a, b) => _qualityRank(b.quality).compareTo(_qualityRank(a.quality)));
    return showModalBottomSheet<SoraSource>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: GlassContainer(
            borderRadius: 22,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Choose Stream',
                    style:
                        TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                ...sorted.map((s) => ListTile(
                      title: Text('${s.quality} - ${s.subOrDub.toUpperCase()}'),
                      subtitle: Text(s.format.toUpperCase()),
                      onTap: () => Navigator.of(context).pop(s),
                    )),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _lockSessionSource(SoraSource source) {
    ref.read(sessionSourceLockProvider.notifier).lockFromSelection(
          sourceUrl: source.url,
          quality: source.quality,
          audio: source.subOrDub,
          format: source.format,
        );
  }

  Future<({int start, int end})?> _pickEpisodeRange(
    int minEpisode,
    int maxEpisode,
  ) async {
    final startController = TextEditingController(text: '$minEpisode');
    final endController = TextEditingController(text: '$maxEpisode');
    return showDialog<({int start, int end})>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Range'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: startController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Start Episode'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: endController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'End Episode'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final start =
                  int.tryParse(startController.text.trim()) ?? minEpisode;
              final end = int.tryParse(endController.text.trim()) ?? maxEpisode;
              final clampedStart = start.clamp(minEpisode, maxEpisode);
              final clampedEnd = end.clamp(clampedStart, maxEpisode);
              Navigator.of(context).pop((start: clampedStart, end: clampedEnd));
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadAllEpisodes(
    AniListMedia media,
    List<SoraEpisode> episodes,
  ) async {
    if (_isBulkDownloading || episodes.isEmpty) return;
    final numbers = episodes.map((e) => e.number).toList()..sort();
    final minEpisode = numbers.first;
    final maxEpisode = numbers.last;
    final range = await _pickEpisodeRange(minEpisode, maxEpisode);
    if (!mounted || range == null) return;
    final selectedEpisodes = episodes
        .where((ep) => ep.number >= range.start && ep.number <= range.end)
        .toList();
    if (selectedEpisodes.isEmpty) return;

    List<SoraSource> probeSources;
    try {
      probeSources =
          await _loadSourcesWithOverlay(media, selectedEpisodes.first);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Unable to load stream sources right now.')),
      );
      return;
    }
    if (!mounted || probeSources.isEmpty) return;
    final settings = ref.read(appSettingsProvider);
    final chosen = settings.chooseStreamEveryTime
        ? await _showSourcePicker(probeSources)
        : _pickDownloadSource(probeSources, settings);
    if (!mounted || chosen == null) return;
    _lockSessionSource(chosen);

    setState(() {
      _isBulkDownloading = true;
      _bulkDone = 0;
      _bulkTotal = selectedEpisodes.length;
    });

    try {
      for (final ep in selectedEpisodes) {
        final local = await ref
            .read(downloadControllerProvider.notifier)
            .localManifestPath(media.id, ep.number);
        if (local == null) {
          List<SoraSource> sources;
          try {
            sources = await _loadSourcesWithOverlay(media, ep);
          } catch (_) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                  content:
                      Text('Source load failed for episode ${ep.number}.')),
            );
            continue;
          }
          if (sources.isNotEmpty) {
            final sameProvider = sources
                .where(
                  (s) =>
                      sourceProviderIdFromUrl(s.url) ==
                      sourceProviderIdFromUrl(chosen.url),
                )
                .toList();
            final pool = sameProvider.isNotEmpty ? sameProvider : sources;
            final selected = _pickDownloadSource(
              pool,
              settings,
              preferredQuality: chosen.quality,
              preferredAudio: chosen.subOrDub,
            );
            await ref
                .read(downloadControllerProvider.notifier)
                .downloadHlsEpisode(
                  mediaId: media.id,
                  episode: ep.number,
                  animeTitle: media.title.best,
                  coverImageUrl: media.cover.best,
                  episodeThumbnailUrl: _episodeThumbnailUrl(media, ep.number),
                  source: selected,
                );
          }
        }
        if (!mounted) return;
        setState(() => _bulkDone++);
      }
    } finally {
      if (mounted) {
        setState(() => _isBulkDownloading = false);
      }
    }
  }

  Future<SoraAnimeMatch?> _openManualMatchPicker(AniListMedia media) async {
    final controller = TextEditingController(text: media.title.best);
    var results = <SoraAnimeMatch>[];
    return showModalBottomSheet<SoraAnimeMatch>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, setModalState) {
          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              child: GlassContainer(
                borderRadius: 22,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Text('Manual Match',
                            style: TextStyle(
                                fontSize: 20, fontWeight: FontWeight.w800)),
                        const Spacer(),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                    TextField(
                      controller: controller,
                      decoration: InputDecoration(
                        hintText: 'Search AnimePahe title',
                        suffixIcon: IconButton(
                          onPressed: () async {
                            final r =
                                await _sora.searchAnime(controller.text.trim());
                            setModalState(() => results = r);
                          },
                          icon: const Icon(Icons.search),
                        ),
                      ),
                      onSubmitted: (value) async {
                        final r = await _sora.searchAnime(value.trim());
                        setModalState(() => results = r);
                      },
                    ),
                    const SizedBox(height: 8),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: results.length,
                        itemBuilder: (context, index) {
                          final item = results[index];
                          return ListTile(
                            title: Text(item.title,
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            subtitle: Text(item.session),
                            onTap: () => Navigator.of(context).pop(item),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openTrackingSheet(AniListMedia media, String? token) async {
    hapticTap();
    final source = ref.read(librarySourceProvider);
    try {
      final refreshed = await ref.refresh(mediaListProvider(media.id).future);
      if (refreshed != null) {
        ref.read(mediaListEntryControllerProvider(media.id).notifier).setLocal(
              status: refreshed.status,
              progress: refreshed.progress,
              score: refreshed.score,
            );
      }
    } catch (_) {}
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.82,
        child: Container(
          decoration: const BoxDecoration(
            color: Color(0xFF10131F),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: source == LibrarySource.anilist &&
                      (token == null || token.isEmpty)
                  ? const Center(
                      child: Text(
                        'Connect AniList to manage list, score, and progress.',
                      ),
                    )
                  : SingleChildScrollView(
                      child: _TrackingPane(token: token, media: media),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleBookmarkTap(
    AniListMedia media, {
    required bool inAnyList,
    required bool trackingResolved,
    required String? token,
  }) async {
    final source = ref.read(librarySourceProvider);
    if (source == LibrarySource.anilist && !trackingResolved) {
      await _openTrackingSheet(media, token);
      return;
    }
    if (inAnyList) {
      await _openTrackingSheet(media, token);
      return;
    }

    if (source == LibrarySource.local) {
      await ref.read(localLibraryStoreProvider).upsertFromMedia(
            media,
            status: 'PLANNING',
            progress: 0,
            score: 0,
          );
      ref.invalidate(localLibraryEntriesProvider);
      ref.invalidate(mediaListProvider(media.id));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Added to Planning (Local).')),
      );
      return;
    }

    final ok = await ref
        .read(mediaListEntryControllerProvider(media.id).notifier)
        .save(
          status: 'PLANNING',
          progress: 0,
          score: 0,
          media: media,
          tokenOverride: token,
        );
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to add to AniList.')),
      );
      return;
    }
    ref.invalidate(mediaListProvider(media.id));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Added to Planning.')),
    );
  }

  SoraEpisode _pickSmartEpisode(
    List<SoraEpisode> episodes,
    ProgressStore progressStore,
  ) {
    if (episodes.isEmpty) {
      throw StateError('No episodes available');
    }
    var watchedUpTo = 0;
    for (final entry in progressStore.allForMedia(widget.mediaId)) {
      if (entry.value.percent >= 0.85 && entry.key > watchedUpTo) {
        watchedUpTo = entry.key;
      }
    }
    if (watchedUpTo <= 0) {
      return episodes.first;
    }
    final target = watchedUpTo + 1;
    for (final ep in episodes) {
      if (ep.number == target) {
        return ep;
      }
    }
    for (final ep in episodes) {
      if (ep.number > watchedUpTo) {
        return ep;
      }
    }
    return episodes.first;
  }

  Future<void> _playEpisode(
    AniListMedia media,
    SoraEpisode ep,
  ) async {
    if (_sourceRequestInFlight) return;
    setState(() {
      _sourceRequestInFlight = true;
      _sourceLoadError = null;
      _lastFailedEpisode = null;
    });
    try {
      final navigator = Navigator.of(context);
      final messenger = ScaffoldMessenger.of(context);
      final local = await ref
          .read(downloadControllerProvider.notifier)
          .getLocalEpisodeByMedia(media.id, ep.number);
      if (local != null) {
        if (!context.mounted) return;
        navigator.push(
          MaterialPageRoute(
            builder: (_) => PlayerScreen(
              mediaId: media.id,
              episodeNumber: ep.number,
              episodeTitle: _episodePlaybackTitle(media, ep.number),
              sourceUrl: local.path,
              isLocal: true,
              backgroundImageUrl: media.cover.best ?? media.bannerImage,
              mediaTitle: media.title.best,
              malId: media.idMal,
            ),
          ),
        );
        return;
      }

      List<SoraSource> sources;
      try {
        sources = await _loadSourcesWithOverlay(media, ep);
      } on _SourceLoadFailure catch (e) {
        if (!context.mounted) return;
        setState(() {
          _sourceLoadError = e.message;
          _lastFailedEpisode = ep;
        });
        messenger.showSnackBar(
          SnackBar(content: Text(e.message)),
        );
        return;
      } catch (_) {
        if (!context.mounted) return;
        setState(() {
          _sourceLoadError = 'Error: Stream not found or Timeout';
          _lastFailedEpisode = ep;
        });
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Stream source timed out. Please try again.'),
          ),
        );
        return;
      }
      if (sources.isEmpty) {
        if (!context.mounted) return;
        setState(() {
          _sourceLoadError = 'Error: Stream not found or Timeout';
          _lastFailedEpisode = ep;
        });
        messenger.showSnackBar(
          const SnackBar(content: Text('No sources found for episode.')),
        );
        return;
      }
      final settings = ref.read(appSettingsProvider);
      final selected = _pickSourceByPreference(sources, settings);
      if (!context.mounted) return;
      _lockSessionSource(selected);
      final fallback = sources
          .map((s) => PlayerSourceOption(url: s.url, headers: s.headers))
          .toList();
      navigator.push(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            mediaId: media.id,
            episodeNumber: ep.number,
            episodeTitle: _episodePlaybackTitle(media, ep.number),
            sourceUrl: selected.url,
            headers: selected.headers,
            backgroundImageUrl: media.cover.best ?? media.bannerImage,
            mediaTitle: media.title.best,
            malId: media.idMal,
            fallbackSources: fallback,
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _sourceRequestInFlight = false);
      } else {
        _sourceRequestInFlight = false;
      }
    }
  }

  Future<void> _downloadEpisodeWithPicker(
    AniListMedia media,
    SoraEpisode ep,
  ) async {
    final sources = await _loadSourcesWithOverlay(media, ep);
    if (sources.isEmpty) return;
    final settings = ref.read(appSettingsProvider);
    final selected = settings.chooseStreamEveryTime
        ? await _showSourcePicker(sources)
        : _pickDownloadSource(sources, settings);
    if (selected == null) return;
    _lockSessionSource(selected);
    await ref.read(downloadControllerProvider.notifier).downloadHlsEpisode(
          mediaId: media.id,
          episode: ep.number,
          animeTitle: media.title.best,
          coverImageUrl: media.cover.best,
          episodeThumbnailUrl: _episodeThumbnailUrl(
            media,
            ep.number,
          ),
          source: selected,
        );
  }

  Future<void> _showEpisodeLongPressActions(
    AniListMedia media,
    SoraEpisode ep,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: GlassContainer(
            borderRadius: 18,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.download_rounded),
                  title: Text('Download Episode ${ep.number}'),
                  onTap: () {
                    Navigator.of(context).pop();
                    unawaited(_downloadEpisodeWithPicker(media, ep));
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleManualMatchTap(AniListMedia media) async {
    final manual = await _openManualMatchPicker(media);
    if (!mounted || manual == null) return;
    _refreshPahe(media, manual: manual);
  }

  Future<void> _handleDownloadAllTap(AniListMedia media) async {
    final episodes =
        _episodeState.value.valueOrNull?.episodes ?? const <SoraEpisode>[];
    if (episodes.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Episodes are still loading.')),
      );
      return;
    }
    await _downloadAllEpisodes(media, episodes);
  }

  Future<void> _retryLastFailedSource(AniListMedia media) async {
    final ep = _lastFailedEpisode;
    if (ep == null || _sourceRequestInFlight) return;
    setState(() => _sourceLoadError = null);
    await _playEpisode(media, ep);
  }

  Future<void> _playSmartEpisode(
    AniListMedia media,
    EpisodeQuery episodeQuery,
    ProgressStore progressStore,
  ) async {
    try {
      final cached = _episodeLoadQuery == episodeQuery
          ? _episodeState.value.valueOrNull
          : null;
      final EpisodeLoadResult result =
          cached ?? await ref.read(episodeProvider(episodeQuery).future);
      final episodes = result.episodes;
      if (episodes.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No episodes available yet.')),
        );
        return;
      }

      final ep = _pickSmartEpisode(episodes, progressStore);
      await _playEpisode(media, ep);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Unable to start playback right now.')),
      );
    }
  }

  Future<void> _updateDetailBackground(AniListMedia media) async {
    final image = media.bannerImage ?? media.cover.best;
    if (image == null || image.isEmpty) return;
    if (_bgPaletteLoadingKey == image) return;
    final cached = _detailPaletteCache[image];
    if (cached != null) {
      if (!mounted || _detailBgSeed.toARGB32() == cached.toARGB32()) return;
      setState(() => _detailBgSeed = cached);
      return;
    }
    _bgPaletteLoadingKey = image;
    try {
      final palette = await PaletteGenerator.fromImageProvider(
        KyomiruImageCache.provider(image),
        size: const Size(120, 120),
        maximumColorCount: 12,
      );
      final picked = palette.dominantColor?.color ??
          palette.vibrantColor?.color ??
          palette.mutedColor?.color;
      if (picked == null) return;
      _detailPaletteCache[image] = picked;
      if (!mounted || _detailBgSeed.toARGB32() == picked.toARGB32()) return;
      setState(() => _detailBgSeed = picked);
    } catch (_) {
    } finally {
      if (_bgPaletteLoadingKey == image) {
        _bgPaletteLoadingKey = null;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_detailsBuildLogged) {
      _detailsBuildLogged = true;
      AppLogger.i('Details', 'build start mediaId=${widget.mediaId}');
    }
    _watchBuildLoop(
      '$_deferredInitStarted-${_episodeState.value.runtimeType}-$_sourceRequestInFlight-$_isBulkDownloading-$_allowGlass',
    );
    final progressStore = ref.watch(progressStoreProvider);
    final auth = ref.watch(authControllerProvider);
    final uiSettings = ref.watch(appSettingsProvider);

    return FutureBuilder<AniListMedia>(
      future: _mediaDetailsFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          final preview = _previewMedia;
          if (preview == null) {
            return const Scaffold(body: _DetailsLoadingSkeleton());
          }
          final episodeQuery = EpisodeQuery(
            mediaId: preview.id,
            title: preview.title.best,
            manualMatch: _manualMatch,
          );
          return Scaffold(
            backgroundColor: Colors.black,
            body: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.arrow_back_ios_new_rounded,
                          size: 18),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      preview.title.best,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w900,
                        height: 1.05,
                      ),
                    ),
                    const SizedBox(height: 14),
                    _LiteCard(
                      child: Row(
                        children: [
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'Loading details and episodes...',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.tonal(
                            onPressed: _retryMediaDetails,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child:
                          ValueListenableBuilder<AsyncValue<EpisodeLoadResult>>(
                        valueListenable: _episodeState,
                        builder: (context, episodeAsync, _) {
                          if (episodeAsync.isLoading) {
                            return const _EpisodeListLoadingSkeleton();
                          }
                          if (episodeAsync.hasError) {
                            final err = episodeAsync.error;
                            final serverBusy = err is TimeoutException;
                            return _LiteCard(
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.error_outline_rounded,
                                    color: Colors.orangeAccent,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      serverBusy
                                          ? 'Server Busy. Try again.'
                                          : 'Episode loading failed. Try again.',
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  FilledButton.tonal(
                                    onPressed: () =>
                                        _retryEpisodesStreamed(episodeQuery),
                                    child: const Text('Retry'),
                                  ),
                                ],
                              ),
                            );
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        if (snap.hasError || snap.data == null) {
          return Scaffold(
            appBar: GlassAppBar(
              title: const Text('Details'),
              leading: IconButton(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
              ),
            ),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Failed to load details: ${snap.error}',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: _retryMediaDetails,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        final media = snap.data!;
        _manualMatch ??= _readSavedMatch(media.id);
        final trackingEntryAsync = ref.watch(mediaListProvider(media.id));
        final optimisticTracking =
            ref.watch(mediaListEntryControllerProvider(media.id));
        final inAnyList = trackingEntryAsync.valueOrNull != null ||
            optimisticTracking != null;
        final trackingResolved = trackingEntryAsync.hasValue;
        final episodeQuery = EpisodeQuery(
          mediaId: media.id,
          title: media.title.best,
          manualMatch: _manualMatch,
        );
        _ensureEpisodesStreaming(episodeQuery);
        final description = (media.description ?? '')
            .replaceAll(RegExp(r'<[^>]*>'), ' ')
            .trim();

        if (uiSettings.enableDynamicColors && _allowGlass) {
          final paletteImage = media.bannerImage ?? media.cover.best;
          if (paletteImage != null &&
              paletteImage.isNotEmpty &&
              _lastPaletteRequestImage != paletteImage) {
            _lastPaletteRequestImage = paletteImage;
            unawaited(_updateDetailBackground(media));
          }
        }
        const bgBase = Color(0xFF000000);
        final isWide = MediaQuery.sizeOf(context).width > 600;
        final mobileHeroHeight = _phoneDetailHeroHeight(context);
        final mobileThumbWidth = _phoneEpisodeThumbWidth(context);
        final mobileThumbHeight = _phoneEpisodeThumbHeight(context);
        if (isWide) {
          return _WideDetailsScaffold(
            media: media,
            description: description,
            inAnyList: inAnyList,
            trackingResolved: trackingResolved,
            token: auth.token,
            onPlay: () => _playSmartEpisode(media, episodeQuery, progressStore),
            onBookmark: () => _handleBookmarkTap(
              media,
              inAnyList: inAnyList,
              trackingResolved: trackingResolved,
              token: auth.token,
            ),
            onManualMatch: () => _handleManualMatchTap(media),
            onDownloadAll: () => _handleDownloadAllTap(media),
            onBack: () => Navigator.of(context).maybePop(),
            onSelectRelation: _switchWideMedia,
            episodeState: _episodeState,
            onRetryEpisodes: () => _retryEpisodesStreamed(episodeQuery),
            onPlayEpisode: (ep) => _playEpisode(media, ep),
            onDownloadEpisode: (ep) => _downloadEpisodeWithPicker(media, ep),
            episodeTitleFor: (episodeNumber) =>
                _episodeSpecificTitle(media, episodeNumber),
            episodeThumbFor: (episodeNumber) =>
                _episodeThumbnailUrl(media, episodeNumber),
            fallbackImage: media.bannerImage ?? media.cover.best,
          );
        }
        return Scaffold(
          body: Container(
            color: bgBase,
            child: NestedScrollView(
              headerSliverBuilder: (context, innerBoxIsScrolled) => [
                SliverAppBar(
                  expandedHeight: mobileHeroHeight,
                  pinned: true,
                  stretch: true,
                  backgroundColor: Colors.black,
                  leading: IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon:
                        const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
                  ),
                  flexibleSpace: FlexibleSpaceBar(
                    collapseMode: CollapseMode.parallax,
                    background: _BadlandsHero(
                      media: media,
                      inAnyList: inAnyList,
                      onPlay: () =>
                          _playSmartEpisode(media, episodeQuery, progressStore),
                      onBookmark: () => _handleBookmarkTap(
                        media,
                        inAnyList: inAnyList,
                        trackingResolved: trackingResolved,
                        token: auth.token,
                      ),
                    ),
                  ),
                ),
              ],
              body: ListView(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 100),
                children: [
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.12),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() => _detailTabIndex = 0),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeOut,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                color: _detailTabIndex == 0
                                    ? Colors.white.withValues(alpha: 0.16)
                                    : Colors.transparent,
                              ),
                              child: const Center(
                                child: Text(
                                  'Episodes',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setState(() => _detailTabIndex = 1),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeOut,
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                color: _detailTabIndex == 1
                                    ? Colors.white.withValues(alpha: 0.16)
                                    : Colors.transparent,
                              ),
                              child: const Center(
                                child: Text(
                                  'AniList',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_detailTabIndex == 0)
                    ValueListenableBuilder<AsyncValue<EpisodeLoadResult>>(
                      valueListenable: _episodeState,
                      builder: (context, episodeAsync, _) {
                        if (episodeAsync.isLoading) {
                          return const _EpisodeListLoadingSkeleton();
                        }

                        if (episodeAsync.hasError) {
                          final err = episodeAsync.error;
                          final serverBusy = err is TimeoutException;
                          return _LiteCard(
                            child: Row(
                              children: [
                                const Icon(Icons.error_outline_rounded,
                                    color: Colors.orangeAccent),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    serverBusy
                                        ? 'Server Busy. Try again.'
                                        : 'Episode loading failed. Please retry.',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                FilledButton.tonal(
                                  onPressed: () =>
                                      _retryEpisodesStreamed(episodeQuery),
                                  child: const Text('Retry'),
                                ),
                              ],
                            ),
                          );
                        }

                        final data = episodeAsync.valueOrNull;
                        if (data == null ||
                            data.match == null ||
                            data.episodes.isEmpty) {
                          return _LiteCard(
                            child: Row(
                              children: [
                                const Expanded(
                                  child: Text(
                                    'Could not load AnimePahe episodes for this title.',
                                  ),
                                ),
                                FilledButton.tonal(
                                  onPressed: () => _refreshPahe(media),
                                  child: const Text('Retry'),
                                ),
                                const SizedBox(width: 8),
                                FilledButton.tonal(
                                  onPressed: () async {
                                    final manual =
                                        await _openManualMatchPicker(media);
                                    if (manual != null) {
                                      _refreshPahe(media, manual: manual);
                                    }
                                  },
                                  child: const Text('Manual Match'),
                                ),
                              ],
                            ),
                          );
                        }

                        final episodes = data.episodes;
                        final shownCount =
                            episodes.length < _visibleEpisodeCount
                                ? episodes.length
                                : _visibleEpisodeCount;
                        final visibleEpisodes =
                            episodes.take(shownCount).toList();
                        final hasMoreEpisodes = shownCount < episodes.length;
                        final glassReady = _allowGlass;
                        _prefetchPlaybackData(media, episodes);
                        return Column(
                          children: [
                            glassReady
                                ? GlassCard(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            const Icon(Icons.link),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                data.match!.title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: [
                                            const _InlineActionPill(
                                              icon: Icons.hub_rounded,
                                              label: 'AnimePahe',
                                              onTap: null,
                                            ),
                                            _InlineActionPill(
                                              icon: Icons.tune_rounded,
                                              label: _manualMatch == null
                                                  ? 'Auto'
                                                  : 'Manual',
                                              onTap: null,
                                            ),
                                            _InlineActionPill(
                                              icon: Icons.link_rounded,
                                              label: 'Manual',
                                              onTap: () async {
                                                final manual =
                                                    await _openManualMatchPicker(
                                                        media);
                                                if (manual != null) {
                                                  _refreshPahe(media,
                                                      manual: manual);
                                                }
                                              },
                                            ),
                                            _InlineActionPill(
                                              icon: Icons.refresh_rounded,
                                              label: 'Refresh',
                                              onTap: () => _refreshPahe(media),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  )
                                : _LiteCard(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            const Icon(Icons.link),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                data.match!.title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: [
                                            const _InlineActionPill(
                                              icon: Icons.hub_rounded,
                                              label: 'AnimePahe',
                                              onTap: null,
                                            ),
                                            _InlineActionPill(
                                              icon: Icons.tune_rounded,
                                              label: _manualMatch == null
                                                  ? 'Auto'
                                                  : 'Manual',
                                              onTap: null,
                                            ),
                                            _InlineActionPill(
                                              icon: Icons.link_rounded,
                                              label: 'Manual',
                                              onTap: () async {
                                                final manual =
                                                    await _openManualMatchPicker(
                                                        media);
                                                if (manual != null) {
                                                  _refreshPahe(media,
                                                      manual: manual);
                                                }
                                              },
                                            ),
                                            _InlineActionPill(
                                              icon: Icons.refresh_rounded,
                                              label: 'Refresh',
                                              onTap: () => _refreshPahe(media),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                const Text(
                                  'Episodes',
                                  style: TextStyle(
                                    fontSize: 30,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const Spacer(),
                                if (_isBulkDownloading)
                                  _InlineActionPill(
                                    icon: Icons.downloading_rounded,
                                    label: '$_bulkDone/$_bulkTotal',
                                    onTap: null,
                                    showProgress: true,
                                  )
                                else
                                  _InlineActionPill(
                                    icon: Icons.download_for_offline_outlined,
                                    label: 'Download All',
                                    onTap: () => _downloadAllEpisodes(
                                      media,
                                      episodes,
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            if (_sourceLoadError != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: glassReady
                                    ? GlassCard(
                                        child: Row(
                                          children: [
                                            const Icon(
                                                Icons.error_outline_rounded,
                                                color: Colors.orangeAccent),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Text(
                                                'Error: $_sourceLoadError',
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            FilledButton.tonal(
                                              onPressed: _lastFailedEpisode ==
                                                      null
                                                  ? null
                                                  : () =>
                                                      _retryLastFailedSource(
                                                          media),
                                              child: const Text('Retry'),
                                            ),
                                          ],
                                        ),
                                      )
                                    : _LiteCard(
                                        child: Row(
                                          children: [
                                            const Icon(
                                                Icons.error_outline_rounded,
                                                color: Colors.orangeAccent),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Text(
                                                'Error: $_sourceLoadError',
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            FilledButton.tonal(
                                              onPressed: _lastFailedEpisode ==
                                                      null
                                                  ? null
                                                  : () =>
                                                      _retryLastFailedSource(
                                                          media),
                                              child: const Text('Retry'),
                                            ),
                                          ],
                                        ),
                                      ),
                              ),
                            ...visibleEpisodes.map((ep) {
                              final p = progressStore.read(media.id, ep.number);
                              final pct = p?.percent ?? 0;
                              final thumb =
                                  _episodeThumbnailUrl(media, ep.number);
                              final fallbackThumb = media.bannerImage;
                              final episodeSubtitle = _cleanEpisodeTitle(
                                _episodeSpecificTitle(media, ep.number),
                                ep.number,
                              );

                              return Padding(
                                padding: const EdgeInsets.only(bottom: 6),
                                child: RepaintBoundary(
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: _sourceRequestInFlight
                                        ? null
                                        : () => _playEpisode(media, ep),
                                    onLongPress: () =>
                                        _showEpisodeLongPressActions(media, ep),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: uiSettings.isOledBlack
                                            ? Colors.black
                                            : const Color(0xFF161822),
                                        borderRadius: BorderRadius.circular(14),
                                        border: Border.all(
                                          color: Colors.white
                                              .withValues(alpha: 0.08),
                                        ),
                                      ),
                                      child: Stack(
                                        children: [
                                          Row(
                                            children: [
                                              SizedBox(
                                                width: mobileThumbWidth,
                                                height: mobileThumbHeight,
                                                child: _EpisodeRowThumb(
                                                  mediaId: media.id,
                                                  episode: ep.number,
                                                  progress: pct,
                                                  networkThumbUrl: thumb,
                                                  fallbackUrl: fallbackThumb,
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Row(
                                                      children: [
                                                        Expanded(
                                                          child: Text(
                                                            episodeSubtitle,
                                                            maxLines: 2,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style:
                                                                const TextStyle(
                                                              fontSize: 14,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w700,
                                                            ),
                                                          ),
                                                        ),
                                                        _EpisodeLocalCheck(
                                                          mediaId: media.id,
                                                          episodeNumber:
                                                              ep.number,
                                                        ),
                                                      ],
                                                    ),
                                                    _EpisodeDownloadStatusText(
                                                      mediaId: media.id,
                                                      episodeNumber: ep.number,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              ProgressRing(
                                                percent: pct,
                                                size: 46,
                                              ),
                                              const SizedBox(width: 2),
                                            ],
                                          ),
                                          Positioned(
                                            top: 0,
                                            right: 0,
                                            child: _EpisodeDownloadAction(
                                              mediaId: media.id,
                                              episodeNumber: ep.number,
                                              onDownloadTap: () =>
                                                  _downloadEpisodeWithPicker(
                                                media,
                                                ep,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            }),
                            if (hasMoreEpisodes)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Center(
                                  child: FilledButton.tonal(
                                    onPressed: () {
                                      setState(() {
                                        _visibleEpisodeCount += 24;
                                      });
                                    },
                                    child: Text(
                                      'Load More (${episodes.length - shownCount} left)',
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  if (_detailTabIndex == 1)
                    Column(
                      children: [
                        _TrackingPane(token: auth.token, media: media),
                        const SizedBox(height: 10),
                        GlassCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                media.title.best,
                                style: const TextStyle(
                                    fontSize: 22, fontWeight: FontWeight.w800),
                              ),
                              const SizedBox(height: 8),
                              _ExpandableSynopsis(
                                text: description.isEmpty
                                    ? 'No description.'
                                    : description,
                                collapsedLines: 2,
                              ),
                              const SizedBox(height: 10),
                              if (media.genres.isNotEmpty)
                                Text(
                                  'Genres: ${media.genres.join(', ')}',
                                  style:
                                      const TextStyle(color: Color(0xFFA1A8BC)),
                                ),
                              const SizedBox(height: 6),
                              Text(
                                'Studio: ${media.studios.isEmpty ? 'Unknown' : media.studios.join(', ')}',
                                style:
                                    const TextStyle(color: Color(0xFFA1A8BC)),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        GlassCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Relations',
                                style: TextStyle(
                                    fontSize: 18, fontWeight: FontWeight.w800),
                              ),
                              const SizedBox(height: 8),
                              if (media.relations.isEmpty)
                                const Text(
                                  'No relations available.',
                                  style: TextStyle(color: Color(0xFF9AA0B3)),
                                )
                              else
                                SizedBox(
                                  height: 180,
                                  child: ListView.separated(
                                    scrollDirection: Axis.horizontal,
                                    itemCount: media.relations.length,
                                    separatorBuilder: (_, __) =>
                                        const SizedBox(width: 10),
                                    itemBuilder: (context, index) {
                                      final rel = media.relations[index];
                                      final relImage = rel.media.cover.best ??
                                          rel.media.bannerImage;
                                      return SizedBox(
                                        width: 160,
                                        child: InkWell(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          onTap: () {
                                            if ((rel.media.mediaType ??
                                                    'ANIME') ==
                                                'ANIME') {
                                              Navigator.of(context).push(
                                                MaterialPageRoute(
                                                  builder: (_) => DetailsScreen(
                                                      mediaId: rel.media.id),
                                                ),
                                              );
                                              return;
                                            }
                                            showDialog<void>(
                                              context: context,
                                              builder: (_) => AlertDialog(
                                                title:
                                                    Text(rel.media.title.best),
                                                content: Text(
                                                  '${rel.relationType.replaceAll('_', ' ').toLowerCase()} is not a playable anime entry.',
                                                ),
                                                actions: [
                                                  TextButton(
                                                    onPressed: () =>
                                                        Navigator.of(context)
                                                            .pop(),
                                                    child: const Text('OK'),
                                                  ),
                                                ],
                                              ),
                                            );
                                          },
                                          child: ClipRRect(
                                            borderRadius:
                                                BorderRadius.circular(12),
                                            child: Stack(
                                              fit: StackFit.expand,
                                              children: [
                                                if (relImage != null)
                                                  Hero(
                                                    tag:
                                                        'detail-banner-${rel.media.id}',
                                                    child:
                                                        KyomiruImageCache.image(
                                                      relImage,
                                                      fit: BoxFit.cover,
                                                    ),
                                                  )
                                                else
                                                  const ColoredBox(
                                                    color: Color(0x22111111),
                                                  ),
                                                Positioned.fill(
                                                  child: Container(
                                                    decoration:
                                                        const BoxDecoration(
                                                      gradient: LinearGradient(
                                                        begin:
                                                            Alignment.topCenter,
                                                        end: Alignment
                                                            .bottomCenter,
                                                        colors: [
                                                          Colors.transparent,
                                                          Color(0xC9000000),
                                                        ],
                                                        stops: [0.48, 1.0],
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                Positioned(
                                                  left: 8,
                                                  right: 8,
                                                  bottom: 8,
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      Text(
                                                        rel.media.title.best,
                                                        maxLines: 2,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: const TextStyle(
                                                          fontWeight:
                                                              FontWeight.w700,
                                                        ),
                                                      ),
                                                      Text(
                                                        rel.relationType
                                                            .replaceAll(
                                                                '_', ' ')
                                                            .toLowerCase(),
                                                        style: const TextStyle(
                                                          fontSize: 11,
                                                          color: Colors.white70,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LiteCard extends StatelessWidget {
  const _LiteCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF161822),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: child,
    );
  }
}

class _ExpandableSynopsis extends StatefulWidget {
  const _ExpandableSynopsis({
    required this.text,
    this.collapsedLines = 2,
  });

  final String text;
  final int collapsedLines;

  @override
  State<_ExpandableSynopsis> createState() => _ExpandableSynopsisState();
}

class _ExpandableSynopsisState extends State<_ExpandableSynopsis> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final text = widget.text.trim();
    if (text.isEmpty) return const SizedBox.shrink();
    const baseStyle = TextStyle(
      color: Colors.white70,
      fontSize: 15,
      height: 1.3,
    );
    final painter = TextPainter(
      text: TextSpan(text: text, style: baseStyle),
      maxLines: widget.collapsedLines,
      textDirection: Directionality.of(context),
    )..layout(maxWidth: MediaQuery.sizeOf(context).width - 64);
    final canExpand = painter.didExceedMaxLines;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Text(
              text,
              maxLines: widget.collapsedLines,
              overflow: TextOverflow.ellipsis,
              style: baseStyle,
            ),
            if (canExpand)
              Positioned(
                left: 0,
                right: 0,
                bottom: 30,
                child: IgnorePointer(
                  ignoring: !_expanded,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    opacity: _expanded ? 1 : 0,
                    child: AnimatedSlide(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      offset: _expanded ? Offset.zero : const Offset(0, 0.08),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                          child: Container(
                            constraints: const BoxConstraints(maxHeight: 180),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.52),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.18),
                              ),
                            ),
                            child: SingleChildScrollView(
                              child: Text(text, style: baseStyle),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        if (canExpand)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Text(
                _expanded ? 'Read Less' : 'Read More',
                style: const TextStyle(
                  color: Color(0xFF93C5FD),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _InlineActionPill extends StatelessWidget {
  const _InlineActionPill({
    required this.icon,
    required this.label,
    required this.onTap,
    this.showProgress = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: disabled
                ? Colors.white.withValues(alpha: 0.05)
                : Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.12),
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showProgress)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(icon, size: 16, color: Colors.white70),
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WideDetailsScaffold extends StatelessWidget {
  const _WideDetailsScaffold({
    required this.media,
    required this.description,
    required this.inAnyList,
    required this.trackingResolved,
    required this.token,
    required this.onPlay,
    required this.onBookmark,
    required this.onManualMatch,
    required this.onDownloadAll,
    required this.onBack,
    required this.onSelectRelation,
    required this.episodeState,
    required this.onRetryEpisodes,
    required this.onPlayEpisode,
    required this.onDownloadEpisode,
    required this.episodeTitleFor,
    required this.episodeThumbFor,
    this.fallbackImage,
  });

  final AniListMedia media;
  final String description;
  final bool inAnyList;
  final bool trackingResolved;
  final String? token;
  final VoidCallback onPlay;
  final VoidCallback onBookmark;
  final VoidCallback onManualMatch;
  final VoidCallback onDownloadAll;
  final VoidCallback onBack;
  final ValueChanged<int> onSelectRelation;
  final ValueNotifier<AsyncValue<EpisodeLoadResult>> episodeState;
  final VoidCallback onRetryEpisodes;
  final ValueChanged<SoraEpisode> onPlayEpisode;
  final ValueChanged<SoraEpisode> onDownloadEpisode;
  final String Function(int episodeNumber) episodeTitleFor;
  final String? Function(int episodeNumber) episodeThumbFor;
  final String? fallbackImage;

  @override
  Widget build(BuildContext context) {
    final image = fallbackImage;
    final relationItems = <(String label, int id)>[
      ('Current Series', media.id),
      ...media.relations.map((r) => (r.relationType, r.media.id)),
    ];
    final unique = <int>{};
    final relations = relationItems.where((e) => unique.add(e.$2)).toList();
    final studio =
        media.studios.isEmpty ? 'Unknown Studio' : media.studios.first;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            child: LayoutBuilder(
              key: ValueKey<int>(media.id),
              builder: (context, constraints) {
                if (image == null || image.isEmpty) {
                  return const ColoredBox(color: Color(0xFF111111));
                }
                final aspect = constraints.maxWidth / constraints.maxHeight;
                final extremeAspect = aspect > 1.95;
                if (!extremeAspect) {
                  return Image(
                    image: KyomiruImageCache.provider(image),
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter,
                  );
                }
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    ImageFiltered(
                      imageFilter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                      child: Transform.scale(
                        scale: 1.12,
                        child: Image(
                          image: KyomiruImageCache.provider(image),
                          fit: BoxFit.cover,
                          alignment: Alignment.topCenter,
                        ),
                      ),
                    ),
                    Image(
                      image: KyomiruImageCache.provider(image),
                      fit: BoxFit.contain,
                      alignment: Alignment.topCenter,
                    ),
                  ],
                );
              },
            ),
          ),
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x11000000),
                  Color(0xC8000000),
                  Color(0xEE090B13),
                ],
                stops: [0.0, 0.62, 1.0],
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 28, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconButton(
                    onPressed: onBack,
                    icon:
                        const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
                  ),
                  const Spacer(flex: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _MetadataGlassPill(
                          text:
                              '${media.episodes ?? '-'} EPS  •  $studio  •  ${media.averageScore ?? 0}%',
                        ),
                        const SizedBox(height: 10),
                        _ExpandableSynopsis(
                          text: description.isEmpty
                              ? 'No description.'
                              : description,
                          collapsedLines: 2,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          media.title.best,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 56,
                            fontWeight: FontWeight.w800,
                            height: 0.95,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: onPlay,
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(0xFF6366F1),
                                  foregroundColor: Colors.white,
                                  minimumSize: const Size(260, 54),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  textStyle: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 17,
                                  ),
                                ),
                                icon: const Icon(Icons.play_arrow_rounded,
                                    size: 24),
                                label: const Text('Play'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            _MiniGlassActionButton(
                              onPressed: onBookmark,
                              tooltip: inAnyList ? 'Bookmarked' : 'Bookmark',
                              icon: Icon(
                                inAnyList
                                    ? Icons.bookmark_rounded
                                    : Icons.bookmark_border_rounded,
                              ),
                            ),
                            const SizedBox(width: 8),
                            _MiniGlassActionButton(
                              onPressed: onManualMatch,
                              tooltip: 'Manual Match',
                              icon: const Icon(Icons.link_rounded, size: 18),
                            ),
                            const SizedBox(width: 8),
                            _MiniGlassActionButton(
                              onPressed: onDownloadAll,
                              tooltip: 'Download All',
                              icon: const Icon(
                                  Icons.download_for_offline_outlined,
                                  size: 18),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (relations.length > 1)
                    SizedBox(
                      height: 42,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: relations.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (context, index) {
                          final item = relations[index];
                          final active = item.$2 == media.id;
                          return Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(999),
                              onTap: () {
                                final rel = media.relations.firstWhere(
                                  (r) => r.media.id == item.$2,
                                  orElse: () => AniListRelation(
                                    relationType: item.$1,
                                    media: AniListMedia(
                                      id: item.$2,
                                      title: AniListTitle(english: 'Unknown'),
                                      cover: AniListCover(),
                                    ),
                                  ),
                                );
                                if ((rel.media.mediaType ?? 'ANIME') ==
                                    'ANIME') {
                                  onSelectRelation(item.$2);
                                  return;
                                }
                                showDialog<void>(
                                  context: context,
                                  builder: (_) => AlertDialog(
                                    title: Text(rel.media.title.best),
                                    content: Text(
                                      '${rel.relationType.replaceAll('_', ' ').toLowerCase()} is not playable in-app.',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(context).pop(),
                                        child: const Text('OK'),
                                      ),
                                    ],
                                  ),
                                );
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(999),
                                  color: active
                                      ? Colors.white.withValues(alpha: 0.22)
                                      : Colors.black.withValues(alpha: 0.22),
                                  border: Border.all(
                                    color: active
                                        ? Colors.white.withValues(alpha: 0.9)
                                        : Colors.white.withValues(alpha: 0.20),
                                    width: active ? 1.0 : 0.5,
                                  ),
                                ),
                                child: Text(
                                  item.$1,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color:
                                        active ? Colors.white : Colors.white70,
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  const SizedBox(height: 10),
                  ValueListenableBuilder<AsyncValue<EpisodeLoadResult>>(
                    valueListenable: episodeState,
                    builder: (context, asyncEpisodes, _) {
                      if (asyncEpisodes.isLoading) {
                        return const SizedBox(
                          height: 138,
                          child: _EpisodeListLoadingSkeleton(),
                        );
                      }
                      if (asyncEpisodes.hasError) {
                        return GlassCard(
                          child: Row(
                            children: [
                              const Expanded(
                                child: Text('Server busy loading episodes.'),
                              ),
                              FilledButton.tonal(
                                onPressed: onRetryEpisodes,
                                child: const Text('Retry'),
                              ),
                            ],
                          ),
                        );
                      }
                      final episodes =
                          asyncEpisodes.valueOrNull?.episodes ?? const [];
                      if (episodes.isEmpty) {
                        return const GlassCard(
                          child: Text('No episodes found for this source.'),
                        );
                      }
                      return SizedBox(
                        height: 146,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: episodes.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(width: 10),
                          itemBuilder: (context, index) {
                            final ep = episodes[index];
                            final episodeName = episodeTitleFor(ep.number)
                                .replaceFirst(
                                  RegExp(
                                    r'^(?:episode|ep)\s*0*' +
                                        RegExp.escape(ep.number.toString()) +
                                        r'\s*[:.\-–—]?\s*',
                                    caseSensitive: false,
                                  ),
                                  '',
                                )
                                .trim();
                            final episodeThumb = episodeThumbFor(ep.number);
                            final fallbackThumb = media.bannerImage;
                            return SizedBox(
                              width: 260,
                              child: GestureDetector(
                                onTap: () => onPlayEpisode(ep),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(14),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color:
                                          Colors.black.withValues(alpha: 0.30),
                                      border: Border.all(
                                        color: Colors.white
                                            .withValues(alpha: 0.16),
                                      ),
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        _EpisodeRowThumb(
                                          mediaId: media.id,
                                          episode: ep.number,
                                          progress: 0,
                                          networkThumbUrl: episodeThumb,
                                          fallbackUrl: fallbackThumb,
                                        ),
                                        const DecoratedBox(
                                          decoration: BoxDecoration(
                                            gradient: LinearGradient(
                                              begin: Alignment.topCenter,
                                              end: Alignment.bottomCenter,
                                              colors: [
                                                Colors.transparent,
                                                Color(0xCC000000),
                                              ],
                                              stops: [0.58, 1],
                                            ),
                                          ),
                                        ),
                                        Positioned(
                                          top: 8,
                                          right: 8,
                                          child: _EpisodeDownloadAction(
                                            mediaId: media.id,
                                            episodeNumber: ep.number,
                                            onDownloadTap: () async =>
                                                onDownloadEpisode(ep),
                                          ),
                                        ),
                                        Positioned(
                                          left: 10,
                                          right: 10,
                                          bottom: 10,
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                episodeName.isEmpty
                                                    ? 'Episode ${ep.number}'
                                                    : episodeName,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 13,
                                                  color: Colors.white,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackingPane extends ConsumerStatefulWidget {
  const _TrackingPane({required this.token, required this.media});

  final String? token;
  final AniListMedia media;
  @override
  ConsumerState<_TrackingPane> createState() => _TrackingPaneState();
}

class _TrackingPaneState extends ConsumerState<_TrackingPane> {
  String _status = 'CURRENT';
  double _score = 0;
  int _progress = 0;
  bool _saving = false;
  bool _loadedInitial = false;
  int? _lastHydratedEntryId;

  @override
  void initState() {
    super.initState();
    unawaited(
      ref
          .read(mediaListEntryControllerProvider(widget.media.id).notifier)
          .loadFresh(),
    );
  }

  void _hydrateInitial(AniListTrackingEntry? entry) {
    if (_loadedInitial || entry == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _loadedInitial) return;
      setState(() {
        _status = entry.status;
        _score = entry.score;
        _progress = entry.progress;
        _loadedInitial = true;
        _lastHydratedEntryId = entry.id;
      });
      ref
          .read(mediaListEntryControllerProvider(widget.media.id).notifier)
          .setLocal(
            status: _status,
            progress: _progress,
            score: _score,
          );
    });
  }

  void _pushOptimistic() {
    ref
        .read(mediaListEntryControllerProvider(widget.media.id).notifier)
        .setLocal(status: _status, progress: _progress, score: _score);
  }

  void _persistLocalImmediate() {
    if (ref.read(librarySourceProvider) != LibrarySource.local) return;
    unawaited(
      ref.read(localLibraryStoreProvider).upsertFromMedia(
            widget.media,
            status: _status,
            progress: _progress,
            score: _score,
          ),
    );
    ref.invalidate(localLibraryEntriesProvider);
    ref.invalidate(mediaListProvider(widget.media.id));
  }

  Widget _scoreEditor(String format) {
    switch (format) {
      case 'POINT_100':
        return Row(
          children: [
            const Text('Score'),
            const SizedBox(width: 8),
            Expanded(
              child: Slider(
                value: _score.clamp(0, 100),
                max: 100,
                divisions: 100,
                label: _score.round().toString(),
                onChanged: (v) => setState(() {
                  _loadedInitial = true;
                  _score = v.roundToDouble();
                  _pushOptimistic();
                  _persistLocalImmediate();
                }),
              ),
            ),
            Text(_score.round().toString()),
          ],
        );
      case 'POINT_5':
        final current = _score.clamp(0, 5).round();
        return Row(
          children: [
            const Text('Score'),
            const SizedBox(width: 8),
            for (var i = 1; i <= 5; i++)
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() {
                  _loadedInitial = true;
                  _score = i.toDouble();
                  _pushOptimistic();
                  _persistLocalImmediate();
                }),
                icon: Icon(
                  i <= current ? Icons.star_rounded : Icons.star_border_rounded,
                  color: i <= current ? Colors.amber : Colors.white70,
                ),
              ),
            const Spacer(),
            Text('$current/5'),
          ],
        );
      case 'POINT_3':
        final current = _score.clamp(0, 3).round();
        const opts = <(IconData icon, String label, int value)>[
          (Icons.sentiment_very_dissatisfied_rounded, 'Bad', 1),
          (Icons.sentiment_neutral_rounded, 'Ok', 2),
          (Icons.sentiment_very_satisfied_rounded, 'Great', 3),
        ];
        return Row(
          children: [
            const Text('Score'),
            const SizedBox(width: 8),
            for (final o in opts)
              TextButton.icon(
                onPressed: () => setState(() {
                  _loadedInitial = true;
                  _score = o.$3.toDouble();
                  _pushOptimistic();
                  _persistLocalImmediate();
                }),
                icon: Icon(
                  o.$1,
                  color: current == o.$3 ? Colors.white : Colors.white54,
                ),
                label: Text(
                  o.$2,
                  style: TextStyle(
                    color: current == o.$3 ? Colors.white : Colors.white54,
                  ),
                ),
              ),
          ],
        );
      case 'POINT_10_DECIMAL':
      default:
        const max = 10.0;
        final div = format == 'POINT_10_DECIMAL' ? 100 : 10;
        return Row(
          children: [
            const Text('Score'),
            const SizedBox(width: 8),
            Expanded(
              child: Slider(
                value: _score.clamp(0, max),
                max: max,
                divisions: div,
                label: format == 'POINT_10_DECIMAL'
                    ? _score.toStringAsFixed(1)
                    : _score.round().toString(),
                onChanged: (v) => setState(() {
                  _loadedInitial = true;
                  _score = format == 'POINT_10_DECIMAL'
                      ? (v * 10).round() / 10
                      : v.roundToDouble();
                  _pushOptimistic();
                  _persistLocalImmediate();
                }),
              ),
            ),
            Text(
              format == 'POINT_10_DECIMAL'
                  ? _score.toStringAsFixed(1)
                  : _score.round().toString(),
            ),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = ref.watch(librarySourceProvider);
    final meAsync = ref.watch(currentUserProvider);
    final scoreFormatAsync = ref.watch(trackingScoreFormatProvider);
    final fetchedEntryAsync = ref.watch(mediaListProvider(widget.media.id));
    final optimisticEntry =
        ref.watch(mediaListEntryControllerProvider(widget.media.id));
    final fetchedEntry = fetchedEntryAsync.valueOrNull;
    _hydrateInitial(fetchedEntry ?? optimisticEntry);

    if (fetchedEntryAsync.hasError &&
        !_loadedInitial &&
        optimisticEntry != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _loadedInitial) return;
        setState(() {
          _status = optimisticEntry.status;
          _score = optimisticEntry.score;
          _progress = optimisticEntry.progress;
          _loadedInitial = true;
          _lastHydratedEntryId = optimisticEntry.id;
        });
      });
    }

    if (!_saving &&
        fetchedEntry != null &&
        _lastHydratedEntryId != fetchedEntry.id &&
        fetchedEntryAsync.hasValue) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _status = fetchedEntry.status;
          _score = fetchedEntry.score;
          _progress = fetchedEntry.progress;
          _loadedInitial = true;
          _lastHydratedEntryId = fetchedEntry.id;
        });
      });
    }

    if (fetchedEntryAsync.isLoading || scoreFormatAsync.isLoading) {
      return const GlassCard(child: Text('Loading tracking...'));
    }

    final bg = meAsync.valueOrNull?.bannerImage ?? widget.media.bannerImage;
    final maxEp = widget.media.episodes ?? 9999;
    final scoreFormat = scoreFormatAsync.valueOrNull ?? 'POINT_10_DECIMAL';

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        children: [
          if (bg != null)
            Positioned.fill(
              child: KyomiruImageCache.image(bg, fit: BoxFit.cover),
            ),
          Positioned.fill(
            child: Container(color: const Color(0xCC0B1020)),
          ),
          GlassCard(
            borderRadius: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  source == LibrarySource.local
                      ? 'Local Library Tracking'
                      : 'AniList Tracking',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 10),
                if (source == LibrarySource.anilist &&
                    fetchedEntry == null &&
                    optimisticEntry == null) ...[
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Not in AniList list yet.',
                          style: TextStyle(color: Color(0xFFA1A8BC)),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () {
                          ref.invalidate(mediaListProvider(widget.media.id));
                          unawaited(ref
                              .read(mediaListEntryControllerProvider(
                                      widget.media.id)
                                  .notifier)
                              .loadFresh());
                        },
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                ],
                Wrap(
                  spacing: 8,
                  children: [
                    for (final s in const [
                      'CURRENT',
                      'PLANNING',
                      'COMPLETED',
                      'PAUSED',
                      'DROPPED',
                      'REPEATING'
                    ])
                      ChoiceChip(
                        label: Text(s),
                        selected: _status == s,
                        onSelected: (_) => setState(() {
                          _loadedInitial = true;
                          _status = s;
                          _pushOptimistic();
                          _persistLocalImmediate();
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Text('Episode'),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Slider(
                        value: _progress.toDouble().clamp(0, maxEp.toDouble()),
                        max: maxEp.toDouble(),
                        divisions: maxEp > 0 ? maxEp : 1,
                        label: '$_progress',
                        onChanged: (v) => setState(() {
                          _loadedInitial = true;
                          _progress = v.round();
                          _pushOptimistic();
                          _persistLocalImmediate();
                        }),
                      ),
                    ),
                    Text('$_progress/$maxEp'),
                  ],
                ),
                _scoreEditor(scoreFormat),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    spacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          setState(() => _saving = true);
                          final removed = await ref
                              .read(mediaListEntryControllerProvider(
                                      widget.media.id)
                                  .notifier)
                              .remove(tokenOverride: widget.token);
                          if (!mounted) return;
                          setState(() => _saving = false);
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                removed
                                    ? 'Removed from list.'
                                    : 'Could not remove from list.',
                              ),
                            ),
                          );
                        },
                        icon: const Icon(Icons.playlist_remove_rounded),
                        label: const Text('Remove from List'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: _saving
                            ? null
                            : () async {
                                if (source == LibrarySource.anilist &&
                                    (widget.token == null ||
                                        widget.token!.isEmpty)) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'AniList token missing. Please reconnect your account.',
                                      ),
                                    ),
                                  );
                                  return;
                                }
                                final messenger = ScaffoldMessenger.of(context);
                                setState(() => _saving = true);
                                final ok = await ref
                                    .read(mediaListEntryControllerProvider(
                                            widget.media.id)
                                        .notifier)
                                    .save(
                                      status: _status,
                                      progress: _progress,
                                      score: _score,
                                      media: widget.media,
                                      tokenOverride: widget.token,
                                    );
                                if (!mounted) return;
                                if (!ok) {
                                  final rollback = ref.read(
                                      mediaListEntryControllerProvider(
                                          widget.media.id));
                                  if (rollback != null) {
                                    setState(() {
                                      _status = rollback.status;
                                      _progress = rollback.progress;
                                      _score = rollback.score;
                                    });
                                  }
                                  messenger.showSnackBar(
                                    const SnackBar(
                                        content: Text('Sync Failed')),
                                  );
                                } else {
                                  messenger.showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        source == LibrarySource.local
                                            ? 'Saved locally.'
                                            : 'Tracking updated.',
                                      ),
                                    ),
                                  );
                                }
                                if (mounted) {
                                  setState(() => _saving = false);
                                }
                              },
                        icon: const Icon(Icons.save_outlined),
                        label: Text(
                          _saving
                              ? 'Saving...'
                              : (source == LibrarySource.local
                                  ? 'Save Local'
                                  : 'Save'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BadlandsHero extends StatelessWidget {
  const _BadlandsHero({
    required this.media,
    required this.inAnyList,
    required this.onPlay,
    required this.onBookmark,
  });

  final AniListMedia media;
  final bool inAnyList;
  final VoidCallback onPlay;
  final VoidCallback onBookmark;

  @override
  Widget build(BuildContext context) {
    final typeLabel = (media.episodes ?? 0) == 1 ? 'Movie' : 'TV';
    final genre = media.genres.isNotEmpty ? media.genres.first : 'Anime';
    final logoCandidate = media.siteUrl?.contains('anilist.co') == true &&
            (media.cover.best?.toLowerCase().endsWith('.png') ?? false)
        ? media.cover.best
        : null;
    final ratingTag = media.isAdult ? 'R' : 'TV-14';
    final score = media.averageScore ?? 78;
    final matchScore = (score + 8).clamp(60, 99);
    final hero = media.bannerImage ?? media.cover.best;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (hero != null && hero.isNotEmpty)
          Hero(
            tag: 'detail-banner-${media.id}',
            child: Image(
              image: KyomiruImageCache.provider(hero),
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
            ),
          )
        else
          const ColoredBox(color: Color(0xFF111111)),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.90),
                  const Color(0xFF090B13),
                ],
                stops: const [0.42, 0.72, 1.0],
              ),
            ),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 22,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (logoCandidate != null)
                SizedBox(
                  height: 52,
                  child: KyomiruImageCache.image(
                    logoCandidate,
                    fit: BoxFit.contain,
                  ),
                )
              else
                Text(
                  media.title.best,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 36,
                    height: 1.05,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                '$typeLabel - $genre',
                style: const TextStyle(
                  fontSize: 14,
                  color: Colors.white70,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _CompactMetaPill(
                    icon: Icons.thumb_up_alt_rounded,
                    label: '$matchScore% Match',
                    color: const Color(0xFF22C55E),
                  ),
                  _CompactMetaPill(
                    icon: Icons.shield_rounded,
                    label: ratingTag,
                    color: const Color(0xFF93C5FD),
                  ),
                  _CompactMetaPill(
                    icon: Icons.star_rounded,
                    label: '${media.averageScore ?? 0}%',
                    color: const Color(0xFFFFD54F),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: onPlay,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF6366F1),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(248, 56),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      icon: const Icon(Icons.play_arrow_rounded, size: 24),
                      label: const Text(
                        'Play',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Material(
                    color: Colors.white.withValues(alpha: 0.12),
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: onBookmark,
                      child: Ink(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.18),
                          ),
                        ),
                        child: Icon(
                          inAnyList
                              ? Icons.bookmark_rounded
                              : Icons.bookmark_border_rounded,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CompactMetaPill extends StatelessWidget {
  const _CompactMetaPill({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetadataGlassPill extends StatelessWidget {
  const _MetadataGlassPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.18),
          width: 0.5,
        ),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _MiniGlassActionButton extends StatelessWidget {
  const _MiniGlassActionButton({
    required this.onPressed,
    required this.icon,
    required this.tooltip,
  });

  final VoidCallback onPressed;
  final Widget icon;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(999),
          child: Ink(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.24),
                width: 0.8,
              ),
            ),
            child: Center(child: icon),
          ),
        ),
      ),
    );
  }
}

class ProgressRing extends StatelessWidget {
  const ProgressRing({super.key, required this.percent, this.size = 56});

  final double percent;
  final double size;
  @override
  Widget build(BuildContext context) {
    final value = percent.clamp(0, 1).toDouble();
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const CircularProgressIndicator(
            value: 1,
            strokeWidth: 5,
            valueColor: AlwaysStoppedAnimation(Color(0x334A556B)),
          ),
          CircularProgressIndicator(
            value: value,
            strokeWidth: 5,
            valueColor: const AlwaysStoppedAnimation(Colors.white),
          ),
          Center(
            child: Text('${(value * 100).round()}%',
                style:
                    const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

class _EpisodeLocalCheck extends ConsumerWidget {
  const _EpisodeLocalCheck({
    required this.mediaId,
    required this.episodeNumber,
  });

  final int mediaId;
  final int episodeNumber;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final item = ref.watch(
      downloadItemProvider(
        LocalEpisodeQuery(mediaId: mediaId, episode: episodeNumber),
      ),
    );
    final isLocal = item?.status == 'done' &&
        ((item?.localFilePath?.isNotEmpty ?? false) ||
            (item?.sourceUrl.isNotEmpty ?? false));
    if (!isLocal) return const SizedBox.shrink();
    return const Padding(
      padding: EdgeInsets.only(left: 6),
      child: Icon(
        CupertinoIcons.check_mark_circled,
        size: 16,
        color: Color(0xFF22C55E),
      ),
    );
  }
}

class _EpisodeDownloadStatusText extends ConsumerWidget {
  const _EpisodeDownloadStatusText({
    required this.mediaId,
    required this.episodeNumber,
  });

  final int mediaId;
  final int episodeNumber;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(
      downloadItemProvider(
        LocalEpisodeQuery(mediaId: mediaId, episode: episodeNumber),
      ),
    );
    if (d == null || d.status == 'done') return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text('${d.status} ${(d.progress * 100).toStringAsFixed(0)}%'),
    );
  }
}

class _EpisodeDownloadAction extends ConsumerWidget {
  const _EpisodeDownloadAction({
    required this.mediaId,
    required this.episodeNumber,
    required this.onDownloadTap,
  });

  final int mediaId;
  final int episodeNumber;
  final Future<void> Function() onDownloadTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(
      downloadItemProvider(
        LocalEpisodeQuery(mediaId: mediaId, episode: episodeNumber),
      ),
    );
    final done = d?.status == 'done';

    if (d?.status == 'downloading') {
      return _SmallGlassIconButton(
        icon: Icons.close,
        onPressed: () => ref
            .read(downloadControllerProvider.notifier)
            .cancel(mediaId, episodeNumber),
      );
    }

    if (done) {
      return _SmallGlassIconButton(
        icon: Icons.check_circle_rounded,
        tooltip: 'Delete Download',
        onPressed: () => ref
            .read(downloadControllerProvider.notifier)
            .delete(mediaId, episodeNumber),
      );
    }

    return _SmallGlassIconButton(
      icon: Icons.download_rounded,
      onPressed: () => unawaited(onDownloadTap()),
    );
  }
}

class _SmallGlassIconButton extends StatelessWidget {
  const _SmallGlassIconButton({
    required this.icon,
    required this.onPressed,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onPressed,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.09),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.20),
                width: 0.5,
              ),
            ),
            child: Icon(
              icon,
              size: 17,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailsLoadingSkeleton extends StatelessWidget {
  const _DetailsLoadingSkeleton();
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Shimmer.fromColors(
          baseColor: const Color(0xFF333333),
          highlightColor: const Color(0xFF555555),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                  height: 220,
                  decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18))),
              const SizedBox(height: 12),
              Container(
                  height: 38,
                  width: 240,
                  decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10))),
              const SizedBox(height: 12),
              for (var i = 0; i < 4; i++) ...[
                Container(
                    height: 84,
                    decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14))),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _EpisodeListLoadingSkeleton extends StatelessWidget {
  const _EpisodeListLoadingSkeleton();
  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: const Color(0xFF333333),
      highlightColor: const Color(0xFF555555),
      child: Column(
        children: List.generate(
          5,
          (index) => Container(
            margin: const EdgeInsets.only(bottom: 8),
            height: 84,
            decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(14)),
          ),
        ),
      ),
    );
  }
}

class _EpisodeRowThumb extends ConsumerWidget {
  const _EpisodeRowThumb({
    required this.mediaId,
    required this.episode,
    required this.progress,
    required this.networkThumbUrl,
    required this.fallbackUrl,
  });

  final int mediaId;
  final int episode;
  final double progress;
  final String? networkThumbUrl;
  final String? fallbackUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localThumb = ref.watch(
      localEpisodeArtworkFileProvider(
        LocalEpisodeArtworkQuery(mediaId: mediaId, episode: episode),
      ),
    );
    final localFile = localThumb.valueOrNull;
    final network = (networkThumbUrl ?? '').trim();
    final fallback = (fallbackUrl ?? '').trim();
    final persistedProgress =
        ref.read(progressStoreProvider).read(mediaId, episode)?.percent ?? 0;
    final effectiveProgress = progress > 0 ? progress : persistedProgress;

    Widget base;
    if (localFile != null) {
      base = Image.file(
        localFile,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _EpisodeFallbackBackdrop(
          fallbackUrl: fallback,
          episode: episode,
        ),
      );
    } else if (network.isNotEmpty) {
      base = KyomiruImageCache.image(
        network,
        fit: BoxFit.cover,
        error: _EpisodeFallbackBackdrop(
          fallbackUrl: fallback,
          episode: episode,
        ),
      );
    } else if (fallback.isNotEmpty) {
      base = _EpisodeFallbackBackdrop(
        fallbackUrl: fallback,
        episode: episode,
      );
    } else {
      base = _EpisodeFallbackBackdrop(
        fallbackUrl: null,
        episode: episode,
      );
    }

    return AspectRatio(
      aspectRatio: 16 / 9,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          fit: StackFit.expand,
          children: [
            base,
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.46),
                    ],
                    stops: const [0.58, 1.0],
                  ),
                ),
              ),
            ),
            if (effectiveProgress > 0)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  height: 2.5,
                  color: Colors.white24,
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: effectiveProgress.clamp(0.0, 1.0),
                    child: Container(
                      color: effectiveProgress >= 1
                          ? const Color(0xFF34D399)
                          : const Color(0xFF60A5FA),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _EpisodeFallbackBackdrop extends StatelessWidget {
  const _EpisodeFallbackBackdrop({
    required this.fallbackUrl,
    required this.episode,
  });

  final String? fallbackUrl;
  final int episode;

  @override
  Widget build(BuildContext context) {
    final bg = (fallbackUrl ?? '').trim();
    return Stack(
      fit: StackFit.expand,
      children: [
        if (bg.isNotEmpty)
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Transform.scale(
              scale: 1.22,
              child: KyomiruImageCache.image(
                bg,
                fit: BoxFit.cover,
                error: const ColoredBox(color: Color(0x22111111)),
              ),
            ),
          )
        else
          const ColoredBox(color: Color(0x22111111)),
        Positioned.fill(
          child: Container(color: Colors.black.withValues(alpha: 0.38)),
        ),
        Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.25),
                    width: 0.7,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.play_arrow_rounded,
                      size: 26,
                      color: Colors.white.withValues(alpha: 0.70),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$episode',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.68),
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                        fontSize: 34,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
