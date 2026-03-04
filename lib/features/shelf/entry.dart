import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/glass_widgets.dart';
import '../../core/haptics.dart';
import '../../core/image_cache.dart';
import '../../features/auth/anilist_login_webview_screen.dart';
import '../../features/details/details_screen.dart';
import '../../models/anilist_models.dart';
import '../../state/auth_state.dart';

Route<void> _detailsRoute(int mediaId) {
  return PageRouteBuilder<void>(
    pageBuilder: (_, __, ___) => DetailsScreen(mediaId: mediaId),
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
  );
}

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  String _selected = 'All';
  int _heroIndex = 0;
  Timer? _heroTimer;
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _heroTimer?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _startHeroTimer(int count) {
    _heroTimer?.cancel();
    if (count <= 1) return;
    _heroTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!mounted) return;
      setState(() => _heroIndex = (_heroIndex + 1) % count);
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    if (auth.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (auth.token == null || auth.token!.isEmpty) {
      return SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
          children: [
            const GlassCard(
              child: Text('Connect AniList to load your library and tracking.'),
            ),
            const SizedBox(height: 10),
            GlassButton(
              onPressed: () {
                hapticTap();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const AniListLoginWebViewScreen(),
                  ),
                );
              },
              child: const Text('Connect AniList'),
            ),
          ],
        ),
      );
    }

    final token = auth.token!;
    final client = ref.watch(anilistClientProvider);
    return FutureBuilder<List<dynamic>>(
      future: client.me(token).then(
            (u) async => [u, await client.librarySections(token, userId: u.id)],
          ),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError || snap.data == null) {
          return Center(child: Text('Failed loading library: ${snap.error}'));
        }
        final user = snap.data![0] as AniListUser;
        final sections = snap.data![1] as List<AniListLibrarySection>;
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
        final heroPool = (watching.isNotEmpty ? watching : planning)
            .map((e) => e.media)
            .toList();
        _startHeroTimer(heroPool.length);
        final hero = heroPool.isEmpty ? null : heroPool[_heroIndex % heroPool.length];

        final chips = <String>['All', ...sections.map((s) => s.title)];
        final filteredByChip = _selected == 'All'
            ? sections
            : sections.where((s) => s.title == _selected).toList();
        final query = _search.text.trim().toLowerCase();
        final filtered = query.isEmpty
            ? filteredByChip
            : filteredByChip
                .map(
                  (s) => AniListLibrarySection(
                    title: s.title,
                    items: s.items
                        .where((i) => i.media.title.best.toLowerCase().contains(query))
                        .toList(),
                  ),
                )
                .where((s) => s.items.isNotEmpty)
                .toList();

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
          children: [
            _LibraryHero(media: hero),
            const SizedBox(height: 10),
            GlassContainer(
              borderRadius: 16,
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Search in library...',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          onPressed: () {
                            _search.clear();
                            setState(() {});
                          },
                          icon: const Icon(Icons.close),
                        ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: chips.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final chip = chips[i];
                  final active = chip == _selected;
                  return ChoiceChip(
                    label: Text(chip),
                    selected: active,
                    onSelected: (_) => setState(() => _selected = chip),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text(
                  'Currently Watching',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
                ),
                const Spacer(),
                if (user.avatar != null)
                  CircleAvatar(
                    radius: 16,
                    backgroundImage: KyomiruImageCache.provider(user.avatar!),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            _ShelfRow(items: watching.map((e) => e.media).toList()),
            const SizedBox(height: 12),
            for (final section in filtered) ...[
              Text(
                section.title,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 8),
              _ShelfRow(items: section.items.map((e) => e.media).toList()),
              const SizedBox(height: 12),
            ],
          ],
        );
      },
    );
  }
}

class _LibraryHero extends StatelessWidget {
  const _LibraryHero({required this.media});

  final AniListMedia? media;

  @override
  Widget build(BuildContext context) {
    final image = media?.bannerImage ?? media?.cover.best;
    return SizedBox(
      height: 250,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 500),
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
                      Color(0x35000000),
                      Color(0x98090B13),
                      Color(0xFF090B13),
                    ],
                    stops: [0.0, 0.56, 0.82, 1.0],
                  ),
                ),
              ),
              Positioned(
                left: 14,
                right: 14,
                bottom: 14,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Library',
                      style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
                    ),
                    const Text(
                      'Your current and planned anime',
                      style: TextStyle(color: Color(0xFFA1A8BC)),
                    ),
                    if (media != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        media!.title.best,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
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

class _ShelfRow extends StatelessWidget {
  const _ShelfRow({required this.items});

  final List<AniListMedia> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const GlassCard(child: Text('No items in this section.'));
    }
    return SizedBox(
      height: 232,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final media = items[index];
          return SizedBox(
            width: 152,
            child: GestureDetector(
              onTap: () {
                hapticTap();
                Navigator.of(context).push(_detailsRoute(media.id));
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (media.cover.best != null)
                      KyomiruImageCache.image(media.cover.best!, fit: BoxFit.cover)
                    else
                      const ColoredBox(color: Color(0x22111111)),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Color(0xD0000000)],
                          stops: [0.56, 1],
                        ),
                      ),
                    ),
                    Positioned(
                      left: 8,
                      right: 8,
                      bottom: 8,
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
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

