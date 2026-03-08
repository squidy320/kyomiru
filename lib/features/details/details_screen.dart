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
import '../../core/app_logger.dart';
import '../../core/image_cache.dart';
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
  bool _trackingSheetOpen = false;

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
    unawaited(_prefetchTrackingForCurrentMedia());
    setState(() {
      _mediaDetailsFuture = _loadMediaDetails();
    });
    // Re-enable glass only after first content settles to avoid transition stalls.
    unawaited(Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      setState(() => _allowGlass = true);
    }));
  }

  Future<void> _prefetchTrackingForCurrentMedia() async {
    final source = ref.read(librarySourceProvider);
    if (source != LibrarySource.anilist) return;
    final auth = ref.read(authControllerProvider);
    final token = auth.token;
    if (token == null || token.isEmpty) return;
    try {
      await ref
          .read(anilistClientProvider)
          .trackingEntry(token, _currentMediaId, force: true);
      ref.invalidate(mediaListProvider(_currentMediaId));
      AppLogger.i(
        'Details',
        'tracking prefetch refreshed mediaId=$_currentMediaId',
      );
    } catch (e, st) {
      AppLogger.w(
        'Details',
        'tracking prefetch failed mediaId=$_currentMediaId',
        error: e,
        stackTrace: st,
      );
    }
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
    unawaited(_prefetchTrackingForCurrentMedia());
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
          r'\s*[:.\-]?\s*',
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

  Future<List<SoraSource>> _loadSourcesDirect(
    AniListMedia media,
    SoraEpisode ep,
  ) async {
    return ref.read(
      episodeSourcesProvider(
        EpisodeSourceQuery(
          playUrl: ep.playUrl,
          anilistId: media.id,
          episodeNumber: ep.number,
        ),
      ).future,
    );
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

  Widget _rangePickerPill({
    required String label,
    required int value,
    required VoidCallback onDec,
    required VoidCallback onInc,
  }) {
    return Expanded(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0x552A2F46), Color(0x4421283D)],
              ),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.24),
                width: 0.5,
              ),
            ),
            child: Column(
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFBAC2DA),
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _RangeStepButton(icon: Icons.remove_rounded, onTap: onDec),
                    Text(
                      '$value',
                      style: const TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.3,
                      ),
                    ),
                    _RangeStepButton(icon: Icons.add_rounded, onTap: onInc),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<({int start, int end})?> _pickEpisodeRange(
    int minEpisode,
    int maxEpisode,
  ) async {
    var start = minEpisode;
    var end = maxEpisode;
    return showDialog<({int start, int end})>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final mq = MediaQuery.of(context);
          final maxWidth = mq.size.width >= 1024 ? 560.0 : 500.0;
          return Dialog(
            backgroundColor: Colors.transparent,
            insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: maxWidth),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Color(0xD9151826),
                            Color(0xCC0B0E18),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.22),
                          width: 0.5,
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Download Range',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.2,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              _rangePickerPill(
                                label: 'Start Episode',
                                value: start,
                                onDec: () => setDialogState(() {
                                  start = (start - 1).clamp(minEpisode, end);
                                }),
                                onInc: () => setDialogState(() {
                                  start = (start + 1).clamp(minEpisode, end);
                                }),
                              ),
                              const SizedBox(width: 10),
                              _rangePickerPill(
                                label: 'End Episode',
                                value: end,
                                onDec: () => setDialogState(() {
                                  end = (end - 1).clamp(start, maxEpisode);
                                }),
                                onInc: () => setDialogState(() {
                                  end = (end + 1).clamp(start, maxEpisode);
                                }),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              _LiquidActionButton(
                                label: 'Cancel',
                                onTap: () => Navigator.of(context).pop(),
                              ),
                              const SizedBox(width: 10),
                              _LiquidActionButton(
                                label: 'Apply',
                                isPrimary: true,
                                onTap: () {
                                  Navigator.of(context).pop((start: start, end: end));
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
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

    final failures = <int>[];
    try {
      final tasks = selectedEpisodes.map((ep) async {
        final local = await ref
            .read(downloadControllerProvider.notifier)
            .localManifestPath(media.id, ep.number);
        if (local != null) {
          if (!mounted) return;
          setState(() => _bulkDone++);
          return;
        }

        List<SoraSource> sources;
        try {
          sources = await _loadSourcesDirect(media, ep);
        } catch (e, st) {
          AppLogger.w(
            'Details',
            'Source load failed for episode ${ep.number}',
            error: e,
            stackTrace: st,
          );
          failures.add(ep.number);
          if (mounted) setState(() => _bulkDone++);
          return;
        }

        if (sources.isEmpty) {
          failures.add(ep.number);
          if (mounted) setState(() => _bulkDone++);
          return;
        }

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

        unawaited(
          ref
              .read(downloadControllerProvider.notifier)
              .downloadHlsEpisode(
                mediaId: media.id,
                episode: ep.number,
                animeTitle: media.title.best,
                coverImageUrl: media.cover.best,
                episodeThumbnailUrl: _episodeThumbnailUrl(media, ep.number),
                source: selected,
              )
              .catchError((Object e, StackTrace st) {
            AppLogger.w(
              'Details',
              'Bulk download enqueue failed for episode ${ep.number}',
              error: e,
              stackTrace: st,
            );
            failures.add(ep.number);
          }),
        );

        if (!mounted) return;
        setState(() => _bulkDone++);
      }).toList();
      await Future.wait(tasks);
    } finally {
      if (mounted) {
        setState(() => _isBulkDownloading = false);
        if (failures.isNotEmpty) {
          final sample = failures.take(4).join(', ');
          final suffix = failures.length > 4 ? ', ...' : '';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Some episodes failed to queue: $sample$suffix',
              ),
            ),
          );
        }
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
    if (_trackingSheetOpen) return;
    _trackingSheetOpen = true;
    hapticTap();
    AppLogger.i(
      'TrackingUI',
      'open tracking sheet mediaId=${media.id} title="${media.title.best}" tokenPresent=${token != null && token.isNotEmpty}',
    );
    final source = ref.read(librarySourceProvider);
    final target = media.toTrackingTarget();
    if (!mounted) return;
    try {
      await showGeneralDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierLabel: 'Tracking',
        barrierColor: Colors.black.withValues(alpha: 0.46),
        transitionDuration: const Duration(milliseconds: 240),
        pageBuilder: (_, __, ___) => const SizedBox.shrink(),
        transitionBuilder: (context, anim, _, __) {
          final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
          final mq = MediaQuery.of(context);
          final width = mq.size.width;
          final maxWidth = width >= 1024 ? 720.0 : 620.0;
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.96, end: 1).animate(curved),
              child: SafeArea(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: maxWidth,
                        maxHeight: mq.size.height * 0.84,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(24),
                              gradient: const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  Color(0xD9151826),
                                  Color(0xCF0B0E18),
                                ],
                              ),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.22),
                                width: 0.5,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.46),
                                  blurRadius: 32,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                              child: source == LibrarySource.anilist &&
                                      (token == null || token.isEmpty)
                                  ? const Center(
                                      child: Text(
                                        'Connect AniList to manage list, score, and progress.',
                                      ),
                                    )
                                  : SingleChildScrollView(
                                      child: _TrackingPane(
                                        token: token,
                                        media: media,
                                        target: target,
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    } finally {
      _trackingSheetOpen = false;
    }
  }

  Future<void> _handleBookmarkTap(
    AniListMedia media, {
    required bool inAnyList,
    required bool trackingResolved,
    required String? token,
  }) async {
    final source = ref.read(librarySourceProvider);
    if (source == LibrarySource.anilist) {
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

    await _openTrackingSheet(media, token);
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
        final inAnyList = trackingEntryAsync.valueOrNull != null;
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
                        _TrackingPane(
                          token: auth.token,
                          media: media,
                          target: media.toTrackingTarget(),
                        ),
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
            child: Container(
              key: ValueKey<int>(media.id),
              decoration: BoxDecoration(
                image: image == null
                    ? null
                    : DecorationImage(
                        image: KyomiruImageCache.provider(image),
                        fit: BoxFit.cover,
                      ),
              ),
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
                              '${media.episodes ?? '-'} EPS  -  $studio  -  ${media.averageScore ?? 0}%',
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
                                        r'\s*[:.\-]?\s*',
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
  const _TrackingPane({
    required this.token,
    required this.media,
    required this.target,
  });

  final String? token;
  final AniListMedia media;
  final AniListTrackingTarget target;

  @override
  ConsumerState<_TrackingPane> createState() => _TrackingPaneState();
}

class _TrackingPaneState extends ConsumerState<_TrackingPane> {
  @override
  void initState() {
    super.initState();
    unawaited(
      ref
          .read(aniListTrackingProvider(widget.target).notifier)
          .prepare(tokenOverride: widget.token, forceRefresh: true),
    );
  }

  String _lastSyncedLabel(DateTime? at) {
    if (at == null) return 'Last synced: --';
    final h = at.hour.toString().padLeft(2, '0');
    final m = at.minute.toString().padLeft(2, '0');
    final s = at.second.toString().padLeft(2, '0');
    return 'Last synced: $h:$m:$s';
  }

  Future<void> _showLiquidTrackingAlert({
    required String message,
    bool success = true,
  }) async {
    if (!mounted) return;
    final mq = MediaQuery.of(context);
    final wideLandscape =
        mq.size.width >= 900 && mq.orientation == Orientation.landscape;
    final xShift = wideLandscape ? 40.0 : 0.0;
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'Tracking Alert',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 260),
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
      transitionBuilder: (context, anim, _, __) {
        final fade = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return IgnorePointer(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(
                left: 16 + (wideLandscape ? 84 : 0),
                right: 16,
                bottom: 26,
              ),
              child: Transform.translate(
                offset: Offset(xShift, 0),
                child: FadeTransition(
                  opacity: fade,
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.94, end: 1).animate(fade),
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 440),
                      decoration: BoxDecoration(
                        boxShadow: [
                          BoxShadow(
                            color: (success
                                    ? const Color(0xFF22C55E)
                                    : const Color(0xFFF87171))
                                .withValues(alpha: 0.24),
                            blurRadius: 26,
                            spreadRadius: 0.5,
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [Color(0xCC131827), Color(0xB9161A2A)],
                              ),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.24),
                                width: 0.5,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  success
                                      ? Icons.check_circle_rounded
                                      : Icons.error_rounded,
                                  size: 18,
                                  color: success
                                      ? const Color(0xFF22C55E)
                                      : const Color(0xFFF87171),
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    message,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 1450));
    if (mounted) {
      Navigator.of(context, rootNavigator: true).maybePop();
    }
  }

  Widget _liquidSlider({
    required double value,
    required double max,
    required int divisions,
    required String labelText,
    required ValueChanged<double>? onChanged,
  }) {
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: 4,
        activeTrackColor: const Color(0xFF7C82FF),
        inactiveTrackColor: Colors.white.withValues(alpha: 0.15),
        thumbColor: const Color(0xFF8D96FF),
        overlayColor: const Color(0x668D96FF),
        thumbShape: _LiquidGlassThumbShape(labelText: labelText),
      ),
      child: Slider(
        value: value.clamp(0, max),
        max: max,
        divisions: divisions > 0 ? divisions : 1,
        onChanged: onChanged,
      ),
    );
  }

  Widget _scoreEditor({
    required String format,
    required double score,
    required bool enabled,
    required ValueChanged<double> onChanged,
  }) {
    switch (format) {
      case 'POINT_100':
        return Row(
          children: [
            const Text('Score'),
            const SizedBox(width: 8),
            Expanded(
              child: _liquidSlider(
                value: score.clamp(0, 100),
                max: 100,
                divisions: 100,
                labelText: score.round().toString(),
                onChanged: enabled ? (v) => onChanged(v.roundToDouble()) : null,
              ),
            ),
            Text(score.round().toString()),
          ],
        );
      case 'POINT_5':
        final current = score.clamp(0, 5).round();
        return Row(
          children: [
            const Text('Score'),
            const SizedBox(width: 8),
            for (var i = 1; i <= 5; i++)
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: enabled ? () => onChanged(i.toDouble()) : null,
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
        final current = score.clamp(0, 3).round();
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
                onPressed: enabled ? () => onChanged(o.$3.toDouble()) : null,
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
        return Row(
          children: [
            const Text('Score'),
            const SizedBox(width: 8),
            Expanded(
              child: _liquidSlider(
                value: score.clamp(0, 10),
                max: 10,
                divisions: format == 'POINT_10_DECIMAL' ? 100 : 10,
                labelText: format == 'POINT_10_DECIMAL'
                    ? score.toStringAsFixed(1)
                    : score.round().toString(),
                onChanged: enabled
                    ? (v) => onChanged(
                          format == 'POINT_10_DECIMAL'
                              ? (v * 10).round() / 10
                              : v.roundToDouble(),
                        )
                    : null,
              ),
            ),
            Text(
              format == 'POINT_10_DECIMAL'
                  ? score.toStringAsFixed(1)
                  : score.round().toString(),
            ),
          ],
        );
    }
  }

  String _effectiveScoreFormat({
    required String? reportedFormat,
    required double scoreValue,
  }) {
    final f = (reportedFormat ?? '').trim().toUpperCase();
    if (f.isNotEmpty) return f;
    // Fallback when Viewer.scoreFormat is temporarily unavailable.
    if (scoreValue > 10) return 'POINT_100';
    return 'POINT_10_DECIMAL';
  }

  @override
  Widget build(BuildContext context) {
    final source = ref.watch(librarySourceProvider);
    final meAsync = ref.watch(currentUserProvider);
    final scoreFormatAsync = ref.watch(trackingScoreFormatProvider);
    final sync = ref.watch(aniListTrackingProvider(widget.target));
    final notifier = ref.read(aniListTrackingProvider(widget.target).notifier);
    final scoreFormat = _effectiveScoreFormat(
      reportedFormat: scoreFormatAsync.valueOrNull,
      scoreValue: sync.scoreDraft,
    );
    final isLocked = sync.isFetching || sync.isResolvingId;
    final isSyncing = sync.isSaving || sync.isRemoving;
    final bg = meAsync.valueOrNull?.bannerImage ?? widget.media.bannerImage;
    final maxEp = sync.maxEpisodes > 0 ? sync.maxEpisodes : 9999;

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        children: [
          if (bg != null)
            Positioned.fill(
              child: KyomiruImageCache.image(bg, fit: BoxFit.cover),
            ),
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
              child: Container(color: const Color(0xB3161A2A)),
            ),
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
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                if (isLocked)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Shimmer.fromColors(
                      baseColor: Colors.white.withValues(alpha: 0.16),
                      highlightColor: Colors.white.withValues(alpha: 0.34),
                      child: Column(
                        children: [
                          Container(
                            height: 34,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Container(
                            height: 36,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Container(
                            height: 36,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          const SizedBox(height: 10),
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Fetching Data...',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  AbsorbPointer(
                    absorbing: isSyncing,
                    child: Opacity(
                      opacity: isSyncing ? 0.60 : 1,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
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
                                  selected: sync.statusDraft == s,
                                  selectedColor: Colors.white,
                                  backgroundColor:
                                      Colors.white.withValues(alpha: 0.08),
                                  side: BorderSide(
                                    color: Colors.white.withValues(alpha: 0.24),
                                    width: 0.5,
                                  ),
                                  labelStyle: TextStyle(
                                    color: sync.statusDraft == s
                                        ? const Color(0xFF121727)
                                        : Colors.white,
                                    fontWeight: FontWeight.w800,
                                  ),
                                  onSelected: (_) {
                                    unawaited(notifier.requestStatus(s));
                                  },
                                ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              const Text('Episode'),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _liquidSlider(
                                  value: sync.progressDraft.toDouble(),
                                  max: maxEp.toDouble(),
                                  divisions: maxEp,
                                  labelText: sync.progressDraft.toString(),
                                  onChanged: (v) {
                                    unawaited(notifier.requestProgress(v.round()));
                                  },
                                ),
                              ),
                              Text('${sync.progressDraft}/$maxEp'),
                            ],
                          ),
                          _scoreEditor(
                            format: scoreFormat,
                            score: sync.scoreDraft,
                            enabled: !isSyncing,
                            onChanged: (v) {
                              unawaited(notifier.requestScore(v));
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                if (sync.errorMessage != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    sync.errorMessage!,
                    style: const TextStyle(
                      color: Color(0xFFFF9E9E),
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    spacing: 8,
                    children: [
                      _LiquidActionButton(
                        label: 'Remove from List',
                        icon: Icons.playlist_remove_rounded,
                        onPressed: isLocked || isSyncing
                            ? null
                            : () async {
                                final removed =
                                    await notifier.remove(tokenOverride: widget.token);
                                if (!context.mounted) return;
                                unawaited(
                                  _showLiquidTrackingAlert(
                                    message: removed
                                        ? 'Removed from list'
                                        : 'Could not remove from list',
                                    success: removed,
                                  ),
                                );
                              },
                      ),
                      _LiquidActionButton(
                        label: isSyncing ? 'Syncing...' : 'Save',
                        icon: Icons.save_outlined,
                        isPrimary: true,
                        onPressed: isLocked || isSyncing
                            ? null
                            : () async {
                                final ok =
                                    await notifier.commit(tokenOverride: widget.token);
                                if (!context.mounted) return;
                                unawaited(
                                  _showLiquidTrackingAlert(
                                    message: ok
                                        ? (source == LibrarySource.local
                                            ? 'Saved locally'
                                            : 'Tracking updated')
                                        : 'Sync Failed',
                                    success: ok,
                                  ),
                                );
                              },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (isSyncing) ...[
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        'Syncing AniList...',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFFA1A8BC),
                        ),
                      ),
                    ],
                    const Spacer(),
                    Text(
                      _lastSyncedLabel(sync.lastSyncedAt),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFA1A8BC),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LiquidActionButton extends StatelessWidget {
  const _LiquidActionButton({
    required this.label,
    this.icon,
    this.onPressed,
    this.onTap,
    this.isPrimary = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final VoidCallback? onTap;
  final bool isPrimary;

  @override
  Widget build(BuildContext context) {
    final action = onPressed ?? onTap;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: action,
            child: Ink(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: isPrimary
                      ? const [Color(0xC65F63FF), Color(0xB04D52E8)]
                      : const [Color(0x5A2A2F46), Color(0x4521283D)],
                ),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.24),
                  width: 0.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 18, color: Colors.white),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    label,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RangeStepButton extends StatelessWidget {
  const _RangeStepButton({
    required this.icon,
    required this.onTap,
  });

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: onTap,
            child: Ink(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.24),
                  width: 0.5,
                ),
              ),
              child: Icon(icon, size: 16, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

class _LiquidGlassThumbShape extends SliderComponentShape {
  const _LiquidGlassThumbShape({required this.labelText});

  final String labelText;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size(44, 28);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: center, width: 44, height: 28),
      const Radius.circular(999),
    );
    final fill = Paint()..color = const Color(0xCC9AA4FF);
    final border = Paint()
      ..color = Colors.white.withValues(alpha: 0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRRect(rect, fill);
    canvas.drawRRect(rect, border);

    final tp = TextPainter(
      text: TextSpan(
        text: labelText,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: textDirection,
    )..layout(minWidth: 0, maxWidth: 44);
    tp.paint(canvas, Offset(center.dx - tp.width / 2, center.dy - tp.height / 2));
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

