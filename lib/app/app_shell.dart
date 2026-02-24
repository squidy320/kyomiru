import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
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

  @override
  void dispose() {
    _connectivitySub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final unread = ref.watch(unreadAlertsProvider).valueOrNull ?? 0;
    final settings = ref.watch(appSettingsProvider);

    return Scaffold(
      extendBody: true,
      body: GlassScaffoldBackground(child: _pages[_index]),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: _PillBottomBar(
          compact: settings.compactBar,
          index: _index,
          unread: unread,
          onTap: (value) => setState(() => _index = value),
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
    required this.onTap,
  });

  final bool compact;
  final int index;
  final int unread;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final items = <({IconData icon, String label})>[
      (icon: Icons.library_books_outlined, label: 'Library'),
      (icon: Icons.auto_awesome_outlined, label: 'Discover'),
      (icon: Icons.notifications_none, label: 'Alerts'),
      (icon: Icons.download_outlined, label: 'Downloads'),
      (icon: Icons.settings_outlined, label: 'Settings'),
    ];

    return GlassCard(
      borderRadius: 30,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 4 : 6,
      ),
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => onTap(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: EdgeInsets.symmetric(
                      vertical: compact ? 8 : 10, horizontal: 6),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    color: i == index
                        ? Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.24)
                        : Colors.transparent,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (i == 2)
                        Badge(
                          isLabelVisible: unread > 0,
                          smallSize: 8,
                          child: Icon(items[i].icon,
                              size: compact ? 18 : 20,
                              color: i == index
                                  ? Theme.of(context).colorScheme.primary
                                  : null),
                        )
                      else
                        Icon(items[i].icon,
                            size: compact ? 18 : 20,
                            color: i == index
                                ? Theme.of(context).colorScheme.primary
                                : null),
                      if (!compact) ...[
                        const SizedBox(height: 2),
                        Text(
                          items[i].label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight:
                                i == index ? FontWeight.w800 : FontWeight.w600,
                            color: i == index
                                ? Theme.of(context).colorScheme.primary
                                : const Color(0xFFA1A8BC),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (i != items.length - 1) const SizedBox(width: 4),
          ],
        ],
      ),
    );
  }
}
