import 'dart:async';
import 'dart:io';
import 'dart:ui';

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
import '../../services/progress_store.dart';
import '../../services/watch_history_store.dart';
import '../../state/app_settings_state.dart';
import '../../state/auth_state.dart';
import '../../state/library_source_state.dart';
import '../../state/library_preferences_state.dart';
import '../../state/tracking_state.dart';
import '../../state/ui_ambient_state.dart';
import '../../state/watch_history_state.dart';

const double _kCardWidth = 152;
const double _kCardHeight = 232;
const double _kListCardHeight = 102;

class _CatalogView {
  const _CatalogView({
    required this.id,
    required this.title,
    required this.items,
  });

  final String id;
  final String title;
  final List<AniListLibraryEntry> items;
}

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
    required this.normalizedProgress,
    required this.status,
  });

  final int unseen;
  final int totalAvailable;
  final int normalizedProgress;
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
      normalizedProgress: 0,
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
      normalizedProgress: 0,
      status: '',
    );
  }
  final released = (info.latestReleasedEpisode > 0)
      ? info.latestReleasedEpisode
      : info.availableEpisodes;
  final normalizedProgress = released > 0
      ? query.lastCompleted.clamp(0, released)
      : query.lastCompleted;
  final unseen = (released - normalizedProgress).clamp(0, 9999);
  return _ContinueWatchingNotifierMeta(
    unseen: unseen,
    totalAvailable: released,
    normalizedProgress: normalizedProgress,
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
      normalizedProgress: 0,
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
      normalizedProgress: 0,
      status: '',
    );
  }
  final released = (info.latestReleasedEpisode > 0)
      ? info.latestReleasedEpisode
      : info.availableEpisodes;
  final normalizedProgress =
      released > 0 ? query.progress.clamp(0, released) : query.progress;
  final unseen = (released - normalizedProgress).clamp(0, 9999);
  return _ContinueWatchingNotifierMeta(
    unseen: unseen,
    totalAvailable: released,
    normalizedProgress: normalizedProgress,
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
  String _selectedCatalogId = 'current';
  String _selectedLocal = 'All';
  int _refreshTick = 0;
  bool _isVerifyingTracking = false;
  bool _launchTrackingSyncStarted = false;
  final Map<String, Set<String>> _selectedGenresByCatalog =
      <String, Set<String>>{};

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
        selected: _selectedLocal,
        onSelect: (value) {
          hapticTap();
          setState(() => _selectedLocal = value);
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
      key: ValueKey('$_selectedCatalogId-$_refreshTick'),
      token: auth.token!,
      selectedCatalogId: _selectedCatalogId,
      selectedGenresByCatalog: _selectedGenresByCatalog,
      verifyingTracking: _isVerifyingTracking,
      onSelectCatalog: (value) {
        hapticTap();
        setState(() => _selectedCatalogId = value);
      },
      onSetGenres: (catalogId, genres) {
        setState(() {
          _selectedGenresByCatalog[catalogId] = genres;
        });
      },
      onRefresh: _refresh,
    );
  }
}

class _LibraryDataView extends ConsumerWidget {
  const _LibraryDataView({
    super.key,
    required this.token,
    required this.selectedCatalogId,
    required this.selectedGenresByCatalog,
    required this.verifyingTracking,
    required this.onSelectCatalog,
    required this.onSetGenres,
    required this.onRefresh,
  });

  final String token;
  final String selectedCatalogId;
  final Map<String, Set<String>> selectedGenresByCatalog;
  final bool verifyingTracking;
  final ValueChanged<String> onSelectCatalog;
  final void Function(String catalogId, Set<String> genres) onSetGenres;
  final Future<void> Function() onRefresh;

  static const List<MapEntry<String, String>> _standardCatalogs = [
    MapEntry('current', 'Currently Watching'),
    MapEntry('planning', 'Planning'),
    MapEntry('completed', 'Completed'),
    MapEntry('paused', 'Paused'),
    MapEntry('dropped', 'Dropped'),
  ];

  static String _normalizeTitleToCatalogId(String title) {
    final t = title.toLowerCase();
    if (t.contains('current') || t.contains('watch')) return 'current';
    if (t.contains('plan')) return 'planning';
    if (t.contains('complete')) return 'completed';
    if (t.contains('pause')) return 'paused';
    if (t.contains('drop')) return 'dropped';
    return '';
  }

  static List<AniListLibraryEntry> _sortedItems(
    List<AniListLibraryEntry> input,
    LibrarySortMode mode,
  ) {
    final out = [...input];
    switch (mode) {
      case LibrarySortMode.az:
        out.sort((a, b) => a.media.title.best.compareTo(b.media.title.best));
      case LibrarySortMode.za:
        out.sort((a, b) => b.media.title.best.compareTo(a.media.title.best));
      case LibrarySortMode.recentlyUpdated:
        out.sort((a, b) => b.progress.compareTo(a.progress));
      case LibrarySortMode.dateAdded:
        out.sort((a, b) => b.id.compareTo(a.id));
      case LibrarySortMode.highestScore:
        out.sort(
          (a, b) => (b.media.averageScore ?? 0).compareTo(
            a.media.averageScore ?? 0,
          ),
        );
    }
    return out;
  }

  static List<AniListLibraryEntry> _genreFilteredItems(
    List<AniListLibraryEntry> input,
    Set<String> selectedGenres,
  ) {
    if (selectedGenres.isEmpty) return input;
    return input.where((item) {
      final genres = item.media.genres.map((e) => e.toLowerCase()).toSet();
      return selectedGenres.every(genres.contains);
    }).toList();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(anilistClientProvider);
    final settings = ref.watch(appSettingsProvider);
    final prefs = ref.watch(libraryPreferencesProvider);
    final prefsNotifier = ref.read(libraryPreferencesProvider.notifier);
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

        final titleById = <String, String>{
          for (final c in _standardCatalogs) c.key: c.value,
          for (final c in prefs.customCatalogs) c.id: c.title,
        };

        final entriesByMediaId = <int, AniListLibraryEntry>{};
        final normalized = <String, List<AniListLibraryEntry>>{};
        for (final sec in sections) {
          final id = _normalizeTitleToCatalogId(sec.title);
          if (id.isEmpty) continue;
          final list = normalized.putIfAbsent(id, () => <AniListLibraryEntry>[]);
          for (final item in sec.items) {
            entriesByMediaId[item.media.id] = item;
            list.add(item);
          }
        }

        final customCatalogsAsSections = <String, List<AniListLibraryEntry>>{};
        for (final custom in prefs.customCatalogs) {
          final items = custom.mediaIds
              .map((id) => entriesByMediaId[id])
              .whereType<AniListLibraryEntry>()
              .toList();
          customCatalogsAsSections[custom.id] = items;
        }

        final allCatalogIds = <String>[
          ...prefs.catalogOrder.where(titleById.containsKey),
          ...titleById.keys.where((id) => !prefs.catalogOrder.contains(id)),
        ];
        final visibleCatalogIds = allCatalogIds;

        final catalogs = <_CatalogView>[];
        for (final id in visibleCatalogIds) {
          final source = normalized[id] ?? customCatalogsAsSections[id] ?? const [];
          final sortMode = prefsNotifier.sortForCatalog(id);
          final sorted = _sortedItems(source, sortMode);
          final filteredByGenre = _genreFilteredItems(
            sorted,
            selectedGenresByCatalog[id] ?? const <String>{},
          );
          catalogs.add(
            _CatalogView(
              id: id,
              title: titleById[id] ?? id,
              items: filteredByGenre,
            ),
          );
        }

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
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                runSpacing: 8,
                spacing: 8,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.sort_rounded, size: 18),
                      const SizedBox(width: 8),
                      DropdownButton<LibrarySortMode>(
                        value: prefs.defaultSort,
                        items: LibrarySortMode.values
                            .map(
                              (m) => DropdownMenuItem(
                                value: m,
                                child: Text(m.label),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value == null) return;
                          prefsNotifier.setDefaultSort(value);
                        },
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Grid view',
                        onPressed: () => prefsNotifier.setLayoutMode(
                          LibraryLayoutMode.grid,
                        ),
                        icon: Icon(
                          Icons.grid_view_rounded,
                          color: prefs.layoutMode == LibraryLayoutMode.grid
                              ? Colors.white
                              : Colors.white60,
                        ),
                      ),
                      IconButton(
                        tooltip: 'List view',
                        onPressed: () => prefsNotifier.setLayoutMode(
                          LibraryLayoutMode.list,
                        ),
                        icon: Icon(
                          Icons.view_list_rounded,
                          color: prefs.layoutMode == LibraryLayoutMode.list
                              ? Colors.white
                              : Colors.white60,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
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
              else if (catalogs.isEmpty)
                const _LibraryEmptyState(
                  icon: Icons.menu_open_rounded,
                  title: 'No Catalogs',
                  subtitle: 'Your library is empty right now.',
                )
              else ...[
                for (final catalog in catalogs) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: _LibraryCatalogSection(
                      catalogId: catalog.id,
                      title: catalog.title,
                      items: catalog.items,
                      verifyingTracking: verifyingTracking,
                      listMode: prefs.layoutMode == LibraryLayoutMode.list,
                      onLongPressEntry: (entry) async {
                        if (prefs.customCatalogs.isEmpty) return;
                        await showModalBottomSheet<void>(
                          context: context,
                          backgroundColor: const Color(0xFF0F111A),
                          builder: (context) => _CustomCatalogPickerSheet(
                            entry: entry,
                            catalogs: prefs.customCatalogs,
                            onToggle: (catalogId) {
                              prefsNotifier.toggleMediaInCustomCatalog(
                                catalogId,
                                entry.media.id,
                              );
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ],
          ),
        );
      },
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
    final bg = active
        ? const Color(0xFF1F2937)
        : (isOledBlack ? Colors.black : const Color(0xFF0F111A));
    final fg = active ? Colors.white : Colors.white70;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: fg,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _LibraryCatalogSection extends StatelessWidget {
  const _LibraryCatalogSection({
    required this.catalogId,
    required this.title,
    required this.items,
    required this.verifyingTracking,
    required this.listMode,
    required this.onLongPressEntry,
  });

  final String catalogId;
  final String title;
  final List<AniListLibraryEntry> items;
  final bool verifyingTracking;
  final bool listMode;
  final Future<void> Function(AniListLibraryEntry entry) onLongPressEntry;

  bool get _showProgress {
    final t = catalogId.toLowerCase();
    return t.contains('current') || t.contains('watching');
  }

  bool get _showRating {
    final t = catalogId.toLowerCase();
    return t.contains('current') || t.contains('watching') || t.contains('plan');
  }

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$title (0)',
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          GlassCard(child: Text('Nothing in $title yet.')),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$title (${items.length})',
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        if (!listMode)
          SizedBox(
            height: _kCardHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final e = items[index];
                return SizedBox(
                  width: _kCardWidth,
                  child: _HoverPosterTile(
                    onTap: () {
                      hapticTap();
                      Navigator.of(context).push(_detailsRoute(e.media.id));
                    },
                    onLongPress: () => onLongPressEntry(e),
                    child: _LibraryEntryCard(
                      entry: e,
                      showProgress: _showProgress,
                      showRating: _showRating,
                      verifyingTracking: verifyingTracking,
                      listMode: false,
                    ),
                  ),
                );
              },
            ),
          )
        else
          Column(
            children: [
              for (final e in items) ...[
                _HoverPosterTile(
                  onTap: () {
                    hapticTap();
                    Navigator.of(context).push(_detailsRoute(e.media.id));
                  },
                  onLongPress: () => onLongPressEntry(e),
                  child: SizedBox(
                    height: _kListCardHeight,
                    child: _LibraryEntryCard(
                      entry: e,
                      showProgress: _showProgress,
                      showRating: _showRating,
                      verifyingTracking: verifyingTracking,
                      listMode: true,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ]
            ],
          ),
      ],
    );
  }
}

class _LibraryEntryCard extends ConsumerWidget {
  const _LibraryEntryCard({
    required this.entry,
    required this.showProgress,
    required this.showRating,
    required this.verifyingTracking,
    required this.listMode,
  });

  final AniListLibraryEntry entry;
  final bool showProgress;
  final bool showRating;
  final bool verifyingTracking;
  final bool listMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    String? unwatchedBadgeText;
    if (showProgress) {
      final notifier = ref.watch(
        libraryWatchingNotifierProvider(
          (mediaId: entry.media.id, progress: entry.progress),
        ),
      );
      final meta = notifier.valueOrNull;
      final isReleasing = (meta?.status.toUpperCase() ?? '') == 'RELEASING';
      if (meta != null && isReleasing && meta.unseen > 0) {
        unwatchedBadgeText = '${meta.unseen}/${meta.totalAvailable}';
      }
    }
    final card = listMode
        ? _AnimeListCard(
            media: entry.media,
            progressText: showProgress
                ? '${entry.progress}${entry.media.episodes != null ? ' / ${entry.media.episodes}' : ''}'
                : null,
            progressFraction: showProgress && (entry.media.episodes ?? 0) > 0
                ? (entry.progress / (entry.media.episodes!)).clamp(0.0, 1.0)
                : null,
            unwatchedBadgeText: unwatchedBadgeText,
            showRating: showRating,
          )
        : _AnimePosterCard(
            media: entry.media,
            progressText: showProgress
                ? '${entry.progress}${entry.media.episodes != null ? ' / ${entry.media.episodes}' : ''}'
                : null,
            progressFraction: showProgress && (entry.media.episodes ?? 0) > 0
                ? (entry.progress / (entry.media.episodes!)).clamp(0.0, 1.0)
                : null,
            unwatchedBadgeText: unwatchedBadgeText,
            showRating: showRating,
          );
    if (!(showProgress && verifyingTracking)) return card;
    return Shimmer.fromColors(
      baseColor: Colors.white.withValues(alpha: 0.18),
      highlightColor: Colors.white.withValues(alpha: 0.34),
      child: card,
    );
  }
}

class _AnimeListCard extends StatelessWidget {
  const _AnimeListCard({
    required this.media,
    this.progressText,
    this.progressFraction,
    this.unwatchedBadgeText,
    this.showRating = true,
  });

  final AniListMedia media;
  final String? progressText;
  final double? progressFraction;
  final String? unwatchedBadgeText;
  final bool showRating;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              color: const Color(0xFA1E1E1E),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
          ),
          Row(
            children: [
              AspectRatio(
                aspectRatio: 16 / 9,
                child: media.cover.best != null
                    ? KyomiruImageCache.image(media.cover.best!, fit: BoxFit.cover)
                    : Container(color: const Color(0x22111111)),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        media.title.best,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Score: ${media.averageScore ?? 0}%',
                        style:
                            const TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                      if (progressText != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          'Watched: $progressText',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFFE5E7EB),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (showRating)
            Positioned(
              top: 8,
              right: 8,
              child: RatingBadge(rating: media.averageScore?.toDouble()),
            ),
          if ((unwatchedBadgeText ?? '').isNotEmpty)
            Positioned(
              top: 8,
              left: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xCC263046), Color(0xB11A2234)],
                  ),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.44),
                    width: 0.5,
                  ),
                ),
                child: Text(
                  unwatchedBadgeText!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          if ((progressFraction ?? 0) > 0)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                height: 3,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
          if ((progressFraction ?? 0) > 0)
            Positioned(
              left: 0,
              bottom: 0,
              child: Container(
                height: 3,
                width: (progressFraction ?? 0) * 400,
                decoration: BoxDecoration(
                  color: const Color(0xFF3B82F6),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AnimePosterCard extends StatelessWidget {
  const _AnimePosterCard({
    required this.media,
    this.progressText,
    this.progressFraction,
    this.unwatchedBadgeText,
    this.showRating = true,
  });

  final AniListMedia media;
  final String? progressText;
  final double? progressFraction;
  final String? unwatchedBadgeText;
  final bool showRating;

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
                stops: [0.54, 1],
              ),
            ),
          ),
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Column(
                children: [
                  Row(
                    children: [
                      if ((unwatchedBadgeText ?? '').isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Color(0xCC263046), Color(0xB11A2234)],
                            ),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.44),
                              width: 0.5,
                            ),
                          ),
                          child: Text(
                            unwatchedBadgeText!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      const Spacer(),
                      if (showRating)
                        RatingBadge(rating: media.averageScore?.toDouble()),
                    ],
                  ),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Text(
                      media.title.best,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  if (progressText != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      progressText!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          if ((progressFraction ?? 0) > 0)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                height: 3,
                width: double.infinity,
                decoration: const BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.vertical(
                    bottom: Radius.circular(18),
                  ),
                ),
              ),
            ),
          if ((progressFraction ?? 0) > 0)
            Positioned(
              left: 0,
              bottom: 0,
              child: Container(
                height: 3,
                width: 152 * (progressFraction ?? 0),
                decoration: const BoxDecoration(
                  color: Color(0xFF3B82F6),
                  borderRadius: BorderRadius.vertical(
                    bottom: Radius.circular(18),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _HoverPosterTile extends StatefulWidget {
  const _HoverPosterTile({
    required this.child,
    required this.onTap,
    this.onLongPress,
  });

  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

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
            onLongPress: widget.onLongPress,
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

class _ContinueWatchingCard extends ConsumerStatefulWidget {
  const _ContinueWatchingCard({required this.entry});

  final WatchHistoryEntry entry;

  @override
  ConsumerState<_ContinueWatchingCard> createState() =>
      _ContinueWatchingCardState();
}

class _ContinueWatchingCardState extends ConsumerState<_ContinueWatchingCard> {
  bool _hovered = false;

  bool get _desktopLike =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  WatchHistoryEntry get entry => widget.entry;

  Future<void> _markWatched() async {
    final auth = ref.read(authControllerProvider);
    final token = auth.token;
    final durationMs = entry.totalDurationMs > 0
        ? entry.totalDurationMs
        : (entry.lastPositionMs > 0 ? entry.lastPositionMs : 1);

    await ref.read(progressStoreProvider).write(
          mediaId: entry.mediaId,
          episode: entry.episodeNumber,
          positionMs: durationMs,
          durationMs: durationMs,
        );
    if (entry.isDownloaded) {
      await ref.read(downloadControllerProvider.notifier).setLocalPlaybackPosition(
            entry.mediaId,
            entry.episodeNumber,
            positionMs: durationMs,
            durationMs: durationMs,
          );
    }

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
        if (mounted) {
          _showContinueWatchingAlert('AniList sync failed');
        }
      }
    }

    await ref.read(watchHistoryStoreProvider).removeByStorageKey(entry.storageKey);
    if (!mounted) return;
    _showContinueWatchingAlert('Episode marked as watched');
  }

  Future<void> _removeFromHistory() async {
    await ref.read(watchHistoryStoreProvider).removeByStorageKey(entry.storageKey);
    if (!mounted) return;
    _showContinueWatchingAlert('History cleared');
  }

  Future<void> _showActions() async {
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
                  leading: const Icon(Icons.check_circle_rounded),
                  title: const Text('Mark as Watched'),
                  onTap: () {
                    Navigator.of(context).pop();
                    unawaited(_markWatched());
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.history_toggle_off_rounded),
                  title: const Text('Remove from History'),
                  onTap: () {
                    Navigator.of(context).pop();
                    unawaited(_removeFromHistory());
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showContinueWatchingAlert(String message) {
    final messenger = ScaffoldMessenger.of(context);
    final insets = MediaQuery.viewPaddingOf(context);
    final safeBottom = (insets.bottom + 12).clamp(24.0, 96.0);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.fromLTRB(16, 0, 16, safeBottom),
        content: ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
              child: Text(
                message,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _formatDurationMs(int ms) {
    if (ms <= 0) return '0:00';
    final d = Duration(milliseconds: ms);
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) return '${d.inHours}:$m:$s';
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
  Widget build(BuildContext context) {
    final progress = entry.progress;
    final percent = (progress * 100).round();
    final remainingMs =
        (entry.totalDurationMs - entry.lastPositionMs).clamp(0, entry.totalDurationMs);
    final timeLeftLabel = _formatTimeLeft(remainingMs);
    final notifierAsync = ref.watch(
      continueWatchingNotifierProvider(
        (mediaId: entry.mediaId, lastCompleted: entry.lastCompletedEpisode),
      ),
    );
    final notifier = notifierAsync.valueOrNull;
    final globalProgressTotal = (notifier?.totalAvailable ?? 0) > 0
        ? notifier!.totalAvailable
        : entry.episodeNumber;
    final localArtworkAsync = ref.watch(
      localEpisodeArtworkFileProvider(
        LocalEpisodeArtworkQuery(mediaId: entry.mediaId, episode: entry.episodeNumber),
      ),
    );
    final localArtwork = localArtworkAsync.valueOrNull;
    final networkFallback =
        ref.watch(continueWatchingArtworkFallbackProvider(entry.mediaId)).valueOrNull;
    final resolvedCoverUrl = (() {
      final stored = (entry.coverImageUrl ?? '').trim();
      if (stored.isNotEmpty) return stored;
      final fetched = (networkFallback ?? '').trim();
      if (fetched.isNotEmpty) return fetched;
      return null;
    })();

    return MouseRegion(
      onEnter: (_) {
        if (_desktopLike) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_desktopLike) setState(() => _hovered = false);
      },
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onLongPress: _showActions,
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
                final progressWidth =
                    (constraints.maxWidth * progress).clamp(0.0, constraints.maxWidth);
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
                                          error:
                                              const ColoredBox(color: Color(0x22111111)),
                                        );
                                      }
                                      return const ColoredBox(color: Color(0x22111111));
                                    },
                                  )
                                else if (resolvedCoverUrl != null)
                                  KyomiruImageCache.image(
                                    resolvedCoverUrl,
                                    fit: BoxFit.cover,
                                    error: const ColoredBox(color: Color(0x22111111)),
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
                    if (_desktopLike)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 140),
                          opacity: _hovered ? 1 : 0,
                          child: IgnorePointer(
                            ignoring: !_hovered,
                            child: Row(
                              children: [
                                _DesktopQuickAction(
                                  icon: Icons.check_rounded,
                                  onTap: () => unawaited(_markWatched()),
                                ),
                                const SizedBox(width: 6),
                                _DesktopQuickAction(
                                  icon: Icons.close_rounded,
                                  onTap: () => unawaited(_removeFromHistory()),
                                ),
                              ],
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
      ),
    );
  }
}

class _LibraryEmptyState extends StatelessWidget {
  const _LibraryEmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Row(
        children: [
          Icon(icon, size: 28, color: Colors.white70),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CustomCatalogPickerSheet extends StatelessWidget {
  const _CustomCatalogPickerSheet({
    required this.entry,
    required this.catalogs,
    required this.onToggle,
  });

  final AniListLibraryEntry entry;
  final List<CustomCatalog> catalogs;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: GlassContainer(
          borderRadius: 18,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 6),
              const Text(
                'Add to Catalog',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              for (final catalog in catalogs)
                CheckboxListTile(
                  value: catalog.mediaIds.contains(entry.media.id),
                  onChanged: (_) => onToggle(catalog.id),
                  title: Text(catalog.title),
                ),
              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
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
    final prefs = ref.watch(libraryPreferencesProvider);
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

        final sortedGrouped = <String, List<AnimeEntry>>{};
        for (final entry in grouped.entries) {
          sortedGrouped[entry.key] =
              _sortedLocalEntries(entry.value, prefs.defaultSort);
        }

        final chips = <String>['All', ...sortedGrouped.keys];
        final sections = selected == 'All'
            ? sortedGrouped.entries.toList()
            : sortedGrouped.entries.where((e) => e.key == selected).toList();

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
                      listMode: prefs.layoutMode == LibraryLayoutMode.list,
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

  static List<AnimeEntry> _sortedLocalEntries(
    List<AnimeEntry> input,
    LibrarySortMode mode,
  ) {
    final out = [...input];
    switch (mode) {
      case LibrarySortMode.az:
        out.sort((a, b) => a.title.compareTo(b.title));
      case LibrarySortMode.za:
        out.sort((a, b) => b.title.compareTo(a.title));
      case LibrarySortMode.recentlyUpdated:
        out.sort((a, b) => b.episodesWatched.compareTo(a.episodesWatched));
      case LibrarySortMode.dateAdded:
        out.sort((a, b) => b.mediaId.compareTo(a.mediaId));
      case LibrarySortMode.highestScore:
        out.sort((a, b) => b.userScore.compareTo(a.userScore));
    }
    return out;
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
    required this.listMode,
  });

  final String title;
  final List<AnimeEntry> items;
  final bool listMode;

  static int? _normalizeScore(double score) {
    if (score <= 0) return null;
    if (score > 10) return score.round();
    return (score * 10).round();
  }

  @override
  Widget build(BuildContext context) {
    final isWatchingSection = title.toLowerCase() == 'watching';

    Widget buildCard(AnimeEntry entry) {
      final media = AniListMedia(
        id: entry.mediaId,
        title: AniListTitle(english: entry.title),
        cover: AniListCover(large: entry.coverImage),
        episodes: entry.totalEpisodes <= 0 ? null : entry.totalEpisodes,
        averageScore: _normalizeScore(entry.userScore),
      );
      final progressText = entry.totalEpisodes > 0
          ? '${entry.episodesWatched} / ${entry.totalEpisodes}'
          : '${entry.episodesWatched}';
      final progressFraction = entry.totalEpisodes > 0
          ? (entry.episodesWatched / entry.totalEpisodes).clamp(0.0, 1.0)
          : null;
      if (listMode) {
        return _AnimeListCard(
          media: media,
          progressText: progressText,
          progressFraction: progressFraction,
        );
      }
      return _AnimePosterCard(
        media: media,
        progressText: progressText,
      );
    }

    if (items.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$title (0)',
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          GlassCard(child: Text('Nothing in $title yet.')),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$title (${items.length})',
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        if (!listMode)
          SizedBox(
            height: _kCardHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final entry = items[index];
                return SizedBox(
                  width: _kCardWidth,
                  child: _HoverPosterTile(
                    onTap: () {
                      hapticTap();
                      Navigator.of(context).push(_detailsRoute(entry.mediaId));
                    },
                    child: buildCard(entry),
                  ),
                );
              },
            ),
          )
        else
          Column(
            children: [
              for (final entry in items) ...[
                _HoverPosterTile(
                  onTap: () {
                    hapticTap();
                    Navigator.of(context).push(_detailsRoute(entry.mediaId));
                  },
                  child: SizedBox(
                    height: _kListCardHeight,
                    child: buildCard(entry),
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ],
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
    final score = media?.averageScore ?? 0;
    final matchScore = (score + 8).clamp(60, 99);
    final ratingTag = (media?.isAdult ?? false) ? 'R' : 'TV-14';

    Widget pill({required IconData icon, required String label, Color? color}) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.34),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color ?? Colors.white),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: color == null ? Colors.white : Colors.white,
                fontSize: 12,
              ),
            ),
          ],
        ),
      );
    }

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
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 10,
                        runSpacing: 6,
                        children: [
                          pill(
                            icon: Icons.thumb_up_alt_rounded,
                            label: '$matchScore% Match',
                            color: const Color(0xFF22C55E),
                          ),
                          pill(
                            icon: Icons.star_rounded,
                            label: '${media.averageScore ?? 0}%',
                            color: const Color(0xFFFFD54F),
                          ),
                          pill(
                            icon: Icons.shield_rounded,
                            label: ratingTag,
                            color: const Color(0xFF93C5FD),
                          ),
                          if (genres.isNotEmpty)
                            pill(
                              icon: Icons.local_offer_rounded,
                              label: genres,
                              color: Colors.white70,
                            ),
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

class _DesktopQuickAction extends StatelessWidget {
  const _DesktopQuickAction({
    required this.icon,
    required this.onTap,
  });

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xCC111827),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(icon, size: 14, color: Colors.white),
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
