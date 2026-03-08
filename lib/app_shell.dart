import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:cross_file/cross_file.dart';
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
import 'features/player/player_screen.dart';
import 'features/settings/settings_screen.dart';
import 'models/anilist_models.dart';
import 'services/anilist_client.dart';
import 'services/download_manager.dart';
import 'state/app_settings_state.dart';
import 'state/auth_state.dart';
import 'state/ui_ambient_state.dart';
import 'state/watch_history_state.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

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
  _DockEdge _wideDockEdge = _DockEdge.top;
  double _wideDockFactor = 0.5;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  ProviderSubscription<AuthState>? _authSub;
  final TextEditingController _desktopSearchController =
      TextEditingController();

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

  @override
  void dispose() {
    _desktopSearchController.dispose();
    _connectivitySub?.cancel();
    _authSub?.close();
    super.dispose();
  }

  bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  Future<void> _handleDesktopDrop(List<XFile> files) async {
    if (!_isDesktop || files.isEmpty || !mounted) return;
    final candidates = files
        .map((f) => f.path)
        .where((path) {
          final lower = path.toLowerCase();
          return lower.endsWith('.mp4') || lower.endsWith('.mkv');
        })
        .toList(growable: false);
    if (candidates.isEmpty) return;

    final dm = ref.read(downloadControllerProvider.notifier);
    var imported = 0;
    for (final path in candidates) {
      final episodeGuess = dm.detectEpisodeNumberFromFilePath(path) ?? 1;
      final mapped = await _showDesktopDropImportDialog(path, episodeGuess);
      if (mapped == null || !mounted) continue;
      await dm.importLocalEpisode(
        mediaId: 0,
        episode: mapped.episode,
        animeTitle: mapped.title,
        absoluteFilePath: path,
      );
      imported++;
    }
    if (!mounted || imported == 0) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        content: Text('Imported $imported desktop file(s)'),
      ),
    );
    setState(() => _index = 3);
  }

  Future<({String title, int episode})?> _showDesktopDropImportDialog(
    String path,
    int episodeGuess,
  ) async {
    final titleController =
        TextEditingController(text: p.basenameWithoutExtension(path));
    final episodeController = TextEditingController(text: '$episodeGuess');
    final result = await showDialog<({String title, int episode})>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import Local Episode'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleController,
              decoration: const InputDecoration(labelText: 'Anime Title'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: episodeController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Episode Number'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final ep = int.tryParse(episodeController.text.trim());
              final title = titleController.text.trim();
              if (ep == null || ep <= 0 || title.isEmpty) return;
              Navigator.of(context).pop((title: title, episode: ep));
            },
            child: const Text('Import'),
          ),
        ],
      ),
    );
    titleController.dispose();
    episodeController.dispose();
    return result;
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
    final vertical =
        _wideDockEdge == _DockEdge.left || _wideDockEdge == _DockEdge.right;
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

  Widget _buildDesktopShell({
    required BuildContext context,
    required int safeIndex,
    required Widget offlineBadge,
    required int unread,
  }) {
    final content = Row(
      children: [
        _DesktopExpandedRail(
          index: safeIndex,
          unread: unread,
          onTap: _onItemTapped,
        ),
        Expanded(
          child: IndexedStack(
            index: safeIndex,
            children: _pages,
          ),
        ),
      ],
    );

    final body = Scaffold(
      extendBody: true,
      extendBodyBehindAppBar: true,
      resizeToAvoidBottomInset: false,
      body: GlassScaffoldBackground(
        child: Column(
          children: [
            _DesktopLiquidTitleBar(
              searchController: _desktopSearchController,
              onSearch: () => _openSearch(),
            ),
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  content,
                  offlineBadge,
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return DropTarget(
      onDragDone: (details) => unawaited(_handleDesktopDrop(details.files)),
      child: body,
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    final ambientColor = ref.watch(uiAmbientColorProvider);
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
        if (_isDesktop) {
          return _buildDesktopShell(
            context: context,
            safeIndex: safeIndex,
            offlineBadge: offlineBadge,
            unread: displayUnread,
          );
        }
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
                    final size =
                        Size(constraints.maxWidth, constraints.maxHeight);
                    final isIosTablet = Platform.isIOS &&
                        MediaQuery.sizeOf(context).shortestSide >= 600;
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
                      activeGlowColor: ambientColor,
                    );
                    if (isIosTablet) {
                      const dockW = 358.0;
                      const dockH = 74.0;
                      final top = viewPadding.top + 12;
                      final left = ((size.width - dockW) / 2).clamp(12.0, size.width - dockW - 12);
                      return Positioned(
                        left: left,
                        top: top,
                        width: dockW,
                        height: dockH,
                        child: dock,
                      );
                    }
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

class _DesktopLiquidTitleBar extends StatefulWidget {
  const _DesktopLiquidTitleBar({
    required this.searchController,
    required this.onSearch,
  });

  final TextEditingController searchController;
  final VoidCallback onSearch;

  @override
  State<_DesktopLiquidTitleBar> createState() => _DesktopLiquidTitleBarState();
}

class _DesktopLiquidTitleBarState extends State<_DesktopLiquidTitleBar> {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    unawaited(_sync());
  }

  Future<void> _sync() async {
    _isMaximized = await windowManager.isMaximized();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 62,
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.26),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18), width: 0.5),
      ),
      child: Row(
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => windowManager.startDragging(),
            onDoubleTap: () async {
              if (await windowManager.isMaximized()) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
              await _sync();
            },
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Icon(CupertinoIcons.play_rectangle_fill, size: 18),
                  SizedBox(width: 8),
                  Text(
                    'Kyomiru',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: TextField(
              controller: widget.searchController,
              onSubmitted: (_) => widget.onSearch(),
              decoration: InputDecoration(
                hintText: 'Search anime...',
                isDense: true,
                prefixIcon: const Icon(Icons.search_rounded, size: 18),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: BorderSide(
                    color: Colors.white.withValues(alpha: 0.22),
                    width: 0.5,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: BorderSide(
                    color: Colors.white.withValues(alpha: 0.22),
                    width: 0.5,
                  ),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Minimize',
            onPressed: () => unawaited(windowManager.minimize()),
            icon: const Icon(Icons.remove_rounded),
          ),
          IconButton(
            tooltip: _isMaximized ? 'Restore' : 'Maximize',
            onPressed: () async {
              if (_isMaximized) {
                await windowManager.unmaximize();
              } else {
                await windowManager.maximize();
              }
              await _sync();
            },
            icon: Icon(_isMaximized
                ? Icons.filter_none_rounded
                : Icons.crop_square_rounded),
          ),
          IconButton(
            tooltip: 'Close',
            onPressed: () => unawaited(windowManager.close()),
            icon: const Icon(Icons.close_rounded),
          ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}

class _DesktopExpandedRail extends StatelessWidget {
  const _DesktopExpandedRail({
    required this.index,
    required this.unread,
    required this.onTap,
  });

  final int index;
  final int unread;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final items = <(int i, IconData icon, String label)>[
      (0, CupertinoIcons.book_fill, 'Library'),
      (1, CupertinoIcons.compass_fill, 'Discovery'),
      (2, CupertinoIcons.bell_fill, 'Alerts'),
      (3, CupertinoIcons.arrow_down_circle_fill, 'Downloads'),
      (4, CupertinoIcons.gear, 'Settings'),
    ];
    return Container(
      width: 228,
      margin: const EdgeInsets.fromLTRB(12, 0, 10, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Colors.black.withValues(alpha: 0.30),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16), width: 0.5),
      ),
      child: Column(
        children: [
          const SizedBox(height: 12),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => onTap(item.$1),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    color: index == item.$1
                        ? const Color(0xFF4F46E5).withValues(alpha: 0.35)
                        : Colors.transparent,
                  ),
                  child: Row(
                    children: [
                      Icon(item.$2, size: 19),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          item.$3,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (item.$1 == 2 && unread > 0)
                        Container(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(999),
                            color: Colors.redAccent,
                          ),
                          child: Text(
                            '$unread',
                            style: const TextStyle(
                                fontSize: 11, fontWeight: FontWeight.w800),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          const Spacer(),
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Text(
              'Desktop mode',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
        ],
      ),
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
    required this.activeGlowColor,
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
  final Color activeGlowColor;

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
            glowColor: activeGlowColor,
          ),
          SizedBox(width: vertical ? 0 : 6, height: vertical ? 6 : 0),
          _WideRailItem(
            icon: CupertinoIcons.house_fill,
            active: currentIndex == 1,
            onTap: onHomeTap,
            glowColor: activeGlowColor,
          ),
          SizedBox(width: vertical ? 0 : 6, height: vertical ? 6 : 0),
          _WideRailItem(
            icon: CupertinoIcons.book_fill,
            active: currentIndex == 0,
            onTap: onLibraryTap,
            glowColor: activeGlowColor,
          ),
          SizedBox(width: vertical ? 0 : 6, height: vertical ? 6 : 0),
          _WideRailItem(
            icon: CupertinoIcons.bell_fill,
            active: currentIndex == 2,
            onTap: onNotificationsTap,
            glowColor: activeGlowColor,
          ),
          SizedBox(width: vertical ? 0 : 6, height: vertical ? 6 : 0),
          _WideRailItem(
            icon: CupertinoIcons.arrow_down_circle_fill,
            active: currentIndex == 3,
            onTap: onDownloadsTap,
            glowColor: activeGlowColor,
          ),
          SizedBox(width: vertical ? 0 : 6, height: vertical ? 6 : 0),
          _WideRailItem(
            icon: CupertinoIcons.gear,
            active: currentIndex == 4,
            onTap: onSettingsTap,
            glowColor: activeGlowColor,
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

class _WideRailItem extends StatefulWidget {
  const _WideRailItem({
    required this.icon,
    required this.active,
    required this.onTap,
    required this.glowColor,
  });

  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  final Color glowColor;

  @override
  State<_WideRailItem> createState() => _WideRailItemState();
}

class _WideRailItemState extends State<_WideRailItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedScale(
        scale: (_hover || widget.active) ? 1.05 : 1.0,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOut,
              height: 48,
              width: 48,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: widget.active
                    ? Colors.white.withValues(alpha: 0.18)
                    : Colors.transparent,
                boxShadow: widget.active
                    ? [
                        BoxShadow(
                          color: widget.glowColor.withValues(alpha: 0.45),
                          blurRadius: 18,
                          spreadRadius: 1.5,
                        ),
                      ]
                    : const [],
              ),
              child: Icon(
                widget.icon,
                size: 23,
                color: widget.active ? Colors.white : Colors.white70,
              ),
            ),
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
  static const _wideCardWidth = 220.0;
  static const _wideCardHeight = 302.0;
  Timer? _heroTimer;
  int _heroIndex = 0;
  String _selected = 'All';
  Future<List<dynamic>>? _libraryFuture;
  String? _libraryFutureToken;

  @override
  void dispose() {
    _heroTimer?.cancel();
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

  Future<List<dynamic>> _loadLibraryData(
    AniListClient client,
    String token,
  ) {
    return client.me(token).then(
        (u) async => [u, await client.librarySections(token, userId: u.id)]);
  }

  void _ensureLibraryFuture(AniListClient client, String token) {
    if (_libraryFuture != null && _libraryFutureToken == token) return;
    _libraryFutureToken = token;
    _libraryFuture = _loadLibraryData(client, token);
  }

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
    _ensureLibraryFuture(client, token);
    return FutureBuilder<List<dynamic>>(
      future: _libraryFuture,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError || snap.data == null) {
          return Center(child: Text('Failed loading library: ${snap.error}'));
        }

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
        final heroMedia =
            heroPool.isEmpty ? null : heroPool[_heroIndex % heroPool.length];

        final chips = <String>['All', ...sections.map((s) => s.title)];
        final selectedSections = _selected == 'All'
            ? sections
            : sections.where((s) => s.title == _selected).toList();
        final filtered = selectedSections;

        final isWide = MediaQuery.sizeOf(context).width > 600;
        if (!isWide) {
          final phoneCardW = _phoneCardWidth(context);
          final phoneCardH = _phoneCardHeight(context);
          final heroHeight = _phoneHeroHeight(context);
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
              onRefresh: () async {
                _libraryFuture = _loadLibraryData(client, token);
                setState(() {});
                await _libraryFuture;
              },
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 120),
                children: [
                  _LibraryHero(media: heroMedia, height: heroHeight),
                  const SizedBox(height: 10),
                  const _LibraryContinueWatchingShelf(),
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
                  for (final section in filtered) ...[
                    if (section.items.isNotEmpty) ...[
                      Text(
                        section.title,
                        style: const TextStyle(
                            fontSize: 26, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: phoneCardH,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: section.items.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(width: 10),
                          itemBuilder: (context, index) => _LibraryPosterCard(
                            media: section.items[index].media,
                            width: phoneCardW,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                  ],
                ],
              ),
            ),
          );
        }

        final topInset = MediaQuery.viewPaddingOf(context).top;
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
            onRefresh: () async {
              _libraryFuture = _loadLibraryData(client, token);
              setState(() {});
              await _libraryFuture;
            },
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: _LibraryWideHero(media: heroMedia, topInset: topInset),
                ),
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
                    child: _LibraryContinueWatchingShelf(),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                    child: SizedBox(
                      height: 36,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: chips.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (context, i) => ChoiceChip(
                          label: Text(chips[i]),
                          selected: chips[i] == _selected,
                          onSelected: (_) =>
                              setState(() => _selected = chips[i]),
                        ),
                      ),
                    ),
                  ),
                ),
                for (final section in filtered)
                  if (section.items.isNotEmpty) ...[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                        child: Text(
                          section.title,
                          style: const TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                        child: SizedBox(
                          height: _wideCardHeight,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: section.items.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 14),
                            itemBuilder: (context, index) => _LibraryPosterCard(
                              media: section.items[index].media,
                              width: _wideCardWidth,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                const SliverToBoxAdapter(child: SizedBox(height: 120)),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LibraryHero extends StatelessWidget {
  const _LibraryHero({
    required this.media,
    required this.height,
  });

  final AniListMedia? media;
  final double height;

  @override
  Widget build(BuildContext context) {
    final image = media?.bannerImage ?? media?.cover.best;
    return SizedBox(
      height: height,
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
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w700),
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

class _LibraryWideHero extends StatelessWidget {
  const _LibraryWideHero({required this.media, required this.topInset});

  final AniListMedia? media;
  final double topInset;

  @override
  Widget build(BuildContext context) {
    final image = media?.bannerImage ?? media?.cover.best;
    return SizedBox(
      height: 470,
      child: Stack(
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
                  Color(0x22000000),
                  Color(0x77090B13),
                  Color(0xDD090B13),
                  Color(0xFF090B13),
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
                      const Text(
                        'Library',
                        style: TextStyle(
                          fontSize: 52,
                          fontWeight: FontWeight.w800,
                          height: 0.95,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        media?.title.best ?? 'Your AniList library',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
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

class _LibraryPosterCard extends StatelessWidget {
  const _LibraryPosterCard({
    required this.media,
    required this.width,
  });

  final AniListMedia media;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(
          PageRouteBuilder<void>(
            pageBuilder: (_, __, ___) => DetailsScreen(mediaId: media.id),
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
  }
}

class _LibraryContinueWatchingShelf extends ConsumerWidget {
  const _LibraryContinueWatchingShelf();

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
    if (!Hive.isBoxOpen('watch_history')) return const SizedBox.shrink();
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
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 152,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: entries.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  final cover = (entry.coverImageUrl ?? '').trim();
                  final remainingMs =
                      (entry.totalDurationMs - entry.lastPositionMs)
                          .clamp(0, entry.totalDurationMs);
                  return Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
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
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.08),
                          ),
                        ),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final progress = entry.progress.clamp(0.0, 1.0);
                            final progressWidth =
                                (constraints.maxWidth * progress)
                                    .clamp(0.0, constraints.maxWidth);
                            return Stack(
                              children: [
                                Row(
                                  children: [
                                    ClipRRect(
                                      borderRadius:
                                          const BorderRadius.horizontal(
                                        left: Radius.circular(16),
                                      ),
                                      child: SizedBox(
                                        width: 92,
                                        height: double.infinity,
                                        child: cover.isNotEmpty
                                            ? KyomiruImageCache.image(
                                                cover,
                                                fit: BoxFit.cover,
                                                error: const ColoredBox(
                                                    color: Color(0x22111111)),
                                              )
                                            : const ColoredBox(
                                                color: Color(0x22111111),
                                              ),
                                      ),
                                    ),
                                    Expanded(
                                      child: Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                            10, 10, 10, 10),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
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
                                              style: const TextStyle(
                                                color: Colors.white70,
                                                fontSize: 12,
                                              ),
                                            ),
                                            const Spacer(),
                                            Text(
                                              _formatTimeLeft(remainingMs),
                                              style: const TextStyle(
                                                color: Colors.white70,
                                                fontSize: 11,
                                              ),
                                            ),
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
                                      height: 4, color: Colors.white24),
                                ),
                                Positioned(
                                  left: 0,
                                  bottom: 0,
                                  child: Container(
                                    height: 4,
                                    width: progressWidth,
                                    color: const Color(0xFF60A5FA),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
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
