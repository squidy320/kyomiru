import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:shimmer/shimmer.dart';

import '../../core/glass_widgets.dart';
import '../../core/haptics.dart';
import '../../core/image_cache.dart';
import '../../core/liquid_glass_preset.dart';
import '../../features/auth/anilist_login_webview_screen.dart';
import '../../features/details/details_screen.dart';
import '../../features/discovery/discovery_screen.dart';
import '../../features/player/player_screen.dart';
import '../../models/anilist_models.dart';
import '../../services/download_manager.dart';
import '../../services/local_library_store.dart';
import '../../services/watch_history_store.dart';
import '../../state/app_settings_state.dart';
import '../../state/auth_state.dart';
import '../../state/library_source_state.dart';
import '../../state/tracking_state.dart';
import '../../state/ui_ambient_state.dart';
import '../../state/watch_history_state.dart';

const double _kCardWidth = 152;
const double _kCardHeight = 232;

Route<void> _detailsRoute(int mediaId) {
  return PageRouteBuilder<void>(
    pageBuilder: (_, __, ___) => DetailsScreen(mediaId: mediaId),
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
  );
}

class _ContinueWatchingNotifierMeta {
  const _ContinueWatchingNotifierMeta({
    required this.unseen,
    required this.totalAvailable,
    required this.status,
  });

  final int unseen;
  final int totalAvailable;
  final String status;
}

final continueWatchingNotifierProvider = FutureProvider.family<
    _ContinueWatchingNotifierMeta,
    ({int mediaId, int lastCompleted})>((ref, query) async {
  final auth = ref.watch(authControllerProvider);
  final token = auth.token;
  if (token == null || token.isEmpty) {
    return const _ContinueWatchingNotifierMeta(
      unseen: 0,
      totalAvailable: 0,
      status: '',
    );
  }
  final info = await ref
      .watch(anilistClientProvider)
      .episodeAvailability(token, query.mediaId);
  if (info == null) {
    return const _ContinueWatchingNotifierMeta(
      unseen: 0,
      totalAvailable: 0,
      status: '',
    );
  }
  final latestReleased = info.latestReleasedEpisode;
  final unseen = info.status == 'RELEASING'
      ? (latestReleased - query.lastCompleted).clamp(0, 9999)
      : 0;
  return _ContinueWatchingNotifierMeta(
    unseen: unseen,
    totalAvailable: info.availableEpisodes,
    status: info.status,
  );
});

final continueWatchingArtworkFallbackProvider =
    FutureProvider.family<String?, int>((ref, mediaId) async {
  try {
    final media = await ref.watch(anilistClientProvider).mediaDetails(mediaId);
    return media.cover.best ?? media.bannerImage;
  } catch (_) {
    return null;
  }
});

final libraryWatchingNotifierProvider = FutureProvider.family<
    _ContinueWatchingNotifierMeta,
    ({int mediaId, int progress})>((ref, query) async {
  final auth = ref.watch(authControllerProvider);
  final token = auth.token;
  if (token == null || token.isEmpty) {
    return const _ContinueWatchingNotifierMeta(
      unseen: 0,
      totalAvailable: 0,
      status: '',
    );
  }
  final info = await ref
      .watch(anilistClientProvider)
      .episodeAvailability(token, query.mediaId);
  if (info == null) {
    return const _ContinueWatchingNotifierMeta(
      unseen: 0,
      totalAvailable: 0,
      status: '',
    );
  }
  final latestReleased = info.latestReleasedEpisode;
  final unseen = info.status == 'RELEASING'
      ? (latestReleased - query.progress).clamp(0, 9999)
      : 0;
  return _ContinueWatchingNotifierMeta(
    unseen: unseen,
    totalAvailable: info.availableEpisodes,
    status: info.status,
  );
});

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen>
    with AutomaticKeepAliveClientMixin {
  String _selected = 'All';
  int _refreshTick = 0;
  bool _isVerifyingTracking = false;
  bool _launchTrackingSyncStarted = false;

  Future<void> _refresh() async {
    await _runTrackingVerificationSync();
    if (!mounted) return;
    setState(() => _refreshTick++);
  }

  Future<void> _runTrackingVerificationSync() async {
    if (_isVerifyingTracking) return;
    final source = ref.read(librarySourceProvider);
    final auth = ref.read(authControllerProvider);
    final token = auth.token;
    if (source != LibrarySource.anilist || token == null || token.isEmpty) {
      return;
    }
    setState(() => _isVerifyingTracking = true);
    try {
      final client = ref.read(anilistClientProvider);
      final user = await client.me(token, force: true);
      await Future.wait<void>([
        client.librarySections(token, userId: user.id, force: true).then((_) {}),
        client.libraryCurrent(token, userId: user.id, force: true).then((_) {}),
      ]);
      ref.read(librarySyncBumpProvider.notifier).state++;
    } finally {
      if (mounted) {
        setState(() => _isVerifyingTracking = false);
      }
    }
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final source = ref.watch(librarySourceProvider);
    final auth = ref.watch(authControllerProvider);

    if (source == LibrarySource.local) {
      return _LocalLibraryView(
        selected: _selected,
        onSelect: (value) {
          hapticTap();
          setState(() => _selected = value);
        },
      );
    }

    if (auth.loading) {
      return const _LibrarySkeleton();
    }

    if (auth.token == null || auth.token!.isEmpty) {
      return SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 120),
          children: [
            Text('Library', style: Theme.of(context).textTheme.displaySmall),
            const Text('All your AniList collections',
                style: TextStyle(color: Color(0xFFA1A8BC))),
            const SizedBox(height: 12),
            const GlassCard(
              child: Text(
                  'No account connected. Sign in with AniList to sync lists and tracking.'),
            ),
            const SizedBox(height: 12),
            GlassButton(
              onPressed: () {
                hapticTap();
                Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const AniListLoginWebViewScreen()),
                );
              },
              child: const Text('Connect AniList',
                  style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      );
    }

    if (!_launchTrackingSyncStarted) {
      _launchTrackingSyncStarted = true;
      unawaited(_runTrackingVerificationSync());
    }

    return _LibraryDataView(
      key: ValueKey('$_selected-$_refreshTick'),
      token: auth.token!,
      selected: _selected,
      verifyingTracking: _isVerifyingTracking,
      onSelect: (value) {
        hapticTap();
        setState(() => _selected = value);
      },
      onRefresh: _refresh,
    );
  }
}

class _LibraryDataView extends ConsumerWidget {
  const _LibraryDataView({
    super.key,
    required this.token,
    required this.selected,
    required this.verifyingTracking,
    required this.onSelect,
    required this.onRefresh,
  });

  final String token;
  final String selected;
  final bool verifyingTracking;
  final ValueChanged<String> onSelect;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(anilistClientProvider);
    final settings = ref.watch(appSettingsProvider);
    ref.watch(librarySyncBumpProvider);
    final cachedSections = client.cachedLibrarySections(token);

    return FutureBuilder<List<dynamic>>(
      future: client.me(token).then((u) async => [
            u,
            await client.librarySections(token, userId: u.id),
          ]),
      builder: (context, snap) {
        final loading = snap.connectionState == ConnectionState.waiting;
        final hasError = snap.hasError;
        final user =
            !loading && !hasError ? snap.data![0] as AniListUser : null;
        final sections = !loading && !hasError
            ? snap.data![1] as List<AniListLibrarySection>
            : cachedSections;
        final showingCached = loading && cachedSections.isNotEmpty;

        final chips = <String>['All', ...sections.map((s) => s.title)];
        final filtered = selected == 'All'
            ? sections
            : sections.where((s) => s.title == selected).toList();
        final watching = sections
            .where((s) =>
                s.title.toLowerCase().contains('watch') ||
                s.title.toLowerCase().contains('current'))
            .expand((s) => s.items)
            .toList();
        final planning = sections
            .where((s) => s.title.toLowerCase().contains('plan'))
            .expand((s) => s.items)
            .toList();
        final heroItems = (watching.isNotEmpty ? watching : planning)
            .map((e) => e.media)
            .toList();

        return RefreshIndicator(
          onRefresh: onRefresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 120),
            children: [
              _LibraryAnimatedHero(
                items: heroItems,
                title: 'Library',
                subtitle: 'Currently watching and synced lists',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Library',
                            style: Theme.of(context).textTheme.displaySmall),
                        const Text('All your AniList collections',
                            style: TextStyle(color: Color(0xFFA1A8BC))),
                      ],
                    ),
                  ),
                  if (user?.avatar != null)
                    CircleAvatar(
                        radius: 18,
                        backgroundImage:
                            KyomiruImageCache.provider(user!.avatar!)),
                ],
              ),
              const SizedBox(height: 12),
              GlassContainer(
                borderRadius: 14,
                child: SizedBox(
                  height: 38,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: chips.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final chip = chips[index];
                      final active = selected == chip;
                      return _LibraryFilterChip(
                        label: chip,
                        active: active,
                        isOledBlack: settings.isOledBlack,
                        onTap: () => onSelect(chip),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (showingCached)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Showing cached library',
                    style: TextStyle(
                      fontSize: 12,
                      color: Color(0xFFA1A8BC),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (verifyingTracking)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Verifying AniList progress...',
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFFA1A8BC),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              const _ContinueWatchingShelf(),
              const SizedBox(height: 12),
              if (loading && cachedSections.isEmpty)
                const _LibrarySkeletonBody()
              else if (hasError && sections.isEmpty)
                GlassCard(child: Text('Failed loading library: ${snap.error}'))
              else if (sections.isEmpty)
                const GlassCard(child: Text('No library items found.'))
              else
                ...filtered.map((section) => Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: _LibrarySection(
                        section: section,
                        verifyingTracking: verifyingTracking,
                      ),
                    )),
            ],
          ),
        );
      },
    );
  }
}

class _LocalLibraryView extends ConsumerWidget {
  const _LocalLibraryView({
    required this.selected,
    required this.onSelect,
  });

  final String selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entriesAsync = ref.watch(localLibraryEntriesProvider);
    final settings = ref.watch(appSettingsProvider);
    return entriesAsync.when(
      loading: () => const _LibrarySkeleton(),
      error: (e, _) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 120),
          children: [
            Text('Local Library',
                style: Theme.of(context).textTheme.displaySmall),
            const SizedBox(height: 10),
            GlassCard(child: Text('Failed loading local library: $e')),
          ],
        ),
      ),
      data: (entries) {
        final grouped = <String, List<AnimeEntry>>{};
        for (final entry in entries) {
          grouped.putIfAbsent(_statusLabel(entry.status), () => []).add(entry);
        }

        final chips = <String>['All', ...grouped.keys];
        final sections = selected == 'All'
            ? grouped.entries.toList()
            : grouped.entries.where((e) => e.key == selected).toList();

        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 120),
            children: [
              _LibraryAnimatedHero(
                items: entries
                    .where((e) => e.status == 'CURRENT')
                    .followedBy(entries.where((e) => e.status == 'PLANNING'))
                    .map(
                      (e) => AniListMedia(
                        id: e.mediaId,
                        title: AniListTitle(english: e.title),
                        cover: AniListCover(large: e.coverImage),
                        episodes: e.totalEpisodes <= 0 ? null : e.totalEpisodes,
                      ),
                    )
                    .toList(),
                title: 'Local Library',
                subtitle: 'Stored on this device',
              ),
              const SizedBox(height: 12),
              Text('Local Library',
                  style: Theme.of(context).textTheme.displaySmall),
              const Text('Stored on this device',
                  style: TextStyle(color: Color(0xFFA1A8BC))),
              const SizedBox(height: 12),
              const _ContinueWatchingShelf(),
              const SizedBox(height: 12),
              if (entries.isEmpty) ...[
                const GlassCard(child: Text('Your local library is empty.')),
                const SizedBox(height: 12),
                GlassButton(
                  onPressed: () {
                    hapticTap();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const DiscoveryScreen()),
                    );
                  },
                  child: const Text('Browse Discovery to add Anime'),
                ),
              ] else ...[
                GlassContainer(
                  borderRadius: 14,
                  child: SizedBox(
                    height: 38,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: chips.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final chip = chips[index];
                        final active = selected == chip;
                        return _LibraryFilterChip(
                          label: chip,
                          active: active,
                          isOledBlack: settings.isOledBlack,
                          onTap: () => onSelect(chip),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                ...sections.map(
                  (section) => Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: _LocalLibrarySection(
                      title: section.key,
                      items: section.value,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  static String _statusLabel(String status) {
    switch (status) {
      case 'CURRENT':
        return 'Watching';
      case 'COMPLETED':
        return 'Completed';
      case 'PAUSED':
        return 'Paused';
      case 'DROPPED':
        return 'Dropped';
      case 'PLANNING':
        return 'Planning';
      case 'REPEATING':
        return 'Repeating';
      default:
        return status;
    }
  }
}

class _LocalLibrarySection extends StatelessWidget {
  const _LocalLibrarySection({
    required this.title,
    required this.items,
  });

  final String title;
  final List<AnimeEntry> items;

  @override
  Widget build(BuildContext context) {
    final isWatchingSection = title.toLowerCase() == 'watching';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$title (${items.length})',
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        SizedBox(
          height: _kCardHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final entry = items[index];
              final media = AniListMedia(
                id: entry.mediaId,
                title: AniListTitle(english: entry.title),
                cover: AniListCover(large: entry.coverImage),
                episodes: entry.totalEpisodes <= 0 ? null : entry.totalEpisodes,
              );
              final progressText = entry.totalEpisodes > 0
                  ? '${entry.episodesWatched} / ${entry.totalEpisodes}'
                  : '${entry.episodesWatched}';
              return SizedBox(
                width: _kCardWidth,
                child: _HoverPosterTile(
                  onTap: () {
                    hapticTap();
                    Navigator.of(context).push(_detailsRoute(entry.mediaId));
                  },
                  child: Consumer(
                    builder: (context, ref, _) {
                      int? unseenCount;
                      if (isWatchingSection) {
                        final notifier = ref.watch(
                          libraryWatchingNotifierProvider(
                            (
                              mediaId: entry.mediaId,
                              progress: entry.episodesWatched,
                            ),
                          ),
                        );
                        final meta = notifier.valueOrNull;
                        if (meta != null &&
                            meta.status == 'RELEASING' &&
                            meta.unseen > 0) {
                          unseenCount = meta.unseen;
                        }
                      }
                      return _AnimePosterCard(
                        media: media,
                        progressText: progressText,
                        unseenCount: unseenCount,
                      );
                    },
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _LibraryAnimatedHero extends ConsumerStatefulWidget {
  const _LibraryAnimatedHero({
    required this.items,
    required this.title,
    required this.subtitle,
  });

  final List<AniListMedia> items;
  final String title;
  final String subtitle;

  @override
  ConsumerState<_LibraryAnimatedHero> createState() =>
      _LibraryAnimatedHeroState();
}

class _LibraryAnimatedHeroState extends ConsumerState<_LibraryAnimatedHero> {
  Timer? _timer;
  int _index = 0;
  final Map<String, Color> _ambientCache = <String, Color>{};
  String? _lastAmbientKey;

  @override
  void didUpdateWidget(covariant _LibraryAnimatedHero oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items != widget.items) {
      _index = 0;
      _restartTimer();
    }
  }

  @override
  void initState() {
    super.initState();
    _restartTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _restartTimer() {
    _timer?.cancel();
    if (widget.items.length <= 1) return;
    _timer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!mounted || widget.items.isEmpty) return;
      setState(() => _index = (_index + 1) % widget.items.length);
    });
  }

  Future<void> _syncAmbient(AniListMedia? media) async {
    final image = media?.bannerImage ?? media?.cover.best;
    if (image == null || image.isEmpty || _lastAmbientKey == image) return;
    _lastAmbientKey = image;
    final cached = _ambientCache[image];
    if (cached != null) {
      ref.read(uiAmbientColorProvider.notifier).state = cached;
      return;
    }
    try {
      final palette = await PaletteGenerator.fromImageProvider(
        KyomiruImageCache.provider(image),
        size: const Size(96, 96),
      );
      final color = palette.dominantColor?.color ??
          palette.vibrantColor?.color ??
          const Color(0xFF8B5CF6);
      final adjusted = Color.alphaBlend(
        Colors.black.withValues(alpha: 0.18),
        color,
      );
      _ambientCache[image] = adjusted;
      if (!mounted) return;
      ref.read(uiAmbientColorProvider.notifier).state = adjusted;
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final media = widget.items.isEmpty
        ? null
        : widget.items[_index % widget.items.length];
    unawaited(_syncAmbient(media));
    final image = media?.bannerImage ?? media?.cover.best;
    final genres = media?.genres.take(2).join('  ') ?? '';
    final score = media?.averageScore ?? 78;
    final matchScore = (score + 8).clamp(60, 99);
    final ratingTag = (media?.isAdult ?? false) ? 'R' : 'TV-14';
    return SizedBox(
      height: 250,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 520),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          child: Stack(
            key: ValueKey<int>(media?.id ?? -1),
            fit: StackFit.expand,
            children: [
              if (image != null)
                KyomiruImageCache.image(image, fit: BoxFit.cover)
              else
                const ColoredBox(color: Color(0x22111111)),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Color(0x33090B13),
                      Color(0x96090B13),
                      Color(0xFF090B13),
                    ],
                    stops: [0.0, 0.55, 0.78, 1.0],
                  ),
                ),
              ),
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.title,
                        style: const TextStyle(
                            fontSize: 28, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text(widget.subtitle,
                        style: const TextStyle(color: Color(0xFFA1A8BC))),
                    if (media != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        media.title.best,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w800),
                      ),
                      Row(
                        children: [
                          const Icon(Icons.star_rounded,
                              color: Colors.amber, size: 16),
                          const SizedBox(width: 4),
                          Text('${media.averageScore ?? 0}%'),
                          const SizedBox(width: 10),
                          Text(
                            '$matchScore% Match',
                            style: const TextStyle(
                              color: Color(0xFF86EFAC),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            ratingTag,
                            style: const TextStyle(
                              color: Color(0xFFBFDBFE),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (genres.isNotEmpty) ...[
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                genres,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white70),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LibrarySection extends StatelessWidget {
  const _LibrarySection({
    required this.section,
    required this.verifyingTracking,
  });

  final AniListLibrarySection section;
  final bool verifyingTracking;

  bool get _showProgress {
    final t = section.title.toLowerCase();
    return t.contains('current') || t.contains('watching');
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${section.title} (${section.items.length})',
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        SizedBox(
          height: _kCardHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: section.items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final e = section.items[index];
              return SizedBox(
                width: _kCardWidth,
                child: _HoverPosterTile(
                  onTap: () {
                    hapticTap();
                    Navigator.of(context).push(_detailsRoute(e.media.id));
                  },
                  child: Consumer(
                    builder: (context, ref, _) {
                      int? unseenCount;
                      if (_showProgress) {
                        final notifier = ref.watch(
                          libraryWatchingNotifierProvider(
                            (mediaId: e.media.id, progress: e.progress),
                          ),
                        );
                        final meta = notifier.valueOrNull;
                        if (meta != null &&
                            meta.status == 'RELEASING' &&
                            meta.unseen > 0) {
                          unseenCount = meta.unseen;
                        }
                      }
                      final card = _AnimePosterCard(
                        media: e.media,
                        progressText: _showProgress
                            ? '${e.progress}${e.media.episodes != null ? ' / ${e.media.episodes}' : ''}'
                            : null,
                        progressFraction: _showProgress &&
                                (e.media.episodes ?? 0) > 0
                            ? (e.progress / (e.media.episodes!)).clamp(0.0, 1.0)
                            : null,
                        unseenCount: unseenCount,
                      );
                      if (!(_showProgress && verifyingTracking)) {
                        return card;
                      }
                      return Shimmer.fromColors(
                        baseColor: Colors.white.withValues(alpha: 0.18),
                        highlightColor: Colors.white.withValues(alpha: 0.34),
                        child: card,
                      );
                    },
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _AnimePosterCard extends StatelessWidget {
  const _AnimePosterCard({
    required this.media,
    this.progressText,
    this.progressFraction,
    this.unseenCount,
  });

  final AniListMedia media;
  final String? progressText;
  final double? progressFraction;
  final int? unseenCount;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (media.cover.best != null)
            KyomiruImageCache.image(media.cover.best!, fit: BoxFit.cover)
          else
            Container(color: const Color(0x22111111)),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Color(0xE6000000)],
                stops: [0.52, 1],
              ),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFA1E1E1E),
                    borderRadius: BorderRadius.circular(999),
                    border:
                        Border.all(color: Colors.white.withValues(alpha: 0.10)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.star_rounded,
                          color: Colors.amber, size: 12),
                      const SizedBox(width: 3),
                      Text(media.averageScore?.toString() ?? 'NR',
                          style: const TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
                if ((unseenCount ?? 0) > 0) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.22),
                        width: 0.5,
                      ),
                    ),
                    child: Text(
                      '+${unseenCount!}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if ((progressFraction ?? 0) > 0)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                height: 3,
                color: Colors.white.withValues(alpha: 0.24),
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: (progressFraction ?? 0).clamp(0.0, 1.0),
                  child: Container(color: const Color(0xFF8B5CF6)),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(media.title.best,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: 14)),
                  if (progressText != null) ...[
                    const SizedBox(height: 2),
                    Text('Watched: $progressText',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w400,
                            fontSize: 12,
                            color: Color(0xFFE5E7EB))),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LibraryFilterChip extends StatelessWidget {
  const _LibraryFilterChip({
    required this.label,
    required this.active,
    required this.isOledBlack,
    required this.onTap,
  });

  final String label;
  final bool active;
  final bool isOledBlack;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return LiquidGlass.withOwnLayer(
      settings: kyomiruLiquidGlassSettings(isOledBlack: isOledBlack),
      shape: const LiquidRoundedSuperellipse(borderRadius: 999),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: active ? Colors.white : Colors.white70,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HoverPosterTile extends StatefulWidget {
  const _HoverPosterTile({
    required this.child,
    required this.onTap,
  });

  final Widget child;
  final VoidCallback onTap;

  @override
  State<_HoverPosterTile> createState() => _HoverPosterTileState();
}

class _HoverPosterTileState extends State<_HoverPosterTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          boxShadow: _hover
              ? [
                  BoxShadow(
                    color: Colors.white.withValues(alpha: 0.12),
                    blurRadius: 18,
                    spreadRadius: 1,
                  ),
                ]
              : const [],
        ),
        child: AnimatedScale(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          scale: _hover ? 1.05 : 1.0,
          child: GestureDetector(
            onTap: widget.onTap,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _ContinueWatchingShelf extends ConsumerWidget {
  const _ContinueWatchingShelf();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = Hive.box('watch_history');
    return ValueListenableBuilder(
      valueListenable: box.listenable(),
      builder: (context, Box<dynamic> _, __) {
        final entries = ref.read(watchHistoryStoreProvider).allEntries();
        if (entries.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Continue Watching',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 152,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: entries.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  return _ContinueWatchingCard(entry: entry);
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ContinueWatchingCard extends ConsumerWidget {
  const _ContinueWatchingCard({required this.entry});

  final WatchHistoryEntry entry;

  Future<void> _markWatched(BuildContext context, WidgetRef ref) async {
    final auth = ref.read(authControllerProvider);
    final token = auth.token;
    if (token != null && token.isNotEmpty) {
      try {
        final client = ref.read(anilistClientProvider);
        final current = await client.trackingEntry(token, entry.mediaId);
        final targetProgress = ((current?.progress ?? 0) > entry.episodeNumber)
            ? (current?.progress ?? 0)
            : entry.episodeNumber;
        final currentStatus = current?.status ?? 'CURRENT';
        final nextStatus =
            currentStatus == 'PLANNING' ? 'CURRENT' : currentStatus;
        await client.saveTrackingEntry(
          token: token,
          mediaId: entry.mediaId,
          status: nextStatus,
          progress: targetProgress,
          score: current?.score ?? 0,
          entryId: current?.id == 0 ? null : current?.id,
        );
        ref.invalidate(mediaListProvider(entry.mediaId));
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('AniList sync failed')),
          );
        }
      }
    }

    await ref
        .read(watchHistoryStoreProvider)
        .removeByStorageKey(entry.storageKey);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Marked as watched')),
    );
  }

  String _formatDurationMs(int ms) {
    if (ms <= 0) return '0:00';
    final d = Duration(milliseconds: ms);
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      return '${d.inHours}:$m:$s';
    }
    return '$m:$s';
  }

  String _formatTimeLeft(int remainingMs) {
    if (remainingMs <= 0) return 'Done';
    final totalMinutes = (remainingMs / 60000).ceil();
    if (totalMinutes < 1) return '<1 min left';
    if (totalMinutes < 60) return '$totalMinutes min left';
    final hours = totalMinutes ~/ 60;
    final mins = totalMinutes % 60;
    if (mins == 0) return '${hours}h left';
    return '${hours}h ${mins}m left';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progress = entry.progress;
    final percent = (progress * 100).round();
    final remainingMs = (entry.totalDurationMs - entry.lastPositionMs)
        .clamp(0, entry.totalDurationMs);
    final timeLeftLabel = _formatTimeLeft(remainingMs);
    final notifierAsync = ref.watch(
      continueWatchingNotifierProvider(
        (
          mediaId: entry.mediaId,
          lastCompleted: entry.lastCompletedEpisode,
        ),
      ),
    );
    final notifier = notifierAsync.valueOrNull;
    final unseen = notifier?.unseen ?? 0;
    final showUnseen = unseen > 0 && notifier?.status == 'RELEASING';
    final globalProgressTotal = (notifier?.totalAvailable ?? 0) > 0
        ? notifier!.totalAvailable
        : entry.episodeNumber;
    final localArtworkAsync = ref.watch(
      localEpisodeArtworkFileProvider(
        LocalEpisodeArtworkQuery(
          mediaId: entry.mediaId,
          episode: entry.episodeNumber,
        ),
      ),
    );
    final localArtwork = localArtworkAsync.valueOrNull;
    final networkFallback = ref
        .watch(continueWatchingArtworkFallbackProvider(entry.mediaId))
        .valueOrNull;
    final resolvedCoverUrl = (() {
      final stored = (entry.coverImageUrl ?? '').trim();
      if (stored.isNotEmpty) return stored;
      final fetched = (networkFallback ?? '').trim();
      if (fetched.isNotEmpty) return fetched;
      return null;
    })();
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onLongPress: () => _markWatched(context, ref),
        onTap: () {
          hapticTap();
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => PlayerScreen(
                mediaId: entry.mediaId,
                episodeNumber: entry.episodeNumber,
                episodeTitle: entry.episodeTitle,
                sourceUrl: entry.sourceUrl,
                mediaTitle: entry.mediaTitle,
                headers: entry.headers,
                isLocal: entry.isDownloaded,
                backgroundImageUrl: entry.coverImageUrl,
                resumePositionMs: entry.lastPositionMs,
              ),
            ),
          );
        },
        child: Container(
          width: 252,
          decoration: BoxDecoration(
            color: const Color(0xFA1E1E1E),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final progressWidth = (constraints.maxWidth * progress)
                  .clamp(0.0, constraints.maxWidth);
              return Stack(
                children: [
                  Row(
                    children: [
                      ClipRRect(
                        borderRadius: const BorderRadius.horizontal(
                          left: Radius.circular(16),
                        ),
                        child: SizedBox(
                          width: 92,
                          height: double.infinity,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (localArtwork != null)
                                Image.file(
                                  localArtwork,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) {
                                    if (resolvedCoverUrl != null) {
                                      return KyomiruImageCache.image(
                                        resolvedCoverUrl,
                                        fit: BoxFit.cover,
                                        error: const ColoredBox(
                                            color: Color(0x22111111)),
                                      );
                                    }
                                    return const ColoredBox(
                                        color: Color(0x22111111));
                                  },
                                )
                              else if (resolvedCoverUrl != null)
                                KyomiruImageCache.image(
                                  resolvedCoverUrl,
                                  fit: BoxFit.cover,
                                  error: const ColoredBox(
                                      color: Color(0x22111111)),
                                )
                              else
                                const ColoredBox(color: Color(0x22111111)),
                              Positioned.fill(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.transparent,
                                        Colors.black.withValues(alpha: 0.45),
                                      ],
                                      stops: const [0.58, 1.0],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                entry.mediaTitle,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Episode ${entry.episodeNumber}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                              const Spacer(),
                              Text(
                                '$percent% • ${_formatDurationMs(entry.lastPositionMs)} / ${_formatDurationMs(entry.totalDurationMs)} • ${entry.lastCompletedEpisode}/$globalProgressTotal${entry.isDownloaded ? ' • Local' : ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                ),
                              ),
                              const SizedBox(height: 8),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      height: 4,
                      width: double.infinity,
                      decoration: const BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.vertical(
                          bottom: Radius.circular(16),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    bottom: 0,
                    child: Container(
                      height: 4,
                      width: progressWidth,
                      decoration: const BoxDecoration(
                        color: Color(0xFF3B82F6),
                        borderRadius: BorderRadius.vertical(
                          bottom: Radius.circular(16),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 4,
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(20, 4, 10, 4),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.55),
                          ],
                        ),
                      ),
                      child: Text(
                        timeLeftLabel,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  if (showUnseen)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEF4444),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.16),
                          ),
                        ),
                        child: Text(
                          '+$unseen',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _LibrarySkeleton extends StatelessWidget {
  const _LibrarySkeleton();

  @override
  Widget build(BuildContext context) {
    return const SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(14, 14, 14, 120),
        child: _LibrarySkeletonBody(),
      ),
    );
  }
}

class _LibrarySkeletonBody extends StatelessWidget {
  const _LibrarySkeletonBody();

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: const Color(0xFF333333),
      highlightColor: const Color(0xFF555555),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
              height: 28,
              width: 180,
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10))),
          const SizedBox(height: 8),
          Container(
              height: 16,
              width: 220,
              decoration: BoxDecoration(
                  color: Colors.white, borderRadius: BorderRadius.circular(8))),
          const SizedBox(height: 14),
          for (var i = 0; i < 2; i++) ...[
            Container(
                height: 22,
                width: 170,
                decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8))),
            const SizedBox(height: 8),
            SizedBox(
              height: _kCardHeight,
              child: Row(
                children: List.generate(
                  3,
                  (index) => Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Container(
                        decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(16)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
          ],
        ],
      ),
    );
  }
}
