import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shimmer/shimmer.dart';

import '../../core/glass_widgets.dart';
import '../../core/haptics.dart';
import '../../core/image_cache.dart';
import '../../core/liquid_glass_preset.dart';
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

class DetailsScreen extends ConsumerStatefulWidget {
  const DetailsScreen({super.key, required this.mediaId});

  final int mediaId;
  @override
  ConsumerState<DetailsScreen> createState() => _DetailsScreenState();
}

class _DetailsScreenState extends ConsumerState<DetailsScreen> {
  int _tab = 0;
  SoraAnimeMatch? _manualMatch;
  int? _prefetchedForMediaId;
  bool _isBulkDownloading = false;
  int _bulkDone = 0;
  int _bulkTotal = 0;

  SoraRuntime get _sora => ref.read(soraRuntimeProvider);

  void _refreshPahe(AniListMedia media, {SoraAnimeMatch? manual}) {
    setState(() {
      _manualMatch = manual ?? _manualMatch;
      if (_manualMatch != null) {
        _persistManualMatch(media.id, _manualMatch!);
      }
    });
    ref.invalidate(episodeProvider);
  }

  @override
  void initState() {
    super.initState();
    ref.invalidate(episodeProvider);
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
      unawaited(_sora
          .getSourcesForEpisode(
            ep.playUrl,
            anilistId: media.id,
            episodeNumber: ep.number,
          )
          .catchError((_, __) => const <SoraSource>[]));
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
      return await ref.read(provider.future);
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
    final range =
        await _pickEpisodeRange(episodes.first.number, episodes.last.number);
    if (!mounted || range == null) return;
    final selectedEpisodes = episodes
        .where((ep) => ep.number >= range.start && ep.number <= range.end)
        .toList();
    if (selectedEpisodes.isEmpty) return;

    final probeSources =
        await _loadSourcesWithOverlay(media, selectedEpisodes.first);
    if (!mounted || probeSources.isEmpty) return;
    final chosen = await _showSourcePicker(probeSources);
    if (!mounted || chosen == null) return;
    _lockSessionSource(chosen);

    setState(() {
      _isBulkDownloading = true;
      _bulkDone = 0;
      _bulkTotal = selectedEpisodes.length;
    });

    final settings = ref.read(appSettingsProvider);
    try {
      for (final ep in selectedEpisodes) {
        final local = await ref
            .read(downloadControllerProvider.notifier)
            .localManifestPath(media.id, ep.number);
        if (local == null) {
          final sources = await _loadSourcesWithOverlay(media, ep);
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

    final sources = await _loadSourcesWithOverlay(media, ep);
    if (sources.isEmpty) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('No sources found for episode.')),
      );
      return;
    }
    final settings = ref.read(appSettingsProvider);
    final selected = settings.chooseStreamEveryTime
        ? await _showSourcePicker(sources)
        : _pickSourceByPreference(sources, settings);
    if (selected == null || !context.mounted) return;
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
  }

  Future<void> _playSmartEpisode(
    AniListMedia media,
    EpisodeQuery episodeQuery,
    ProgressStore progressStore,
  ) async {
    try {
      final result = await ref.read(episodeProvider(episodeQuery).future);
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

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(anilistClientProvider);
    final progressStore = ref.watch(progressStoreProvider);
    final auth = ref.watch(authControllerProvider);
    final uiSettings = ref.watch(appSettingsProvider);

    return FutureBuilder<AniListMedia>(
      future: client.mediaDetails(widget.mediaId),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Scaffold(body: _DetailsLoadingSkeleton());
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
            body: Center(child: Text('Failed to load details: ${snap.error}')),
          );
        }

        final media = snap.data!;
        _manualMatch ??= _readSavedMatch(media.id);
        final episodeQuery = EpisodeQuery(
          mediaId: media.id,
          title: media.title.best,
          manualMatch: _manualMatch,
        );
        final description = (media.description ?? '')
            .replaceAll(RegExp(r'<[^>]*>'), ' ')
            .trim();

        return Scaffold(
          body: NestedScrollView(
            headerSliverBuilder: (context, innerBoxIsScrolled) => [
              SliverAppBar(
                expandedHeight: 360,
                pinned: true,
                stretch: true,
                backgroundColor: Colors.black,
                leading: IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
                ),
                flexibleSpace: FlexibleSpaceBar(
                  collapseMode: CollapseMode.parallax,
                  background: _BadlandsHero(
                    media: media,
                    onPlay: () =>
                        _playSmartEpisode(media, episodeQuery, progressStore),
                    onBookmark: () => _openTrackingSheet(media, auth.token),
                  ),
                ),
              ),
            ],
            body: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _TabPill(
                        label: 'Watch',
                        selected: _tab == 0,
                        onTap: () => setState(() => _tab = 0)),
                    FilledButton.tonalIcon(
                      onPressed: () => _openTrackingSheet(media, auth.token),
                      icon: const Icon(Icons.edit_document),
                      label: const Text('Manage List'),
                    ),
                    _TabPill(
                        label: 'AniList',
                        selected: _tab == 1,
                        onTap: () => setState(() => _tab = 1)),
                    _TabPill(
                        label: 'More',
                        selected: _tab == 2,
                        onTap: () => setState(() => _tab = 2)),
                  ],
                ),
                const SizedBox(height: 12),
                if (_tab == 0)
                  FutureBuilder<EpisodeLoadResult>(
                    future: ref.watch(episodeProvider(episodeQuery).future),
                    builder: (context, paheSnap) {
                      if (paheSnap.connectionState == ConnectionState.waiting) {
                        return const _EpisodeListLoadingSkeleton();
                      }

                      final data = paheSnap.data;
                      if (data == null ||
                          data.match == null ||
                          data.episodes.isEmpty) {
                        return GlassCard(
                          child: Row(
                            children: [
                              const Expanded(
                                  child: Text(
                                      'Could not load AnimePahe episodes for this title.')),
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
                      _prefetchPlaybackData(media, episodes);
                      return Column(
                        children: [
                          GlassCard(
                            child: Row(
                              children: [
                                const Icon(Icons.link),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text('AnimePahe',
                                          style: TextStyle(
                                              fontWeight: FontWeight.w800)),
                                      Text(
                                        _manualMatch == null
                                            ? 'Using automatic matching'
                                            : 'Using manual matching',
                                        style: const TextStyle(
                                            fontSize: 12,
                                            color: Color(0xFF9AA0B3)),
                                      ),
                                      Text(
                                        data.match!.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                                FilledButton.tonal(
                                  onPressed: () async {
                                    final manual =
                                        await _openManualMatchPicker(media);
                                    if (manual != null) {
                                      _refreshPahe(media, manual: manual);
                                    }
                                  },
                                  child: const Text('Manual'),
                                ),
                                IconButton(
                                  onPressed: () => _refreshPahe(media),
                                  icon: const Icon(Icons.refresh),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: Container(
                                  padding:
                                      const EdgeInsets.fromLTRB(14, 10, 10, 10),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(16),
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.white.withValues(alpha: 0.04),
                                        Colors.black.withValues(alpha: 0.20),
                                      ],
                                    ),
                                    border: Border.all(
                                      color:
                                          Colors.white.withValues(alpha: 0.08),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      const Text(
                                        'Episodes',
                                        style: TextStyle(
                                          fontSize: 28,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      const Spacer(),
                                      if (_isBulkDownloading)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 8,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.white
                                                .withValues(alpha: 0.08),
                                            borderRadius:
                                                BorderRadius.circular(999),
                                            border: Border.all(
                                              color: Colors.white
                                                  .withValues(alpha: 0.12),
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const SizedBox(
                                                width: 16,
                                                height: 16,
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Text(
                                                  'Downloading $_bulkDone/$_bulkTotal'),
                                            ],
                                          ),
                                        )
                                      else
                                        GlassButton(
                                          onPressed: () => _downloadAllEpisodes(
                                              media, episodes),
                                          child: const Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons
                                                  .download_for_offline_outlined),
                                              SizedBox(width: 6),
                                              Text('Download All'),
                                            ],
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          ...episodes.map((ep) {
                            final p = progressStore.read(media.id, ep.number);
                            final pct = p?.percent ?? 0;
                            final thumb =
                                _episodeThumbnailUrl(media, ep.number);
                            final fallbackThumb =
                                media.cover.best ?? media.bannerImage;
                            final episodeSubtitle =
                                _episodeSpecificTitle(media, ep.number);

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: LiquidGlass.withOwnLayer(
                                settings: kyomiruLiquidGlassSettings(
                                  isOledBlack: uiSettings.isOledBlack,
                                ),
                                shape: const LiquidRoundedSuperellipse(
                                    borderRadius: 14),
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => _playEpisode(media, ep),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: uiSettings.isOledBlack
                                          ? Colors.black.withValues(alpha: 0.18)
                                          : Colors.white
                                              .withValues(alpha: 0.03),
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(
                                        color: Colors.white
                                            .withValues(alpha: 0.10),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        SizedBox(
                                          width: 104,
                                          height: 64,
                                          child: _EpisodeRowThumb(
                                            mediaId: media.id,
                                            episode: ep.number,
                                            networkThumbUrl: thumb,
                                            fallbackUrl: fallbackThumb,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text('EP ${ep.number}',
                                                  style: const TextStyle(
                                                      color: Color(0xFF8B5CF6),
                                                      fontWeight:
                                                          FontWeight.w700)),
                                              const SizedBox(height: 2),
                                              Row(
                                                children: [
                                                  Expanded(
                                                    child: Text(
                                                      episodeSubtitle,
                                                      maxLines: 2,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                          fontSize: 15,
                                                          fontWeight:
                                                              FontWeight.w700),
                                                    ),
                                                  ),
                                                  _EpisodeLocalCheck(
                                                    mediaId: media.id,
                                                    episodeNumber: ep.number,
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
                                        const SizedBox(width: 8),
                                        ProgressRing(percent: pct, size: 52),
                                        const SizedBox(width: 8),
                                        _EpisodeDownloadAction(
                                          mediaId: media.id,
                                          episodeNumber: ep.number,
                                          onDownloadTap: () async {
                                            final sources =
                                                await _loadSourcesWithOverlay(
                                              media,
                                              ep,
                                            );
                                            if (sources.isEmpty) return;
                                            final settings =
                                                ref.read(appSettingsProvider);
                                            final selected =
                                                settings.chooseStreamEveryTime
                                                    ? await _showSourcePicker(
                                                        sources)
                                                    : _pickDownloadSource(
                                                        sources,
                                                        settings,
                                                      );
                                            if (selected == null) return;
                                            _lockSessionSource(selected);
                                            await ref
                                                .read(downloadControllerProvider
                                                    .notifier)
                                                .downloadHlsEpisode(
                                                  mediaId: media.id,
                                                  episode: ep.number,
                                                  animeTitle: media.title.best,
                                                  coverImageUrl:
                                                      media.cover.best,
                                                  episodeThumbnailUrl:
                                                      _episodeThumbnailUrl(
                                                    media,
                                                    ep.number,
                                                  ),
                                                  source: selected,
                                                );
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }),
                        ],
                      );
                    },
                  ),
                if (_tab == 1)
                  Column(
                    children: [
                      GlassCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(media.title.best,
                                style: const TextStyle(
                                    fontSize: 22, fontWeight: FontWeight.w800)),
                            const SizedBox(height: 8),
                            Text(description.isEmpty
                                ? 'No description.'
                                : description),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      GlassCard(
                        child: Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Use Manage List to update status, progress, and score.',
                              ),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.tonalIcon(
                              onPressed: () =>
                                  _openTrackingSheet(media, auth.token),
                              icon: const Icon(Icons.edit_document),
                              label: const Text('Manage List'),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                if (_tab == 2)
                  Column(
                    children: [
                      GlassCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Status: ${media.status ?? 'N/A'}'),
                            Text('Score: ${media.averageScore ?? 'N/A'}'),
                            Text('Episodes: ${media.episodes ?? 'N/A'}'),
                            const SizedBox(height: 8),
                            FilledButton.tonalIcon(
                              onPressed: media.siteUrl == null
                                  ? null
                                  : () => Share.share(media.siteUrl!,
                                      subject: media.title.best),
                              icon: const Icon(Icons.share),
                              label: const Text('Share AniList'),
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
                              ...media.relations.map(
                                (rel) => ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(
                                    rel.media.title.best,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    rel.relationType
                                        .replaceAll('_', ' ')
                                        .toLowerCase(),
                                  ),
                                  trailing:
                                      const Icon(Icons.chevron_right_rounded),
                                  onTap: () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          DetailsScreen(mediaId: rel.media.id),
                                    ),
                                  ),
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
        );
      },
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
    final entry = optimisticEntry ?? fetchedEntryAsync.valueOrNull;
    _hydrateInitial(entry);

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
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton.icon(
                        onPressed: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          final removed = await ref
                              .read(downloadControllerProvider.notifier)
                              .removeDownloadsForMedia(widget.media.id);
                          if (!mounted) return;
                          messenger.showSnackBar(
                            SnackBar(
                              content: Text(
                                removed > 0
                                    ? 'Removed $removed downloaded episode(s).'
                                    : 'No local downloads to remove.',
                              ),
                            ),
                          );
                        },
                        icon: const Icon(Icons.delete_outline_rounded),
                        label: const Text('Remove Download'),
                      ),
                      const SizedBox(width: 8),
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
    required this.onPlay,
    required this.onBookmark,
  });

  final AniListMedia media;
  final VoidCallback onPlay;
  final VoidCallback onBookmark;

  @override
  Widget build(BuildContext context) {
    final typeLabel = (media.episodes ?? 0) == 1 ? 'Movie' : 'TV';
    final genre = media.genres.isNotEmpty ? media.genres.first : 'Anime';
    final hero = media.bannerImage ?? media.cover.best;

    return Stack(
      fit: StackFit.expand,
      children: [
        if (hero != null && hero.isNotEmpty)
          KyomiruImageCache.image(hero, fit: BoxFit.cover)
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
                  Colors.black.withValues(alpha: 0.55),
                  const Color(0xFF090B13),
                ],
                stops: const [0.45, 0.78, 1.0],
              ),
            ),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 18,
          child: Container(
            height: 120,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: 0.05),
                  Colors.black.withValues(alpha: 0.24),
                ],
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.10),
              ),
            ),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 24,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                media.title.best,
                maxLines: 2,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 34,
                  height: 1.05,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '$typeLabel • $genre',
                style: const TextStyle(
                  fontSize: 14,
                  color: Colors.white70,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    onPressed: onPlay,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black,
                      minimumSize: const Size(210, 54),
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
                        child: const Icon(Icons.bookmark_border_rounded),
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

class _TabPill extends StatelessWidget {
  const _TabPill(
      {required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        hapticTap();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF8B5CF6) : const Color(0x66141B2E),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0x33FFFFFF)),
        ),
        child: Text(label,
            style: TextStyle(
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : null)),
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
      return IconButton.filledTonal(
        style: IconButton.styleFrom(
          minimumSize: const Size(30, 30),
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
        ),
        onPressed: () => ref
            .read(downloadControllerProvider.notifier)
            .cancel(mediaId, episodeNumber),
        icon: const Icon(Icons.close),
      );
    }

    if (done) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton.filledTonal(
            tooltip: 'Delete Download',
            style: IconButton.styleFrom(
              minimumSize: const Size(30, 30),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            ),
            onPressed: () => ref
                .read(downloadControllerProvider.notifier)
                .delete(mediaId, episodeNumber),
            icon: const Icon(Icons.check_circle_rounded),
          ),
          const Text(
            'Downloaded',
            style: TextStyle(
              fontSize: 9,
              color: Color(0xFF86EFAC),
            ),
          ),
        ],
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        unawaited(onDownloadTap());
      },
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.12),
          ),
        ),
        child: const Icon(
          Icons.download_outlined,
          size: 29,
          color: Colors.white,
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
    required this.networkThumbUrl,
    required this.fallbackUrl,
  });

  final int mediaId;
  final int episode;
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

    Widget base;
    if (localFile != null) {
      base = Image.file(
        localFile,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => fallback.isNotEmpty
            ? KyomiruImageCache.image(
                fallback,
                fit: BoxFit.cover,
                error: const ColoredBox(color: Color(0x22111111)),
              )
            : const ColoredBox(color: Color(0x22111111)),
      );
    } else if (network.isNotEmpty) {
      base = KyomiruImageCache.image(
        network,
        fit: BoxFit.cover,
        error: fallback.isNotEmpty
            ? KyomiruImageCache.image(
                fallback,
                fit: BoxFit.cover,
                error: const ColoredBox(color: Color(0x22111111)),
              )
            : const ColoredBox(color: Color(0x22111111)),
      );
    } else if (fallback.isNotEmpty) {
      base = KyomiruImageCache.image(
        fallback,
        fit: BoxFit.cover,
        error: const ColoredBox(color: Color(0x22111111)),
      );
    } else {
      base = const ColoredBox(color: Color(0x22111111));
    }

    return ClipRRect(
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
        ],
      ),
    );
  }
}
