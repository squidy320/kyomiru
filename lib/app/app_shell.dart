import 'dart:async';
import 'dart:ui';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shimmer/shimmer.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/glass_widgets.dart';
import '../core/haptics.dart';
import '../core/image_cache.dart';
import '../core/theme/app_theme.dart';
import '../features/discovery/discovery_screen.dart';
import '../features/downloads/downloads_screen.dart';
import '../features/library/library_screen.dart';
import '../features/settings/settings_screen.dart';
import '../models/anilist_models.dart';
import '../state/app_settings_state.dart';
import '../state/auth_state.dart';

class KyomiruApp extends ConsumerWidget {
  const KyomiruApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Kyomiru',
      theme: buildKyomiruTheme(settings),
      home: const AppTabs(),
    );
  }
}

class AppTabs extends ConsumerStatefulWidget {
  const AppTabs({super.key});

  @override
  ConsumerState<AppTabs> createState() => _AppTabsState();
}

class _AppTabsState extends ConsumerState<AppTabs> {
  int _index = 0;
  int _lastServerUnread = 0;
  bool _alertsSeenForCurrentUnread = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;

  static const _pages = [
    LibraryScreen(),
    DiscoveryScreen(),
    NotificationsScreen(),
    DownloadsScreen(),
    SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    _initConnectivity();
  }

  Future<void> _initConnectivity() async {
    final now = await Connectivity().checkConnectivity();
    _applyConnectivity(now);
    _connectivitySub =
        Connectivity().onConnectivityChanged.listen(_applyConnectivity);
  }

  void _applyConnectivity(List<ConnectivityResult> results) {
    final offline =
        results.isEmpty || results.every((r) => r == ConnectivityResult.none);
    if (!mounted) return;
    if (offline && _index != 3) {
      setState(() => _index = 3);
    }
  }

  void _onTabTap(int value) {
    hapticTap();
    setState(() {
      _index = value;
      if (value == 2) {
        _alertsSeenForCurrentUnread = true;
      }
    });
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final unread = ref.watch(unreadAlertsProvider).valueOrNull ?? 0;

    if (unread > _lastServerUnread) {
      _lastServerUnread = unread;
      _alertsSeenForCurrentUnread = false;
    } else if (unread == 0) {
      _alertsSeenForCurrentUnread = true;
      _lastServerUnread = 0;
    }

    final displayUnread = _alertsSeenForCurrentUnread ? 0 : unread;

    return Scaffold(
      extendBody: true,
      body: GlassScaffoldBackground(
        child: IndexedStack(index: _index, children: _pages),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(left: 32, right: 32, bottom: 24),
          child: _PillBottomBar(
            index: _index,
            unread: displayUnread,
            onTap: _onTabTap,
          ),
        ),
      ),
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

    return ClipRRect(
      borderRadius: BorderRadius.circular(40),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
        child: Container(
          height: 64,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.5),
            border: Border.all(
              color: Colors.white.withOpacity(0.1),
              width: 1,
            ),
          ),
          child: Row(
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
          ),
        ),
      ),
    );
  }
}

class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() => _NotificationsScreenState();
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
              padding: const EdgeInsets.all(16),
              children: [
                Text('Notifications', style: Theme.of(context).textTheme.displaySmall),
                const SizedBox(height: 4),
                Text('AniList unread: $unread', style: const TextStyle(color: Color(0xFFA1A8BC))),
                const SizedBox(height: 12),
                if (snap.connectionState == ConnectionState.waiting)
                  const _NotificationsSkeleton()
                else if (snap.hasError)
                  GlassCard(child: Text('Notification load failed: ${snap.error}'))
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
                            child: const Icon(Icons.delete, color: Colors.white),
                          ),
                          onDismissed: (_) async {
                            HapticFeedback.mediumImpact();
                            setState(() => _dismissedIds.add(n.id));
                            await ref.read(anilistClientProvider).markNotificationsRead(token);
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
    if (lower.contains('activity_like')) return '${n.userName ?? 'Someone'} liked your activity.';
    if (lower.contains('activity_reply_like')) return '${n.userName ?? 'Someone'} liked your reply.';
    if (lower.contains('activity_reply')) return '${n.userName ?? 'Someone'} replied to your activity.';
    if (lower.contains('following')) return '${n.userName ?? 'Someone'} started following you.';
    return n.context ?? n.media?.title.best ?? n.type;
  }

  @override
  Widget build(BuildContext context) {
    final imageUrl = item.media?.cover.best ?? item.userAvatar;
    final subtitle = '${item.type.toLowerCase()} \u2022 ${_timeAgo(item.createdAt)}';

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
                      child: Icon(Icons.notifications_outlined, color: Color(0xFFA1A8BC)),
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
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                ),
                const SizedBox(height: 4),
                Text(subtitle, style: const TextStyle(fontSize: 13, color: Color(0xFFA1A8BC))),
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
                Container(width: 68, height: 68, decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(10))),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(height: 14, decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(8))),
                      const SizedBox(height: 8),
                      Container(height: 12, width: 140, decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(8))),
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

