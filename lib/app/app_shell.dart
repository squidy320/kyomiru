import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/glass_widgets.dart';
import '../core/theme/app_theme.dart';
import '../features/alerts/alerts_screen.dart';
import '../features/discovery/discovery_screen.dart';
import '../features/downloads/downloads_screen.dart';
import '../features/library/library_screen.dart';
import '../features/settings/settings_screen.dart';
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
    AlertsScreen(),
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
    final settings = ref.watch(appSettingsProvider);
    final currentUser = ref.watch(currentUserProvider).valueOrNull;
    final isIOS = defaultTargetPlatform == TargetPlatform.iOS;

    if (unread > _lastServerUnread) {
      _lastServerUnread = unread;
      _alertsSeenForCurrentUnread = false;
    } else if (unread == 0) {
      _alertsSeenForCurrentUnread = true;
      _lastServerUnread = 0;
    }

    final displayUnread = _alertsSeenForCurrentUnread ? 0 : unread;
    final activeColor = Theme.of(context).colorScheme.primary;

    Widget iOSAlertsIcon() {
      final avatar = currentUser?.avatar;
      final selected = _index == 2;
      final borderColor = selected ? activeColor : const Color(0x33FFFFFF);
      final base = Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: borderColor, width: 1),
          image: (avatar != null && avatar.isNotEmpty)
              ? DecorationImage(image: NetworkImage(avatar), fit: BoxFit.cover)
              : null,
          color: (avatar == null || avatar.isEmpty)
              ? const Color(0x44161D32)
              : Colors.transparent,
        ),
        child: (avatar == null || avatar.isEmpty)
            ? Icon(Icons.person_rounded,
                size: 15,
                color: selected ? activeColor : const Color(0xFFCAD0DD))
            : null,
      );
      return Badge(
        isLabelVisible: displayUnread > 0,
        smallSize: 8,
        child: base,
      );
    }

    return Scaffold(
      extendBody: !isIOS,
      body: GlassScaffoldBackground(child: _pages[_index]),
      bottomNavigationBar: isIOS
          ? CupertinoTabBar(
              currentIndex: _index,
              onTap: _onTabTap,
              activeColor: activeColor,
              inactiveColor: const Color(0xFFCAD0DD),
              backgroundColor: const Color(0xEE101423),
              border: const Border(
                top: BorderSide(color: Color(0x22000000), width: 0.5),
              ),
              items: [
                const BottomNavigationBarItem(
                    icon: Icon(Icons.library_books_outlined), label: 'Library'),
                const BottomNavigationBarItem(
                    icon: Icon(Icons.auto_awesome_outlined),
                    label: 'Discovery'),
                BottomNavigationBarItem(icon: iOSAlertsIcon(), label: 'Alerts'),
                const BottomNavigationBarItem(
                    icon: Icon(Icons.download_outlined), label: 'Downloads'),
                const BottomNavigationBarItem(
                    icon: Icon(Icons.settings_outlined), label: 'Settings'),
              ],
            )
          : SafeArea(
              minimum: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: _PillBottomBar(
                compact: settings.compactBar,
                index: _index,
                unread: displayUnread,
                userAvatar: currentUser?.avatar,
                onTap: _onTabTap,
              ),
            ),
    );
  }
}

class _PillBottomBar extends StatelessWidget {
  const _PillBottomBar({
    required this.compact,
    required this.index,
    required this.unread,
    required this.userAvatar,
    required this.onTap,
  });

  final bool compact;
  final int index;
  final int unread;
  final String? userAvatar;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final items = <({IconData icon, String label})>[
      (icon: Icons.library_books_outlined, label: 'Library'),
      (icon: Icons.auto_awesome_outlined, label: 'Discovery'),
      (icon: Icons.notifications_rounded, label: 'Alerts'),
      (icon: Icons.download_outlined, label: 'Downloads'),
      (icon: Icons.settings_outlined, label: 'Settings'),
    ];

    final activeColor = Theme.of(context).colorScheme.primary;

    Widget alertsIcon() {
      final avatar = userAvatar;
      final selected = index == 2;
      final borderColor = selected ? activeColor : const Color(0x33FFFFFF);
      final base = Container(
        width: compact ? 20 : 22,
        height: compact ? 20 : 22,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: borderColor, width: 1),
          image: (avatar != null && avatar.isNotEmpty)
              ? DecorationImage(image: NetworkImage(avatar), fit: BoxFit.cover)
              : null,
          color: (avatar == null || avatar.isEmpty)
              ? const Color(0x44161D32)
              : Colors.transparent,
        ),
        child: (avatar == null || avatar.isEmpty)
            ? Icon(Icons.person_rounded,
                size: compact ? 14 : 15,
                color: selected ? activeColor : const Color(0xFFCAD0DD))
            : null,
      );
      return Badge(
        isLabelVisible: unread > 0,
        smallSize: 8,
        child: base,
      );
    }

    return GlassCard(
      borderRadius: 999,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 12,
        vertical: compact ? 4 : 6,
      ),
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++)
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => onTap(i),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    vertical: compact ? 8 : 10,
                    horizontal: 4,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (i == 2)
                        alertsIcon()
                      else
                        Icon(
                          items[i].icon,
                          size: compact ? 19 : 20,
                          color: i == index
                              ? activeColor
                              : const Color(0xFFCAD0DD),
                        ),
                      if (!compact) ...[
                        const SizedBox(height: 3),
                        Text(
                          items[i].label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight:
                                i == index ? FontWeight.w800 : FontWeight.w600,
                            color: i == index
                                ? activeColor
                                : const Color(0xFFCAD0DD),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
