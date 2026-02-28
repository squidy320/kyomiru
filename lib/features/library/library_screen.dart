import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shimmer/shimmer.dart';

import '../../core/glass_widgets.dart';
import '../../core/haptics.dart';
import '../../core/image_cache.dart';
import '../../features/auth/anilist_login_webview_screen.dart';
import '../../features/details/details_screen.dart';
import '../../features/discovery/discovery_screen.dart';
import '../../models/anilist_models.dart';
import '../../services/local_library_store.dart';
import '../../state/auth_state.dart';
import '../../state/library_source_state.dart';

const double _kCardWidth = 152;
const double _kCardHeight = 232;

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen>
    with AutomaticKeepAliveClientMixin {
  String _selected = 'All';
  int _refreshTick = 0;

  Future<void> _refresh() async {
    setState(() => _refreshTick++);
    await Future<void>.delayed(const Duration(milliseconds: 120));
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

    return _LibraryDataView(
      key: ValueKey('$_selected-$_refreshTick'),
      token: auth.token!,
      selected: _selected,
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
    required this.onSelect,
    required this.onRefresh,
  });

  final String token;
  final String selected;
  final ValueChanged<String> onSelect;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(anilistClientProvider);

    return FutureBuilder<List<dynamic>>(
      future: client.me(token).then(
          (u) async => [u, await client.librarySections(token, userId: u.id)]),
      builder: (context, snap) {
        final loading = snap.connectionState == ConnectionState.waiting;
        final hasError = snap.hasError;
        final user =
            !loading && !hasError ? snap.data![0] as AniListUser : null;
        final sections = !loading && !hasError
            ? snap.data![1] as List<AniListLibrarySection>
            : const <AniListLibrarySection>[];

        final chips = <String>['All', ...sections.map((s) => s.title)];
        final filtered = selected == 'All'
            ? sections
            : sections.where((s) => s.title == selected).toList();

        return RefreshIndicator(
          onRefresh: onRefresh,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 120),
            children: [
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
              SizedBox(
                height: 38,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: chips.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final chip = chips[index];
                    final active = selected == chip;
                    return ChoiceChip(
                      label: Text(chip),
                      selected: active,
                      onSelected: (_) => onSelect(chip),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              if (loading)
                const _LibrarySkeletonBody()
              else if (hasError)
                GlassCard(child: Text('Failed loading library: ${snap.error}'))
              else if (sections.isEmpty)
                const GlassCard(child: Text('No library items found.'))
              else
                ...filtered.map((section) => Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: _LibrarySection(section: section),
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
    return entriesAsync.when(
      loading: () => const _LibrarySkeleton(),
      error: (e, _) => SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 120),
          children: [
            Text('Local Library', style: Theme.of(context).textTheme.displaySmall),
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
              Text('Local Library', style: Theme.of(context).textTheme.displaySmall),
              const Text('Stored on this device',
                  style: TextStyle(color: Color(0xFFA1A8BC))),
              const SizedBox(height: 12),
              if (entries.isEmpty) ...[
                const GlassCard(child: Text('Your local library is empty.')),
                const SizedBox(height: 12),
                GlassButton(
                  onPressed: () {
                    hapticTap();
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const DiscoveryScreen()),
                    );
                  },
                  child: const Text('Browse Discovery to add Anime'),
                ),
              ] else ...[
                SizedBox(
                  height: 38,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: chips.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final chip = chips[index];
                      final active = selected == chip;
                      return ChoiceChip(
                        label: Text(chip),
                        selected: active,
                        onSelected: (_) => onSelect(chip),
                      );
                    },
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
                child: GestureDetector(
                  onTap: () {
                    hapticTap();
                    Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => DetailsScreen(mediaId: entry.mediaId)));
                  },
                  child: _AnimePosterCard(
                    media: media,
                    progressText: progressText,
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

class _LibrarySection extends StatelessWidget {
  const _LibrarySection({required this.section});

  final AniListLibrarySection section;

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
                child: GestureDetector(
                  onTap: () {
                    hapticTap();
                    Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => DetailsScreen(mediaId: e.media.id)));
                  },
                  child: _AnimePosterCard(
                    media: e.media,
                    progressText: _showProgress
                        ? '${e.progress}${e.media.episodes != null ? ' / ${e.media.episodes}' : ''}'
                        : null,
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
  const _AnimePosterCard({required this.media, this.progressText});

  final AniListMedia media;
  final String? progressText;

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
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFA1E1E1E),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.star_rounded, color: Colors.amber, size: 12),
                  const SizedBox(width: 3),
                  Text(media.averageScore?.toString() ?? 'NR',
                      style: const TextStyle(
                          fontSize: 11, fontWeight: FontWeight.w700)),
                ],
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
