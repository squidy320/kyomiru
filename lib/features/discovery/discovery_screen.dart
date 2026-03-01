import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:shimmer/shimmer.dart';

import '../../core/glass_widgets.dart';
import '../../core/haptics.dart';
import '../../core/image_cache.dart';
import '../../core/liquid_glass_preset.dart';
import '../../models/anilist_models.dart';
import '../../state/app_settings_state.dart';
import '../../state/auth_state.dart';
import '../details/details_screen.dart';

const double _kCardWidth = 152;
const double _kCardHeight = 232;
const Color _kDiscoveryBaseColor = Color(0xFF090B13);

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
    final settings = ref.watch(appSettingsProvider);
    final showingSearch = _search.text.trim().isNotEmpty;

    return FutureBuilder<_DiscoveryPayload>(
      future: _discoveryFuture,
      builder: (context, dataSnap) {
        final payload = dataSnap.data ?? _cachedPayload;
        final trending = payload?.trending ?? const <AniListMedia>[];
        final sections = payload?.sections ?? const <AniListDiscoverySection>[];
        final gradientTop = _backgroundSeed.withValues(alpha: 0.30);
        final hasHero = !showingSearch && trending.isNotEmpty;
        final topInset = MediaQuery.viewPaddingOf(context).top;
        final topSlivers = <Widget>[];
        if (hasHero) {
          topSlivers.add(
            SliverToBoxAdapter(
              child: _DiscoveryHeroCarousel(
                items: trending,
                controller: _heroController,
                onPageChanged: (index) {
                  setState(() => _heroIndex = index);
                  unawaited(_updateBackgroundForTrending(trending, index));
                },
              ),
            ),
          );
        }
        topSlivers.add(
          SliverPersistentHeader(
            floating: true,
            pinned: true,
            delegate: _FixedExtentHeaderDelegate(
              extent: topInset + 74,
              child: Container(
                color: Colors.transparent,
                padding: EdgeInsets.fromLTRB(14, topInset + 8, 14, 8),
                child: LiquidGlass.withOwnLayer(
                  settings: kyomiruLiquidGlassSettings(
                    isOledBlack: settings.isOledBlack,
                  ),
                  shape: const LiquidRoundedSuperellipse(borderRadius: 14),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.10),
                      ),
                    ),
                    child: Padding(
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
                  ),
                ),
              ),
            ),
          ),
        );
        topSlivers.add(
          SliverPadding(
            padding: EdgeInsets.fromLTRB(14, hasHero ? 0 : 10, 14, 10),
            sliver: SliverToBoxAdapter(
              child: Transform.translate(
                offset: Offset(0, hasHero ? -54 : 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Discovery',
                        style: Theme.of(context).textTheme.displaySmall),
                    const SizedBox(height: 4),
                    const Text(
                      'Top Rated',
                      style: TextStyle(color: Color(0xFFA1A8BC)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        if (showingSearch) {
          if (_searching) {
            topSlivers.add(
              const SliverPadding(
                padding: EdgeInsets.fromLTRB(14, 0, 14, 0),
                sliver: SliverToBoxAdapter(child: _DiscoverySkeleton()),
              ),
            );
          } else if (_searchResults.isEmpty) {
            topSlivers.add(
              const SliverPadding(
                padding: EdgeInsets.fromLTRB(14, 0, 14, 0),
                sliver: SliverToBoxAdapter(
                  child: GlassCard(child: Text('No results.')),
                ),
              ),
            );
          } else {
            topSlivers.add(
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                sliver: SliverToBoxAdapter(
                  child: _HorizontalSection(
                    title: 'Search Results',
                    items: _searchResults,
                  ),
                ),
              ),
            );
          }
        } else if ((_discoveryFuture == null ||
                dataSnap.connectionState == ConnectionState.waiting) &&
            payload == null) {
          topSlivers.add(
            const SliverPadding(
              padding: EdgeInsets.fromLTRB(14, 0, 14, 0),
              sliver: SliverToBoxAdapter(child: _DiscoverySkeleton()),
            ),
          );
        } else if (dataSnap.hasError && payload == null) {
          topSlivers.add(
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
              sliver: SliverToBoxAdapter(
                child: GlassCard(
                  child: Text('Discovery load failed: ${dataSnap.error}'),
                ),
              ),
            ),
          );
        } else {
          final sectionSlivers = <Widget>[];
          for (final section in sections) {
            if (section.items.isEmpty) continue;
            sectionSlivers.addAll([
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                sliver: SliverPersistentHeader(
                  pinned: false,
                  delegate: _FixedExtentHeaderDelegate(
                    extent: 38,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        section.title,
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                sliver: SliverToBoxAdapter(
                  child: SizedBox(
                    height: _kCardHeight,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: section.items.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 10),
                      itemBuilder: (context, index) {
                        final item = section.items[index];
                        return SizedBox(
                          width: _kCardWidth,
                          child: _HoverPosterTile(
                            onTap: () {
                              hapticTap();
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      DetailsScreen(mediaId: item.id),
                                ),
                              );
                            },
                            child: _AnimePosterCard(media: item),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ]);
          }
          topSlivers.addAll(sectionSlivers);
        }

        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: const SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.light,
            statusBarBrightness: Brightness.dark,
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              color: _kDiscoveryBaseColor,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  gradientTop,
                  _kDiscoveryBaseColor,
                ],
                stops: const [0.0, 1.0],
              ),
            ),
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: CustomScrollView(
                shrinkWrap: false,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  ...topSlivers,
                  const SliverPadding(
                    padding: EdgeInsets.only(bottom: 120),
                    sliver: SliverToBoxAdapter(child: SizedBox.shrink()),
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

class _FixedExtentHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _FixedExtentHeaderDelegate({
    required this.extent,
    required this.child,
  });

  final double extent;
  final Widget child;

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return RepaintBoundary(
      child: child,
    );
  }

  @override
  bool shouldRebuild(covariant _FixedExtentHeaderDelegate oldDelegate) {
    return extent != oldDelegate.extent || child != oldDelegate.child;
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
    final bannerHeight =
        (MediaQuery.sizeOf(context).height * 0.52).clamp(360.0, 560.0);
    return SizedBox(
      height: bannerHeight,
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
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.transparent,
                          Color(0x40090B13),
                          Color(0x80090B13),
                          Color(0xD8090B13),
                          _kDiscoveryBaseColor,
                        ],
                        stops: [0.0, 0.42, 0.62, 0.78, 0.90, 1.0],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 10,
                  child: Container(
                    height: 96,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.white.withValues(alpha: 0.05),
                          Colors.black.withValues(alpha: 0.22),
                        ],
                      ),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.10),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const LiquidGlass(
                              shape: LiquidRoundedSuperellipse(
                                borderRadius: 999,
                              ),
                              child: Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 5,
                                ),
                                child: Text(
                                  'Trending Now',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ),
                            const Spacer(),
                            _ScorePill(score: media.averageScore),
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
                              fontSize: 26,
                              height: 1.1,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
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
                child: _HoverPosterTile(
                  onTap: () {
                    hapticTap();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => DetailsScreen(mediaId: item.id),
                      ),
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
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Spacer(),
                      _ScorePill(score: media.averageScore),
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
                ],
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xE61A1A1A),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Row(
        children: [
          const Icon(Icons.star_rounded, color: Colors.amber, size: 12),
          const SizedBox(width: 3),
          Text(
            score?.toString() ?? 'NR',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Colors.white,
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
        child: GestureDetector(
          onTap: widget.onTap,
          child: widget.child,
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
