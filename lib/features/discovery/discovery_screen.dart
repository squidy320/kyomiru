import 'dart:async';
import 'dart:io';

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
import '../../state/ui_ambient_state.dart';
import '../details/details_screen.dart';

const double _kCardWidth = 152;
const double _kCardHeight = 232;
const Color _kDiscoveryBaseColor = Color(0xFF090B13);
final discoverySearchFocusRequestProvider = StateProvider<int>((ref) => 0);
final discoveryDesktopSearchQueryProvider =
    StateProvider<String?>((ref) => null);

double _phoneHeroHeight(BuildContext context) {
  final w = MediaQuery.sizeOf(context).width;
  return (w * 0.62).clamp(235.0, 320.0);
}

double _phoneCardWidth(BuildContext context) {
  final w = MediaQuery.sizeOf(context).width;
  return (w * 0.38).clamp(138.0, 172.0);
}

double _phoneCardHeight(BuildContext context) {
  final cw = _phoneCardWidth(context);
  return (cw * 1.53).clamp(208.0, 262.0);
}

Route<void> _detailsRoute(int mediaId) {
  return PageRouteBuilder<void>(
    pageBuilder: (_, __, ___) => DetailsScreen(mediaId: mediaId),
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
  );
}

class DiscoveryScreen extends ConsumerStatefulWidget {
  const DiscoveryScreen({super.key});

  @override
  ConsumerState<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends ConsumerState<DiscoveryScreen>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  Timer? _debounce;
  Timer? _heroTimer;

  Future<_DiscoveryPayload>? _discoveryFuture;
  _DiscoveryPayload? _cachedPayload;

  List<AniListMedia> _searchResults = const [];
  bool _searching = false;
  int _heroIndex = 0;
  int _lastFocusRequestTick = -1;
  String? _lastExternalDesktopQuery;
  String? _lastAmbientHeroKey;
  final Map<String, Color> _ambientColorCache = <String, Color>{};

  @override
  void initState() {
    super.initState();
    final cached = ref.read(anilistClientProvider).cachedDiscoverySnapshot();
    if (cached != null) {
      _cachedPayload = _DiscoveryPayload(
        trending: cached.trending,
        sections: cached.sections,
      );
      _startHeroTimer(cached.trending.length);
    }
    _discoveryFuture = _loadDiscovery();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _heroTimer?.cancel();
    _search.dispose();
    _searchFocus.dispose();
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
    return payload;
  }

  void _startHeroTimer(int count) {
    _heroTimer?.cancel();
    if (count <= 1) return;
    _heroTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (!mounted) return;
      final next = (_heroIndex + 1) % count;
      setState(() => _heroIndex = next);
    });
  }

  Future<void> _updateAmbientFromMedia(AniListMedia? media) async {
    if (media == null) return;
    final image = media.bannerImage ?? media.cover.best;
    if (image == null || image.isEmpty) return;
    if (_lastAmbientHeroKey == image) return;
    _lastAmbientHeroKey = image;
    final cached = _ambientColorCache[image];
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
      _ambientColorCache[image] = adjusted;
      if (!mounted) return;
      ref.read(uiAmbientColorProvider.notifier).state = adjusted;
    } catch (_) {}
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
    final focusRequestTick = ref.watch(discoverySearchFocusRequestProvider);
    final externalDesktopQuery = ref.watch(discoveryDesktopSearchQueryProvider);
    if (focusRequestTick != _lastFocusRequestTick) {
      _lastFocusRequestTick = focusRequestTick;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_searchFocus.canRequestFocus) {
          _searchFocus.requestFocus();
        }
      });
    }
    if (externalDesktopQuery != null &&
        externalDesktopQuery != _lastExternalDesktopQuery) {
      _lastExternalDesktopQuery = externalDesktopQuery;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_search.text != externalDesktopQuery) {
          _search.text = externalDesktopQuery;
        }
        _onSearchChanged(externalDesktopQuery);
      });
    }
    final settings = ref.watch(appSettingsProvider);
    final showingSearch = _search.text.trim().isNotEmpty;
    final isWide = MediaQuery.sizeOf(context).width > 600;

    return FutureBuilder<_DiscoveryPayload>(
      future: _discoveryFuture,
      builder: (context, dataSnap) {
        final payload = dataSnap.data ?? _cachedPayload;
        final trending = payload?.trending ?? const <AniListMedia>[];
        final sections = payload?.sections ?? const <AniListDiscoverySection>[];
        final heroPool = trending.take(5).toList();
        final heroMedia =
            heroPool.isEmpty ? null : heroPool[_heroIndex % heroPool.length];
        unawaited(_updateAmbientFromMedia(heroMedia));
        if (isWide) {
          return _buildWideDiscovery(
            context: context,
            settings: settings,
            dataSnap: dataSnap,
            trending: trending,
            heroMedia: heroMedia,
            sections: sections,
            showingSearch: showingSearch,
          );
        }
        const gradientTop = Color(0x4D121520);
        final hasHero = !showingSearch && trending.isNotEmpty;
        final topInset = MediaQuery.viewPaddingOf(context).top;
        final phoneCardW = _phoneCardWidth(context);
        final phoneCardH = _phoneCardHeight(context);
        final heroHeight = _phoneHeroHeight(context);
        final topSlivers = <Widget>[];
        topSlivers.add(
          SliverPadding(
            padding: EdgeInsets.fromLTRB(14, topInset + 8, 14, 0),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Discovery',
                      style: Theme.of(context).textTheme.displaySmall),
                  const SizedBox(height: 4),
                  const Text(
                    'Top rated, new releases, and hot anime',
                    style: TextStyle(color: Color(0xFFA1A8BC)),
                  ),
                ],
              ),
            ),
          ),
        );
        if (hasHero) {
          topSlivers.add(
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(0, 12, 0, 8),
              sliver: SliverToBoxAdapter(
                child: _DiscoveryAnimatedHero(
                  media: heroMedia,
                  height: heroHeight,
                ),
              ),
            ),
          );
        }
        topSlivers.add(
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            sliver: SliverToBoxAdapter(
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
                      focusNode: _searchFocus,
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
                    cardWidth: phoneCardW,
                    cardHeight: phoneCardH,
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
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
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
                padding: const EdgeInsets.fromLTRB(0, 0, 14, 14),
                sliver: SliverToBoxAdapter(
                  child: SizedBox(
                    height: phoneCardH,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: section.items.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 10),
                      itemBuilder: (context, index) {
                        final item = section.items[index];
                        return SizedBox(
                          width: phoneCardW,
                          child: _HoverPosterTile(
                            onTap: () {
                              hapticTap();
                              Navigator.of(context)
                                  .push(_detailsRoute(item.id));
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

  Widget _buildWideDiscovery({
    required BuildContext context,
    required AppSettings settings,
    required AsyncSnapshot<_DiscoveryPayload> dataSnap,
    required List<AniListMedia> trending,
    required AniListMedia? heroMedia,
    required List<AniListDiscoverySection> sections,
    required bool showingSearch,
  }) {
    const gradientTop = Color(0x47121520);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: _kDiscoveryBaseColor,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [gradientTop, _kDiscoveryBaseColor],
        ),
      ),
      child: RefreshIndicator(
        onRefresh: _refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: _WideHeroBanner(
                media: heroMedia,
                onTapHero: heroMedia == null
                    ? null
                    : () =>
                        Navigator.of(context).push(_detailsRoute(heroMedia.id)),
              ),
            ),
            if (!Platform.isWindows)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: GlassContainer(
                    borderRadius: 16,
                    child: TextField(
                      controller: _search,
                      focusNode: _searchFocus,
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
            if (showingSearch)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                  child: _searching
                      ? const _DiscoverySkeleton()
                      : _HorizontalSection(
                          title: 'Search Results',
                          items: _searchResults,
                        ),
                ),
              )
            else ...[
              for (final section in sections.where((s) => s.items.isNotEmpty))
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                    child: _WideCarouselSection(
                      title: section.title,
                      items: section.items,
                    ),
                  ),
                ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 120)),
          ],
        ),
      ),
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

class _DiscoveryAnimatedHero extends StatelessWidget {
  const _DiscoveryAnimatedHero({
    required this.media,
    required this.height,
  });

  final AniListMedia? media;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (media == null) return const SizedBox.shrink();
    final image = media!.bannerImage ?? media!.cover.best;
    final genresText = media!.genres.take(2).join('  ');
    final score = media!.averageScore ?? 78;
    final matchScore = (score + 8).clamp(60, 99);
    final ratingTag = media!.isAdult ? 'R' : 'TV-14';
    final logoCandidate = media!.siteUrl?.contains('anilist.co') == true &&
            (media!.cover.best?.toLowerCase().endsWith('.png') ?? false)
        ? media!.cover.best
        : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
      child: SizedBox(
        height: height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 520),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: Stack(
              key: ValueKey<int>(media!.id),
              fit: StackFit.expand,
              children: [
                if (image != null)
                  KyomiruImageCache.image(image, fit: BoxFit.cover)
                else
                  const ColoredBox(color: Color(0x22111111)),
                const Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Color(0x22090B13),
                          Color(0x8A090B13),
                          _kDiscoveryBaseColor,
                        ],
                        stops: [0.42, 0.68, 0.86, 1.0],
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 20,
                  right: 20,
                  bottom: 22,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (logoCandidate != null)
                        SizedBox(
                          height: 44,
                          child: KyomiruImageCache.image(
                            logoCandidate,
                            fit: BoxFit.contain,
                          ),
                        )
                      else
                        Text(
                          media!.title.best,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 24,
                            height: 1.05,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 10,
                        runSpacing: 6,
                        children: [
                          _HeroMetaPill(
                            icon: Icons.thumb_up_alt_rounded,
                            label: '$matchScore% Match',
                            color: const Color(0xFF22C55E),
                          ),
                          _HeroMetaPill(
                            icon: Icons.star_rounded,
                            label: '${media!.averageScore ?? 0}%',
                            color: const Color(0xFFFFD54F),
                          ),
                          _HeroMetaPill(
                            icon: Icons.shield_rounded,
                            label: ratingTag,
                            color: const Color(0xFF93C5FD),
                          ),
                          if (genresText.isNotEmpty)
                            _HeroMetaPill(
                              icon: Icons.local_offer_rounded,
                              label: genresText,
                              color: Colors.white70,
                            ),
                        ],
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
  }
}

class _HeroMetaPill extends StatelessWidget {
  const _HeroMetaPill({
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
        color: Colors.black.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: color == Colors.white70 ? Colors.white70 : Colors.white,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _HorizontalSection extends StatelessWidget {
  const _HorizontalSection({
    required this.title,
    required this.items,
    this.cardWidth = _kCardWidth,
    this.cardHeight = _kCardHeight,
  });

  final String title;
  final List<AniListMedia> items;
  final double cardWidth;
  final double cardHeight;

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
          height: cardHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final item = items[index];
              return SizedBox(
                width: cardWidth,
                child: _HoverPosterTile(
                  onTap: () {
                    hapticTap();
                    Navigator.of(context).push(_detailsRoute(item.id));
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

class _WideHeroBanner extends StatelessWidget {
  const _WideHeroBanner({
    required this.media,
    this.onTapHero,
  });

  final AniListMedia? media;
  final VoidCallback? onTapHero;

  @override
  Widget build(BuildContext context) {
    final image = media?.bannerImage ?? media?.cover.best;
    final topInset = MediaQuery.viewPaddingOf(context).top;
    final synopsis =
        (media?.description ?? '').replaceAll(RegExp(r'<[^>]*>'), ' ').trim();
    final studio = media?.studios.isNotEmpty == true
        ? media!.studios.first
        : 'Unknown Studio';

    return SizedBox(
      height: 470,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (image != null && image.isNotEmpty)
            GestureDetector(
              onTap: onTapHero,
              child: KyomiruImageCache.image(image, fit: BoxFit.cover),
            )
          else
            const ColoredBox(color: Color(0x22111111)),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x22000000),
                  Color(0x77090B13),
                  Color(0xDD090B13),
                  _kDiscoveryBaseColor,
                ],
                stops: [0.0, 0.56, 0.82, 1.0],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(20, topInset + 20, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Spacer(),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        media?.title.best ?? 'Discovery',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 52,
                          fontWeight: FontWeight.w800,
                          height: 0.95,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '${media?.episodes ?? '-'} EPS  •  $studio  •  ${media?.averageScore ?? 0}%',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        synopsis.isEmpty
                            ? 'Browse trending and top rated anime.'
                            : synopsis,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          color: Colors.white70,
                          height: 1.3,
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

class _WideCarouselSection extends StatelessWidget {
  const _WideCarouselSection({
    required this.title,
    required this.items,
  });

  final String title;
  final List<AniListMedia> items;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final crossAxisCount = (width / 220).floor().clamp(3, 8);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: items.length,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                crossAxisSpacing: 14,
                mainAxisSpacing: 14,
                childAspectRatio: 220 / 302,
              ),
              itemBuilder: (context, index) {
                final item = items[index];
                return _HoverPosterTile(
                  onTap: () {
                    hapticTap();
                    Navigator.of(context).push(_detailsRoute(item.id));
                  },
                  child: _AnimePosterCard(media: item),
                );
              },
            ),
          ],
        );
      },
    );
  }
}
