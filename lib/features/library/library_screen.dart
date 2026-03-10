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
