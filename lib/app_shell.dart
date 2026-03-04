import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shimmer/shimmer.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

import 'core/glass_widgets.dart';
import 'core/haptics.dart';
import 'core/image_cache.dart';
import 'core/liquid_glass_preset.dart';
import 'core/theme/app_theme.dart';
import 'features/details/details_screen.dart';
import 'features/discovery/discovery_screen.dart';
import 'features/downloads/downloads_screen.dart';
import 'features/settings/settings_screen.dart';
import 'models/anilist_models.dart';
import 'state/app_settings_state.dart';
import 'state/auth_state.dart';

class KyomiruApp extends ConsumerWidget {
  const KyomiruApp({super.key, required this.liquidGlassEnabled});

  final bool liquidGlassEnabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'kyomiru',
      theme: buildKyomiruTheme(settings),
      builder: (context, child) {
        final routedChild = child ?? const SizedBox.shrink();
        final shortestSide = MediaQuery.sizeOf(context).shortestSide;
        final isIosTablet = Platform.isIOS && shortestSide >= 600;
        final enableLiquidLayer = liquidGlassEnabled && !isIosTablet;
        if (!enableLiquidLayer) {
          return routedChild;
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final validBounds = constraints.hasBoundedWidth &&
                constraints.hasBoundedHeight &&
                constraints.maxWidth.isFinite &&
                constraints.maxHeight.isFinite &&
                constraints.maxWidth > 0 &&
                constraints.maxHeight > 0;
            if (!validBounds) {
              return _BasicGlassFallback(child: routedChild);
            }
            return LiquidGlassLayer(
              settings:
                  kyomiruLiquidGlassSettings(isOledBlack: settings.isOledBlack),
              child: RepaintBoundary(child: routedChild),
            );
          },
        );
      },
      home: AppTabs(liquidGlassEnabled: liquidGlassEnabled),
    );
  }
}

class _BasicGlassFallback extends StatelessWidget {
  const _BasicGlassFallback({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        IgnorePointer(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 0.1, sigmaY: 0.1),
            child: const SizedBox.expand(),
          ),
        ),
      ],
    );
  }
}

class AppTabs extends ConsumerStatefulWidget {
  const AppTabs({super.key, required this.liquidGlassEnabled});

  final bool liquidGlassEnabled;

  @override
  ConsumerState<AppTabs> createState() => _AppTabsState();
}

class _AppTabsState extends ConsumerState<AppTabs> {
  int _index = 0;
  int _lastServerUnread = 0;
  bool _alertsSeenForCurrentUnread = false;
  bool _offlineMode = false;
  _DockEdge _wideDockEdge = _DockEdge.left;
  double _wideDockFactor = 0.34;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  ProviderSubscription<AuthState>? _authSub;

  static const _pages = <Widget>[
    _UnifiedLibraryTab(),
    DiscoveryScreen(),
    NotificationsScreen(),
    DownloadsScreen(),
    SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    _initConnectivity();
    _authSub = ref.listenManual<AuthState>(
      authControllerProvider,
      (previous, next) {
        final token = next.token;
        if (token != null && token.isNotEmpty) {
          unawaited(_warmContinueWatchingNotifiers(token));
        }
      },
      fireImmediately: true,
    );
  }

  Future<void> _warmContinueWatchingNotifiers(String token) async {
    try {
      if (!Hive.isBoxOpen('watch_history')) return;
      final box = Hive.box('watch_history');
      final mediaIds = <int>{};
      for (final key in box.keys) {
        final raw = box.get(key);
        if (raw is! Map) continue;
        final mediaId = (raw['mediaId'] as num?)?.toInt();
        if (mediaId != null && mediaId > 0) mediaIds.add(mediaId);
      }
      final client = ref.read(anilistClientProvider);
      for (final mediaId in mediaIds) {
        unawaited(client.episodeAvailability(token, mediaId));
      }
    } catch (_) {}
  }

  Future<void> _initConnectivity() async {
    try {
      final now = await Connectivity()
          .checkConnectivity()
          .timeout(const Duration(seconds: 2));
      _applyConnectivity(now);
      _connectivitySub =
          Connectivity().onConnectivityChanged.listen(_applyConnectivity);
    } catch (_) {
      if (!mounted) return;
      setState(() => _offlineMode = true);
    }
  }

  void _applyConnectivity(List<ConnectivityResult> results) {
    final offline =
        results.isEmpty || results.every((r) => r == ConnectivityResult.none);
    if (!mounted) return;
    if (offline) {
      setState(() {
        _offlineMode = true;
        _index = 3;
      });
      return;
    }
    if (_offlineMode) {
      setState(() => _offlineMode = false);
    }
  }

  void _onItemTapped(int value) {
    hapticTap();
    setState(() {
      _index = value;
      if (value == 2) {
        _alertsSeenForCurrentUnread = true;
      }
    });
  }

  void _openSearch() {
    _onItemTapped(1);
    ref.read(discoverySearchFocusRequestProvider.notifier).state++;
  }

  Rect _wideDockRect(Size size, EdgeInsets viewPadding) {
    final vertical = _wideDockEdge == _DockEdge.left || _wideDockEdge == _DockEdge.right;
    const verticalWidth = 74.0;
    const verticalHeight = 368.0;
    const horizontalHeight = 74.0;
    const horizontalWidth = 358.0;
    final dockW = vertical ? verticalWidth : horizontalWidth;
    final dockH = vertical ? verticalHeight : horizontalHeight;
    final leftBound = viewPadding.left + 12;
    final topBound = viewPadding.top + 12;
    final rightBound = size.width - viewPadding.right - dockW - 12;
    final bottomBound = size.height - viewPadding.bottom - dockH - 12;
    final xRange = (rightBound - leftBound).clamp(0, double.infinity);
    final yRange = (bottomBound - topBound).clamp(0, double.infinity);

    switch (_wideDockEdge) {
      case _DockEdge.left:
        return Rect.fromLTWH(
          leftBound,
          topBound + (yRange * _wideDockFactor),
          dockW,
          dockH,
        );
      case _DockEdge.right:
        return Rect.fromLTWH(
          rightBound,
          topBound + (yRange * _wideDockFactor),
          dockW,
          dockH,
        );
      case _DockEdge.top:
        return Rect.fromLTWH(
          leftBound + (xRange * _wideDockFactor),
          topBound,
          dockW,
          dockH,
        );
      case _DockEdge.bottom:
        return Rect.fromLTWH(
          leftBound + (xRange * _wideDockFactor),
          bottomBound,
          dockW,
          dockH,
        );
    }
  }

  void _snapDockFromGlobal(
    DraggableDetails details,
    BuildContext context,
    Size size,
    EdgeInsets viewPadding,
  ) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final dropLocal = box.globalToLocal(details.offset);
    final dx = dropLocal.dx;
    final dy = dropLocal.dy;
    final distLeft = dx;
    final distRight = size.width - dx;
    final distTop = dy;
    final distBottom = size.height - dy;
    final minDist = [distLeft, distRight, distTop, distBottom]
        .reduce((a, b) => a < b ? a : b);

    _DockEdge edge;
    if (minDist == distLeft) {
      edge = _DockEdge.left;
    } else if (minDist == distRight) {
      edge = _DockEdge.right;
    } else if (minDist == distTop) {
      edge = _DockEdge.top;
    } else {
      edge = _DockEdge.bottom;
    }

    final vertical = edge == _DockEdge.left || edge == _DockEdge.right;
    final factor = vertical
        ? ((dy - viewPadding.top) /
                (size.height - viewPadding.top - viewPadding.bottom - 368))
            .clamp(0.0, 1.0)
        : ((dx - viewPadding.left) /
                (size.width - viewPadding.left - viewPadding.right - 358))
            .clamp(0.0, 1.0);

    setState(() {
      _wideDockEdge = edge;
      _wideDockFactor = factor.isFinite ? factor : 0.34;
    });
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    _authSub?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    final unread = ref.watch(unreadAlertsProvider).valueOrNull ?? 0;

    if (unread > _lastServerUnread) {
      _lastServerUnread = unread;
      _alertsSeenForCurrentUnread = false;
    } else if (unread == 0) {
      _alertsSeenForCurrentUnread = true;
      _lastServerUnread = 0;
    }

    final displayUnread = _alertsSeenForCurrentUnread ? 0 : unread;
    final bottomPadding = MediaQuery.of(context).padding.bottom + 10;
    final navContent = _PillBottomBar(
      index: _index,
      unread: displayUnread,
      onTap: _onItemTapped,
    );
    final offlineBadge = _offlineMode
        ? Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 12,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.48),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.12),
                  ),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.cloud_off_rounded,
                      size: 13,
                      color: Colors.white70,
                    ),
                    SizedBox(width: 6),
                    Text(
                      'Offline Mode',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
        : const SizedBox.shrink();

    final safeIndex = _index.clamp(0, _pages.length - 1);
    return LayoutBuilder(
      builder: (context, constraints) {
        final isLarge = constraints.maxWidth > 600;
        if (!isLarge) {
          return Scaffold(
            extendBody: true,
            extendBodyBehindAppBar: true,
            resizeToAvoidBottomInset: false,
            body: GlassScaffoldBackground(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  IndexedStack(
                    index: safeIndex,
                    children: _pages,
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: IgnorePointer(
                      ignoring: false,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(32, 0, 32, bottomPadding),
                        child: SizedBox(
                          height: 64,
                          child: widget.liquidGlassEnabled
                              ? LiquidGlass.withOwnLayer(
                                  settings: kyomiruLiquidGlassSettings(
                                    isOledBlack: settings.isOledBlack,
                                  ),
                                  shape: const LiquidRoundedSuperellipse(
                                      borderRadius: 40),
                                  child: navContent,
                                )
                              : Container(
                                  decoration: BoxDecoration(
                                    color: const Color(0xFA1E1E1E),
                                    borderRadius: BorderRadius.circular(40),
                                    border: Border.all(
                                      color:
                                          Colors.white.withValues(alpha: 0.10),
                                    ),
                                  ),
                                  child: navContent,
                                ),
                        ),
                      ),
                    ),
                  ),
                  offlineBadge,
                ],
              ),
            ),
          );
        }

        return Scaffold(
          extendBody: true,
          extendBodyBehindAppBar: true,
          resizeToAvoidBottomInset: false,
          body: GlassScaffoldBackground(
            child: SizedBox.expand(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  IndexedStack(
                    index: safeIndex,
                    children: _pages,
                  ),
                  Builder(builder: (dockContext) {
                    final viewPadding = MediaQuery.viewPaddingOf(context);
                    final size = Size(constraints.maxWidth, constraints.maxHeight);
                    final rect = _wideDockRect(size, viewPadding);
                    final dock = _MagneticWideNavDock(
                      edge: _wideDockEdge,
                      currentIndex: safeIndex,
                      onSearchTap: _openSearch,
                      onHomeTap: () => _onItemTapped(1),
                      onLibraryTap: () => _onItemTapped(0),
                      onNotificationsTap: () => _onItemTapped(2),
                      onDownloadsTap: () => _onItemTapped(3),
                      onSettingsTap: () => _onItemTapped(4),
                      liquidGlassEnabled: widget.liquidGlassEnabled,
                      isOledBlack: settings.isOledBlack,
                    );
                    return Positioned.fromRect(
                      rect: rect,
                      child: LongPressDraggable<int>(
                        data: 1,
                        feedback: SizedBox(
                          width: rect.width,
                          height: rect.height,
                          child: Opacity(opacity: 0.92, child: dock),
                        ),
                        onDragEnd: (details) => _snapDockFromGlobal(
                          details,
                          dockContext,
                          size,
                          viewPadding,
                        ),
                        childWhenDragging: Opacity(
                          opacity: 0.18,
                          child: dock,
                        ),
                        child: dock,
                      ),
                    );
                  }),
                  offlineBadge,
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PillBottomBar extends StatelessWidget {
  const _PillBottomBar({
    required this.index,
    required this.unread,
    required this.onTap,
  });

  final int index;
  final int unread;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final items = <({IconData active, IconData inactive})>[
      (active: CupertinoIcons.book_fill, inactive: CupertinoIcons.book),
      (active: CupertinoIcons.compass_fill, inactive: CupertinoIcons.compass),
      (active: CupertinoIcons.bell_fill, inactive: CupertinoIcons.bell),
      (
        active: CupertinoIcons.arrow_down_circle_fill,
        inactive: CupertinoIcons.arrow_down_circle,
      ),
      (active: CupertinoIcons.gear_solid, inactive: CupertinoIcons.gear),
    ];

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        for (var i = 0; i < items.length; i++)
          Expanded(
            child: InkWell(
              onTap: () => onTap(i),
              child: SizedBox(
                height: double.infinity,
                child: Center(
                  child: Badge(
                    isLabelVisible: i == 2 && unread > 0,
                    smallSize: 8,
                    child: Icon(
                      i == index ? items[i].active : items[i].inactive,
                      color: i == index ? Colors.white : Colors.white54,
                      size: 24,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

enum _DockEdge { left, right, top, bottom }

class _MagneticWideNavDock extends StatelessWidget {
  const _MagneticWideNavDock({
    required this.edge,
    required this.currentIndex,
    required this.onSearchTap,
    required this.onHomeTap,
    required this.onLibraryTap,
    required this.onNotificationsTap,
    required this.onDownloadsTap,
    required this.onSettingsTap,
    required this.liquidGlassEnabled,
    required this.isOledBlack,
  });

  final _DockEdge edge;
  final int currentIndex;
  final VoidCallback onSearchTap;
  final VoidCallback onHomeTap;
  final VoidCallback onLibraryTap;
  final VoidCallback onNotificationsTap;
  final VoidCallback onDownloadsTap;
  final VoidCallback onSettingsTap;
  final bool liquidGlassEnabled;
  final bool isOledBlack;

  @override
  Widget build(BuildContext context) {
    final vertical = edge == _DockEdge.left || edge == _DockEdge.right;
    final body = Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.18),
          width: 0.5,
        ),
      ),
      child: Flex(
        direction: vertical ? Axis.vertical : Axis.horizontal,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _WideRailItem(
            icon: CupertinoIcons.search,
            active: false,
            onTap: onSearchTap,
          ),
          SizedBox(width: vertical ? 0 : 6, height: vertical ? 6 : 0),
          _WideRailItem(
            icon: CupertinoIcons.house_fill,
            active: currentIndex == 1,
            onTap: onHomeTap,
          ),
          SizedBox(width: vertical ? 0 : 6, height: vertical ? 6 : 0),
          _WideRailItem(
            icon: CupertinoIcons.book_fill,
            active: currentIndex == 0,
            onTap: onLibraryTap,
          ),
          SizedBox(width: vertical ? 0 : 6, height: vertical ? 6 : 0),
          _WideRailItem(
            icon: CupertinoIcons.bell_fill,
            active: currentIndex == 2,
            onTap: onNotificationsTap,
          ),
          SizedBox(width: vertical ? 0 : 6, height: vertical ? 6 : 0),
          _WideRailItem(
            icon: CupertinoIcons.arrow_down_circle_fill,
            active: currentIndex == 3,
            onTap: onDownloadsTap,
          ),
          SizedBox(width: vertical ? 0 : 6, height: vertical ? 6 : 0),
          _WideRailItem(
            icon: CupertinoIcons.gear,
            active: currentIndex == 4,
            onTap: onSettingsTap,
          ),
        ],
      ),
    );

    if (liquidGlassEnabled) {
      return LiquidGlass.withOwnLayer(
        settings: kyomiruLiquidGlassSettings(isOledBlack: isOledBlack),
        shape: const LiquidRoundedSuperellipse(borderRadius: 28),
        child: body,
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: body,
      ),
    );
  }
}

class _WideRailItem extends StatelessWidget {
  const _WideRailItem({
    required this.icon,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          height: 48,
          width: 48,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color:
                active ? Colors.white.withValues(alpha: 0.18) : Colors.transparent,
          ),
          child: Icon(
            icon,
            size: 23,
            color: active ? Colors.white : Colors.white70,
          ),
        ),
      ),
    );
  }
}

class _UnifiedLibraryTab extends ConsumerStatefulWidget {
  const _UnifiedLibraryTab();

  @override
  ConsumerState<_UnifiedLibraryTab> createState() => _UnifiedLibraryTabState();
}

class _UnifiedLibraryTabState extends ConsumerState<_UnifiedLibraryTab> {
  static const _cardWidth = 152.0;
  static const _cardHeight = 232.0;
  final TextEditingController _searchController = TextEditingController();
  Timer? _heroTimer;
  int _heroIndex = 0;
  String _selected = 'All';

  @override
  void dispose() {
    _heroTimer?.cancel();
    _searchController.dispose();
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
      return const SafeArea(
        child: Center(child: Text('Connect AniList to load your library.')),
      );
    }

    final token = auth.token!;
    final client = ref.watch(anilistClientProvider);
    return FutureBuilder<List<dynamic>>(
      future: client
          .me(token)
          .then((u) async => [u, await client.librarySections(token, userId: u.id)]),
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
        final heroPool =
            (watching.isNotEmpty ? watching : planning).map((e) => e.media).toList();
        _startHeroTimer(heroPool.length);
        final heroMedia =
            heroPool.isEmpty ? null : heroPool[_heroIndex % heroPool.length];

        final chips = <String>['All', ...sections.map((s) => s.title)];
        final q = _searchController.text.trim().toLowerCase();
        final selectedSections = _selected == 'All'
            ? sections
            : sections.where((s) => s.title == _selected).toList();
        final filtered = q.isEmpty
            ? selectedSections
            : selectedSections
                .map((s) => AniListLibrarySection(
                      title: s.title,
                      items: s.items
                          .where((i) => i.media.title.best.toLowerCase().contains(q))
                          .toList(),
                    ))
                .where((s) => s.items.isNotEmpty)
                .toList();

        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFF090B13),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x4D121520), Color(0xFF090B13)],
            ),
          ),
          child: RefreshIndicator(
            onRefresh: () async => setState(() {}),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 120),
              children: [
                _LibraryHero(media: heroMedia),
                const SizedBox(height: 10),
                GlassContainer(
                  borderRadius: 14,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: TextField(
                      controller: _searchController,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: 'Search in library...',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _searchController.text.isEmpty
                            ? null
                            : IconButton(
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() {});
                                },
                                icon: const Icon(Icons.close),
                              ),
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
                    itemBuilder: (context, i) => ChoiceChip(
                      label: Text(chips[i]),
                      selected: chips[i] == _selected,
                      onSelected: (_) => setState(() => _selected = chips[i]),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text('Library', style: Theme.of(context).textTheme.displaySmall),
                    const Spacer(),
                    if (user.avatar != null)
                      CircleAvatar(
                        radius: 16,
                        backgroundImage: KyomiruImageCache.provider(user.avatar!),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                for (final section in filtered) ...[
                  if (section.items.isNotEmpty) ...[
                    Text(
                      section.title,
                      style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: _cardHeight,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: section.items.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 10),
                        itemBuilder: (context, index) {
                          final media = section.items[index].media;
                          return SizedBox(
                            width: _cardWidth,
                            child: GestureDetector(
                              onTap: () => Navigator.of(context).push(
                                PageRouteBuilder<void>(
                                  pageBuilder: (_, __, ___) =>
                                      DetailsScreen(mediaId: media.id),
                                  transitionDuration: Duration.zero,
                                  reverseTransitionDuration: Duration.zero,
                                ),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(18),
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
                                          colors: [Colors.transparent, Color(0xE6000000)],
                                          stops: [0.54, 1],
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
                    ),
                    const SizedBox(height: 14),
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

class _LibraryHero extends StatelessWidget {
  const _LibraryHero({required this.media});

  final AniListMedia? media;

  @override
  Widget build(BuildContext context) {
    final image = media?.bannerImage ?? media?.cover.best;
    return SizedBox(
      height: 285,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Stack(
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
                      Color(0xFF090B13),
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
                  const Text(
                    'Library',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 6),
                  if (media != null)
                    Text(
                      media!.title.best,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  String? _markedForToken;
  final Set<int> _dismissedIds = <int>{};
  int _refreshTick = 0;

  Future<void> _refresh() async {
    setState(() => _refreshTick++);
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    if (auth.loading) {
      return const SafeArea(child: _NotificationsSkeleton());
    }

    if (auth.token == null || auth.token!.isEmpty) {
      return const SafeArea(
        child: Center(
          child: Text('Connect AniList to view alerts.'),
        ),
      );
    }

    final token = auth.token!;
    if (_markedForToken != token) {
      _markedForToken = token;
      Future<void>(() async {
        await ref.read(anilistClientProvider).markNotificationsRead(token);
        if (!mounted) return;
        ref.invalidate(unreadAlertsProvider);
      });
    }

    final client = ref.watch(anilistClientProvider);
    final unread = ref.watch(unreadAlertsProvider).valueOrNull ?? 0;

    return FutureBuilder<List<AniListNotificationItem>>(
      key: ValueKey('alerts-$_refreshTick'),
      future: client.notifications(token),
      builder: (context, snap) {
        final data = (snap.data ?? const <AniListNotificationItem>[])
            .where((e) => !_dismissedIds.contains(e.id))
            .toList();

        return SafeArea(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
              children: [
                Text('Notifications',
                    style: Theme.of(context).textTheme.displaySmall),
                const SizedBox(height: 4),
                Text('AniList unread: $unread',
                    style: const TextStyle(color: Color(0xFFA1A8BC))),
                const SizedBox(height: 12),
                if (snap.connectionState == ConnectionState.waiting)
                  const _NotificationsSkeleton()
                else if (snap.hasError)
                  GlassCard(
                      child: Text('Notification load failed: ${snap.error}'))
                else if (data.isEmpty)
                  const GlassCard(child: Text('No notifications.'))
                else
                  ...data.map((n) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Dismissible(
                          key: ValueKey('notif-${n.id}'),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 16),
                            decoration: BoxDecoration(
                              color: Colors.red.shade700,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child:
                                const Icon(Icons.delete, color: Colors.white),
                          ),
                          onDismissed: (_) async {
                            HapticFeedback.mediumImpact();
                            setState(() => _dismissedIds.add(n.id));
                            await ref
                                .read(anilistClientProvider)
                                .markNotificationsRead(token);
                            ref.invalidate(unreadAlertsProvider);
                          },
                          child: _NotificationTile(item: n),
                        ),
                      )),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.item});

  final AniListNotificationItem item;

  String _timeAgo(int unixSeconds) {
    if (unixSeconds <= 0) return 'now';
    final created = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
    final diff = DateTime.now().difference(created);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${(diff.inDays / 7).floor()}w ago';
  }

  String _titleFor(AniListNotificationItem n) {
    final lower = n.type.toLowerCase();
    if (lower.contains('airing')) {
      final mediaTitle = n.media?.title.best ?? 'Episode update';
      if (n.episode != null) return '$mediaTitle aired episode ${n.episode}';
      return n.context ?? mediaTitle;
    }
    if (lower.contains('activity_like')) {
      return '${n.userName ?? 'Someone'} liked your activity.';
    }
    if (lower.contains('activity_reply_like')) {
      return '${n.userName ?? 'Someone'} liked your reply.';
    }
    if (lower.contains('activity_reply')) {
      return '${n.userName ?? 'Someone'} replied to your activity.';
    }
    if (lower.contains('following')) {
      return '${n.userName ?? 'Someone'} started following you.';
    }
    return n.context ?? n.media?.title.best ?? n.type;
  }

  @override
  Widget build(BuildContext context) {
    final imageUrl = item.media?.cover.best ?? item.userAvatar;
    final subtitle =
        '${item.type.toLowerCase()} \u2022 ${_timeAgo(item.createdAt)}';

    return GlassCard(
      borderRadius: 14,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 68,
              height: 68,
              child: imageUrl == null || imageUrl.isEmpty
                  ? const ColoredBox(
                      color: Color(0x221E2335),
                      child: Icon(Icons.notifications_outlined,
                          color: Color(0xFFA1A8BC)),
                    )
                  : KyomiruImageCache.image(imageUrl, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _titleFor(item),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 15),
                ),
                const SizedBox(height: 4),
                Text(subtitle,
                    style: const TextStyle(
                        fontSize: 13, color: Color(0xFFA1A8BC))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NotificationsSkeleton extends StatelessWidget {
  const _NotificationsSkeleton();

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: const Color(0xFF333333),
      highlightColor: const Color(0xFF555555),
      child: Column(
        children: List.generate(
          6,
          (index) => Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Container(
                    width: 68,
                    height: 68,
                    decoration: BoxDecoration(
                        color: Colors.black12,
                        borderRadius: BorderRadius.circular(10))),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                          height: 14,
                          decoration: BoxDecoration(
                              color: Colors.black12,
                              borderRadius: BorderRadius.circular(8))),
                      const SizedBox(height: 8),
                      Container(
                          height: 12,
                          width: 140,
                          decoration: BoxDecoration(
                              color: Colors.black12,
                              borderRadius: BorderRadius.circular(8))),
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



