import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/haptics.dart';
import '../../core/glass_widgets.dart';
import '../../services/cache_service.dart';
import '../../services/sora_extension_loader.dart';
import '../../state/app_settings_state.dart';
import '../../state/auth_state.dart';
import '../../state/library_source_state.dart';
import 'account_data_settings_screen.dart';
import 'appearance_settings_screen.dart';
import 'debug_logs_screen.dart';
import 'library_preferences_screen.dart';
import 'player_settings_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final SoraExtensionLoader _loader;
  late Future<_ExtensionLoadState> _extensionFuture;

  @override
  void initState() {
    super.initState();
    _loader = SoraExtensionLoader();
    _extensionFuture = _loadExtensionState();
  }

  Future<_ExtensionLoadState> _loadExtensionState() async {
    try {
      final manifest = await _loader.loadOfficialAnimePahe();
      final label = manifest.name ?? manifest.id;
      return _ExtensionLoadState.loaded(label);
    } on DioException {
      return _ExtensionLoadState.failed();
    } on SocketException {
      return _ExtensionLoadState.failed();
    } catch (_) {
      return _ExtensionLoadState.failed();
    }
  }

  void _retryExtensionLoad() {
    setState(() {
      _extensionFuture = _loadExtensionState();
    });
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);
    final librarySource = ref.watch(librarySourceProvider);
    final cacheStatsAsync = ref.watch(cacheStatsProvider);
    final connected = auth.token != null && auth.token!.isNotEmpty;

    return SafeArea(
      child: FutureBuilder(
        future: _extensionFuture,
        builder: (context, snap) {
          final extensionState = snap.data;
          return ListView(
            padding: const EdgeInsets.fromLTRB(10, 12, 10, 100),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text('Settings',
                    style: Theme.of(context).textTheme.displaySmall),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(6, 2, 6, 10),
                child: Text(
                  'Customize Kyomiru exactly how you want.',
                  style: TextStyle(color: Color(0xFFA1A8BC)),
                ),
              ),
              CupertinoListSection.insetGrouped(
                backgroundColor: Colors.transparent,
                children: [
                  _row(
                    context,
                    icon: Icons.palette_outlined,
                    title: 'Appearance',
                    subtitle: 'Themes, colors, and layout',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const AppearanceSettingsScreen()),
                    ),
                  ),
                  _row(
                    context,
                    icon: Icons.play_circle_outline,
                    title: 'Player & Quality',
                    subtitle:
                        'Playback, quality, audio, and stream picker behavior',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const PlayerSettingsScreen(),
                      ),
                    ),
                  ),
                  _row(
                    context,
                    icon: Icons.library_books_outlined,
                    title: 'Library Preferences',
                    subtitle:
                        'Catalog visibility, order, custom lists, sort & layout',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const LibraryPreferencesScreen(),
                      ),
                    ),
                  ),
                  _row(
                    context,
                    icon: Icons.manage_accounts_outlined,
                    title: 'Account & Data',
                    subtitle: connected
                        ? 'AniList connected'
                        : 'Auth and cleanup controls',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const AccountDataSettingsScreen(),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    child: Row(
                      children: [
                        const Padding(
                          padding: EdgeInsets.only(right: 16),
                          child: Icon(Icons.source_outlined),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Library Source',
                                style: Theme.of(context).textTheme.titleMedium,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                librarySource == LibrarySource.anilist
                                    ? 'AniList'
                                    : 'Local',
                                style: Theme.of(context).textTheme.bodySmall,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        ConstrainedBox(
                          constraints: const BoxConstraints(
                            minWidth: 132,
                            maxWidth: 176,
                          ),
                          child: CupertinoSlidingSegmentedControl<LibrarySource>(
                            groupValue: librarySource,
                            children: const {
                              LibrarySource.anilist: Padding(
                                padding: EdgeInsets.symmetric(horizontal: 8),
                                child: Text('AniList'),
                              ),
                              LibrarySource.local: Padding(
                                padding: EdgeInsets.symmetric(horizontal: 8),
                                child: Text('Local'),
                              ),
                            },
                            onValueChanged: (value) {
                              if (value == null) return;
                              hapticTap();
                              ref
                                  .read(appSettingsProvider.notifier)
                                  .setLibrarySource(
                                    value == LibrarySource.local
                                        ? 'Local'
                                        : 'AniList',
                                  );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                  _row(
                    context,
                    icon: Icons.bug_report_outlined,
                    title: 'Debug Logs',
                    subtitle: 'View, copy, and share runtime logs',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const DebugLogsScreen()),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.cleaning_services_outlined),
                    title: const Text('Cache'),
                    subtitle: Text(
                      cacheStatsAsync.when(
                        data: (stats) =>
                            'Used: ${formatBytes(stats.totalBytes)}',
                        loading: () => 'Calculating...',
                        error: (_, __) => 'Unable to read cache size',
                      ),
                    ),
                    trailing: FilledButton.tonal(
                      onPressed: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Delete Cache'),
                            content: const Text(
                              'This clears AniList cache, image cache, and temporary streaming files.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(context).pop(false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton.tonal(
                                onPressed: () =>
                                    Navigator.of(context).pop(true),
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        );
                        if (ok != true) return;
                        await ref.read(cacheServiceProvider).clearAll(
                              anilistClient: ref.read(anilistClientProvider),
                            );
                        ref.invalidate(cacheStatsProvider);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Cache cleared.')),
                          );
                        }
                      },
                      child: const Text('Delete'),
                    ),
                  ),
                ],
              ),
              CupertinoListSection.insetGrouped(
                backgroundColor: Colors.transparent,
                children: [
                  ListTile(
                    title: const Text('Source extension'),
                    subtitle: Text(snap.connectionState == ConnectionState.waiting
                        ? 'Loading source extension...'
                        : extensionState?.isLoaded == true
                            ? 'AnimePahe extension: ${extensionState!.label}'
                            : 'Extension unavailable'),
                  ),
                  if (snap.connectionState != ConnectionState.waiting &&
                      extensionState?.isLoaded != true)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
                      child: GlassCard(
                        borderRadius: 14,
                        child: Row(
                          children: [
                            Icon(
                              Icons.wifi_off_rounded,
                              color: Colors.amber.shade200,
                              size: 18,
                            ),
                            const SizedBox(width: 10),
                            const Expanded(
                              child: Text(
                                'Unable to connect to the extension server. Please check your internet connection.',
                                style: TextStyle(fontSize: 12.5),
                              ),
                            ),
                            const SizedBox(width: 10),
                            FilledButton.tonal(
                              onPressed: _retryExtensionLoad,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ListTile(
                    title: const Text('Logout AniList'),
                    trailing: const Icon(Icons.logout),
                    onTap: () {
                      hapticTap();
                      ref.read(authControllerProvider.notifier).logout();
                    },
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _row(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(CupertinoIcons.chevron_right, size: 18),
      onTap: () {
        hapticTap();
        onTap();
      },
    );
  }
}

class _ExtensionLoadState {
  const _ExtensionLoadState._({
    required this.isLoaded,
    this.label,
  });

  final bool isLoaded;
  final String? label;

  factory _ExtensionLoadState.loaded(String label) {
    return _ExtensionLoadState._(isLoaded: true, label: label);
  }

  factory _ExtensionLoadState.failed() {
    return const _ExtensionLoadState._(isLoaded: false);
  }
}
