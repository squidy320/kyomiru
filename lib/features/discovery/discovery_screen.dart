import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:palette_generator/palette_generator.dart';

import '../../core/glass_widgets.dart';
import '../../core/theme/app_theme.dart';
import '../../models/anilist_models.dart';
import '../../state/auth_state.dart';
import '../details/details_screen.dart';

const double _kCardWidth = 156;
const double _kCardHeight = 236;

class DiscoveryScreen extends ConsumerStatefulWidget {
  const DiscoveryScreen({super.key});

  @override
  ConsumerState<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends ConsumerState<DiscoveryScreen> {
  final TextEditingController _search = TextEditingController();
  final PageController _heroController = PageController(viewportFraction: 1);
  final Map<int, Color> _heroColorCache = {};

  Timer? _debounce;
  Timer? _heroTimer;

  List<AniListMedia> _searchResults = const [];
  bool _searching = false;
  int _heroIndex = 0;
  Color _heroTint = const Color(0xFF1A2238);

  @override
  void dispose() {
    _debounce?.cancel();
    _heroTimer?.cancel();
    _heroController.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 260), () async {
      if (!mounted) return;
      if (value.trim().isEmpty) {
        setState(() {
          _searchResults = const [];
          _searching = false;
        });
        return;
      }
      setState(() => _searching = true);
      try {
        final items =
            await ref.read(anilistClientProvider).searchAnime(value.trim());
        if (!mounted) return;
        setState(() {
          _searchResults = items;
          _searching = false;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() => _searching = false);
      }
    });
  }

  void _syncHero(List<AniListMedia> trending) {
    if (trending.isEmpty) {
      _heroTimer?.cancel();
      return;
    }
    if (_heroIndex >= trending.length) {
      _heroIndex = 0;
    }
    _ensureHeroTint(trending[_heroIndex]);
    _startHeroTimer(trending.length);
  }

  void _startHeroTimer(int count) {
    _heroTimer?.cancel();
    if (count <= 1) return;
    _heroTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || !_heroController.hasClients) return;
      final next = (_heroIndex + 1) % count;
      _heroController.animateToPage(
        next,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _ensureHeroTint(AniListMedia media) async {
    final cached = _heroColorCache[media.id];
    if (cached != null) {
      if (!mounted) return;
      setState(() => _heroTint = cached);
      return;
    }

    final image = media.bannerImage ?? media.cover.best;
    if (image == null || image.isEmpty) return;

    try {
      final palette = await PaletteGenerator.fromImageProvider(
        NetworkImage(image),
        size: const Size(96, 96),
        maximumColorCount: 12,
      );
      final color = palette.vibrantColor?.color ??
          palette.dominantColor?.color ??
          palette.darkMutedColor?.color ??
          const Color(0xFF1A2238);
      _heroColorCache[media.id] = color;
      if (!mounted) return;
      setState(() => _heroTint = color);
    } catch (_) {
      // Ignore palette failures; keep current tint.
    }
  }

  @override
  Widget build(BuildContext context) {
    final client = ref.watch(anilistClientProvider);
    final showingSearch = _search.text.trim().isNotEmpty;

    return FutureBuilder<_DiscoveryPayload>(
      future: Future.wait([
        client.discoveryTrending(),
        client.discoverySections(),
      ]).then((v) => _DiscoveryPayload(
          trending: v[0] as List<AniListMedia>,
          sections: v[1] as List<AniListDiscoverySection>)),
      builder: (context, dataSnap) {
        final payload = dataSnap.data;
        final trending = payload?.trending ?? const <AniListMedia>[];
        final sections = payload?.sections ?? const <AniListDiscoverySection>[];

        if (payload != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _syncHero(trending);
          });
        }

        return SafeArea(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 280),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  _heroTint.withValues(alpha: 0.36),
                  AppColors.background,
                  AppColors.background,
                ],
                stops: const [0, 0.45, 1],
              ),
            ),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 100),
              children: [
                const Text('Discovery',
                    style:
                        TextStyle(fontSize: 34, fontWeight: FontWeight.w900)),
                const SizedBox(height: 4),
                const Text('Top rated, new releases, and hot anime',
                    style: TextStyle(color: Color(0xFFA1A8BC))),
                const SizedBox(height: 10),
                GlassCard(
                  padding: const EdgeInsets.all(8),
                  child: TextField(
                    controller: _search,
                    onChanged: _onSearchChanged,
                    decoration: InputDecoration(
                      hintText: 'Search anime...',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _search.text.isEmpty
                          ? null
                          : IconButton(
                              onPressed: () {
                                _search.clear();
                                setState(() => _searchResults = const []);
                              },
                              icon: const Icon(Icons.close),
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (showingSearch) ...[
                  if (_searching)
                    const Center(child: CircularProgressIndicator())
                  else if (_searchResults.isEmpty)
                    const GlassCard(child: Text('No results.'))
                  else
                    _HorizontalSection(
                      title: 'Search Results',
                      items: _searchResults,
                    ),
                ] else ...[
                  if (dataSnap.connectionState == ConnectionState.waiting)
                    const Center(child: CircularProgressIndicator())
                  else if (dataSnap.hasError)
                    GlassCard(
                        child: Text('Discovery load failed: ${dataSnap.error}'))
                  else ...[
                    if (trending.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: _DiscoveryHeroCarousel(
                          items: trending,
                          controller: _heroController,
                          onPageChanged: (index) {
                            setState(() => _heroIndex = index);
                            _ensureHeroTint(trending[index]);
                          },
                        ),
                      ),
                    for (final section in sections)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: _HorizontalSection(
                          title: section.title,
                          items: section.items,
                        ),
                      ),
                  ],
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DiscoveryHeroCarousel extends StatelessWidget {
  const _DiscoveryHeroCarousel({
    required this.items,
    required this.controller,
    required this.onPageChanged,
  });

  final List<AniListMedia> items;
  final PageController controller;
  final ValueChanged<int> onPageChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 330,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: PageView.builder(
          controller: controller,
          itemCount: items.length,
          onPageChanged: onPageChanged,
          itemBuilder: (context, index) {
            final media = items[index];
            final image = media.bannerImage ?? media.cover.best;
            return GestureDetector(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DetailsScreen(mediaId: media.id),
                ),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (image != null)
                    Image.network(image, fit: BoxFit.cover)
                  else
                    const ColoredBox(color: Color(0x22111111)),
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x11000000), Color(0xE60A0F1C)],
                        stops: [0.38, 1],
                      ),
                    ),
                  ),
                  Positioned(
                    top: 14,
                    left: 14,
                    child: GlassContainer(
                      borderRadius: 999,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      child: const Text(
                        'Trending Now',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 14,
                    right: 14,
                    child: GlassContainer(
                      borderRadius: 999,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      child: Row(
                        children: [
                          const Icon(Icons.star_rounded,
                              size: 14, color: Colors.amber),
                          const SizedBox(width: 4),
                          Text(
                            media.averageScore?.toString() ?? 'NR',
                            style: const TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 14,
                    right: 14,
                    bottom: 16,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          media.title.best,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 31,
                            height: 1,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 8),
                        GlassContainer(
                          borderRadius: 14,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 9),
                          child: const Text(
                            'Open Details',
                            style: TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 14),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _HorizontalSection extends StatelessWidget {
  const _HorizontalSection({required this.title, required this.items});

  final String title;
  final List<AniListMedia> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: _kCardHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final item = items[index];
              return SizedBox(
                width: _kCardWidth,
                child: GestureDetector(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => DetailsScreen(mediaId: item.id)),
                  ),
                  child: _AnimePosterCard(media: item),
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
  const _AnimePosterCard({required this.media});

  final AniListMedia media;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (media.cover.best != null)
            Image.network(media.cover.best!, fit: BoxFit.cover)
          else
            Container(color: const Color(0x22111111)),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Color(0xD80B0F1D)],
                stops: [0.52, 1],
              ),
            ),
          ),
          Positioned(
            top: 10,
            right: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xD8000000),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                media.averageScore?.toString() ?? 'NR',
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Text(
              media.title.best,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 20),
            ),
          ),
        ],
      ),
    );
  }
}

class _DiscoveryPayload {
  const _DiscoveryPayload({required this.trending, required this.sections});

  final List<AniListMedia> trending;
  final List<AniListDiscoverySection> sections;
}
