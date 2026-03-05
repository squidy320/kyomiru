import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/haptics.dart';
import '../../services/cache_service.dart';
import '../../services/sora_extension_loader.dart';
import '../../state/app_settings_state.dart';
import '../../state/auth_state.dart';
import '../../state/library_source_state.dart';
import 'account_data_settings_screen.dart';
import 'appearance_settings_screen.dart';
import 'debug_logs_screen.dart';
import 'player_settings_screen.dart';
import 'streams_settings_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final settings = ref.watch(appSettingsProvider);
    final librarySource = ref.watch(librarySourceProvider);
    final cacheStatsAsync = ref.watch(cacheStatsProvider);
    final loader = SoraExtensionLoader();
    final connected = auth.token != null && auth.token!.isNotEmpty;

    return SafeArea(
      child: FutureBuilder(
        future: loader.loadOfficialAnimePahe(),
        builder: (context, snap) {
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
                    title: 'Player',
                    subtitle: 'Playback controls and behavior',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const PlayerSettingsScreen(),
                      ),
                    ),
                  ),
                  _row(
                    context,
                    icon: Icons.view_list_outlined,
                    title: 'Library & Streams',
                    subtitle:
                        'Default: ${settings.preferredQuality} ${settings.preferredAudio.toUpperCase()}${settings.chooseStreamEveryTime ? ' - Ask every time' : ''}',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const StreamsSettingsScreen()),
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
                  ListTile(
                    leading: const Icon(Icons.source_outlined),
                    title: const Text('Library Source'),
                    subtitle: Text(
                      librarySource == LibrarySource.anilist
                          ? 'AniList'
                          : 'Local',
                    ),
                    trailing: SizedBox(
                      width: 200,
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
                    subtitle: Text(
                      snap.connectionState == ConnectionState.waiting
                          ? 'Loading source extension...'
                          : snap.hasError
                              ? 'Extension load error: ${snap.error}'
                              : 'AnimePahe extension: ${(snap.data as dynamic).name ?? (snap.data as dynamic).id}',
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
