import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/app_theme.dart';
import '../features/alerts/alerts_screen.dart';
import '../features/discovery/discovery_screen.dart';
import '../features/downloads/downloads_screen.dart';
import '../features/library/library_screen.dart';
import '../features/settings/settings_screen.dart';
import '../state/auth_state.dart';

class KyomiruApp extends StatelessWidget {
  const KyomiruApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Kyomiru',
      theme: buildKyomiruTheme(),
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

    return Scaffold(
      body: _pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        destinations: [
          const NavigationDestination(
              icon: Icon(Icons.library_books), label: 'Library'),
          const NavigationDestination(
              icon: Icon(Icons.auto_awesome), label: 'Discovery'),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: unread > 0,
              smallSize: 8,
              child: const Icon(Icons.notifications),
            ),
            label: 'Alerts',
          ),
          const NavigationDestination(
              icon: Icon(Icons.download), label: 'Downloads'),
          const NavigationDestination(
              icon: Icon(Icons.settings), label: 'Settings'),
        ],
        onDestinationSelected: (value) => setState(() => _index = value),
      ),
    );
  }
}
