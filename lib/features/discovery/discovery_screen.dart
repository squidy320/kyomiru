import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:shimmer/shimmer.dart';

import '../../core/glass_widgets.dart';
import '../../core/haptics.dart';
import '../../core/image_cache.dart';
import '../../models/anilist_models.dart';
import '../../state/auth_state.dart';
import '../details/details_screen.dart';

const double _kCardWidth = 152;
const double _kCardHeight = 232;

class DiscoveryScreen extends ConsumerStatefulWidget {
  const DiscoveryScreen({super.key});

  @override
  ConsumerState<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends ConsumerState<DiscoveryScreen>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _search = TextEditingController();
  final PageController _heroController = PageController();

  Timer? _debounce;
  Timer? _heroTimer;

  Future<_DiscoveryPayload>? _discoveryFuture;
  _DiscoveryPayload? _cachedPayload;

  List<AniListMedia> _searchResults = const [];
  bool _searching = false;
  int _heroIndex = 0;
  Color _backgroundSeed = const Color(0xFF0A0D18);
  final Map<String, Color> _paletteCache = <String, Color>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _discoveryFuture = _loadDiscovery();
      });
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _heroTimer?.cancel();
    _heroController.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() {
      _discoveryFuture = _loadDiscovery();
    });
    await _discoveryFuture;
  }

  Future<_DiscoveryPayload> _loadDiscovery() async {
    final client = ref.read(anilistClientProvider);
    final values = await Future.wait([
      client.discoveryTrending(),
      client.discoverySections(),
    ]);
    final payload = _DiscoveryPayload(
      trending: values[0] as List<AniListMedia>,
      sections: values[1] as List<AniListDiscoverySection>,
    );
    _cachedPayload = payload;
    _startHeroTimer(payload.trending.length);
    unawaited(_updateBackgroundForTrending(payload.trending, 0));
    return payload;
  }

  Future<void> _updateBackgroundForTrending(
      List<AniListMedia> trending, int index) async {
    if (trending.isEmpty || index < 0 || index >= trending.length) return;
    final media = trending[index];
    final image = media.bannerImage ?? media.cover.best;
    if (image == null || image.isEmpty) return;

    final cached = _paletteCache[image];
    if (cached != null) {
      if (!mounted) return;
      setState(() => _backgroundSeed = cached);
      return;
    }

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
      _paletteCache[image] = picked;
      if (!mounted) return;
      setState(() => _backgroundSeed = picked);
    } catch (_) {}
  }

  void _startHeroTimer(int count) {
    _heroTimer?.cancel();
    if (count <= 1) return;
    _heroTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!mounted || !_heroController.hasClients) return;
      final next = (_heroIndex + 1) % count;
      _heroController.animateToPage(
        next,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOut,
      );
    });
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () async {
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

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final showingSearch = _search.text.trim().isNotEmpty;

    return FutureBuilder<_DiscoveryPayload>(
      future: _discoveryFuture,
      builder: (context, dataSnap) {
        final payload = dataSnap.data ?? _cachedPayload;
        final trending = payload?.trending ?? const <AniListMedia>[];
        final sections = payload?.sections ?? const <AniListDiscoverySection>[];
        final gradientTop = _backgroundSeed.withValues(alpha: 0.30);

        final topContent = <Widget>[
          Text('Discovery', style: Theme.of(context).textTheme.displaySmall),
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
                          hapticTap();
                          _search.clear();
                          setState(() => _searchResults = const []);
                        },
                        icon: const Icon(Icons.close),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ];
        final listContent = <Widget>[];

        if (showingSearch) {
          if (_searching) {
            listContent.add(const _DiscoverySkeleton());
          } else if (_searchResults.isEmpty) {
            listContent.add(const GlassCard(child: Text('No results.')));
          } else {
            listContent.add(
              _HorizontalSection(
                  title: 'Search Results', items: _searchResults),
            );
          }
        } else {
          if ((_discoveryFuture == null ||
                  dataSnap.connectionState == ConnectionState.waiting) &&
              payload == null) {
            listContent.add(const _DiscoverySkeleton());
          } else if (dataSnap.hasError && payload == null) {
            listContent.add(
              GlassCard(
                  child: Text('Discovery load failed: ${dataSnap.error}')),
            );
          } else {
            for (final section in sections) {
              listContent.add(
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: _HorizontalSection(
                    title: section.title,
                    items: section.items,
                  ),
                ),
              );
            }
          }
        }

        return LiquidGlassLayer(
          settings: const LiquidGlassSettings(
            blur: 25,
            thickness: 15,
            refractiveIndex: 1.2,
            saturation: 1.6,
            glassColor: Color.fromRGBO(255, 255, 255, 0.05),
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  gradientTop,
                  const Color(0xFF090B13),
                ],
              ),
            ),
            child: SafeArea(
              child: RefreshIndicator(
                onRefresh: _refresh,
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
                      sliver: SliverList(
                        delegate: SliverChildListDelegate(topContent),
                      ),
                    ),
                    if (!showingSearch && trending.isNotEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 16),
                          child: _DiscoveryHeroCarousel(
                            items: trending,
                            controller: _heroController,
                            onPageChanged: (index) {
                              setState(() => _heroIndex = index);
                              unawaited(_updateBackgroundForTrending(
                                  trending, index));
                            },
                          ),
                        ),
                      ),
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
                      sliver: SliverList(
                        delegate: SliverChildListDelegate(listContent),
                      ),
                    ),
                    const SliverPadding(
                      padding: EdgeInsets.only(bottom: 120),
                      sliver: SliverToBoxAdapter(child: SizedBox.shrink()),
                    ),
                  ],
                ),
              ),
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
      height: 340,
      child: ClipRRect(
        borderRadius: BorderRadius.zero,
        child: PageView.builder(
          controller: controller,
          itemCount: items.length,
          onPageChanged: onPageChanged,
          itemBuilder: (context, index) {
            final media = items[index];
            final image = media.bannerImage ?? media.cover.best;
            return GestureDetector(
              onTap: () {
                hapticTap();
                Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => DetailsScreen(mediaId: media.id)),
                );
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (image != null)
                    KyomiruImageCache.image(image, fit: BoxFit.cover)
                  else
                    const ColoredBox(color: Color(0x22111111)),
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.9),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 12,
                    left: 12,
                    child: LiquidGlass(
                      shape: const LiquidRoundedSuperellipse(borderRadius: 999),
                      child: const Padding(
                        padding:
                            EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        child: Text('Trending Now',
                            style: TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 12)),
                      ),
                    ),
                  ),
                  Positioned(
                      top: 12,
                      right: 12,
                      child: _ScorePill(score: media.averageScore)),
                  Positioned(
                    left: 14,
                    right: 14,
                    bottom: 14,
                    child: Text(
                      media.title.best,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 26,
                          height: 1.1,
                          fontWeight: FontWeight.w700),
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
    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
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
                  onTap: () {
                    hapticTap();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => DetailsScreen(mediaId: item.id)),
                    );
                  },
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
          Positioned(
              top: 8, right: 8, child: _ScorePill(score: media.averageScore)),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Text(
                media.title.best,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScorePill extends StatelessWidget {
  const _ScorePill({required this.score});

  final int? score;

  @override
  Widget build(BuildContext context) {
    return LiquidGlass(
      shape: const LiquidRoundedSuperellipse(borderRadius: 999),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        child: Row(
          children: [
            const Icon(Icons.star_rounded, color: Colors.amber, size: 12),
            const SizedBox(width: 3),
            Text(score?.toString() ?? 'NR',
                style:
                    const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}

class _DiscoverySkeleton extends StatelessWidget {
  const _DiscoverySkeleton();

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
              width: 190,
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10))),
          const SizedBox(height: 10),
          Container(
              height: 180,
              decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18))),
          const SizedBox(height: 12),
          for (var i = 0; i < 2; i++) ...[
            Container(
                height: 22,
                width: 160,
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
                              borderRadius: BorderRadius.circular(16))),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
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
