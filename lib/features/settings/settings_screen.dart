import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/glass_widgets.dart';
import '../../services/sora_extension_loader.dart';
import '../../state/app_settings_state.dart';
import '../../state/auth_state.dart';
import 'appearance_settings_screen.dart';
import 'debug_logs_screen.dart';
import 'streams_settings_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final settings = ref.watch(appSettingsProvider);
    final loader = SoraExtensionLoader();

    return SafeArea(
      child: FutureBuilder(
        future: loader.loadOfficialAnimePahe(),
        builder: (context, snap) {
          final connected = auth.token != null && auth.token!.isNotEmpty;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            children: [
              const Text('Settings',
                  style: TextStyle(fontSize: 42, fontWeight: FontWeight.w900)),
              const Text('Customize Kyomiru exactly how you want.',
                  style: TextStyle(color: Color(0xFFA1A8BC))),
              const SizedBox(height: 14),
              _SettingsTile(
                icon: Icons.palette_outlined,
                title: 'Appearance',
                subtitle: 'Themes, colors, and layout',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const AppearanceSettingsScreen()),
                ),
              ),
              const SizedBox(height: 8),
              _SettingsTile(
                icon: Icons.play_circle_outline,
                title: 'Player',
                subtitle: 'Playback controls and behavior',
                onTap: () => _openComingSoon(context, 'Player'),
              ),
              const SizedBox(height: 8),
              _SettingsTile(
                icon: Icons.view_list_outlined,
                title: 'Library & Streams',
                subtitle:
                    'Default: ${settings.preferredQuality} ${settings.preferredAudio.toUpperCase()}${settings.chooseStreamEveryTime ? ' - Ask every time' : ''}',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const StreamsSettingsScreen()),
                ),
              ),
              const SizedBox(height: 8),
              _SettingsTile(
                icon: Icons.manage_accounts_outlined,
                title: 'Account & Data',
                subtitle: connected
                    ? 'AniList connected'
                    : 'Auth and cleanup controls',
                onTap: () => _openComingSoon(context, 'Account & Data'),
              ),
              const SizedBox(height: 8),
              _SettingsTile(
                icon: Icons.bug_report_outlined,
                title: 'Debug Logs',
                subtitle: 'View, copy, and share runtime logs',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const DebugLogsScreen()),
                ),
              ),
              const SizedBox(height: 12),
              GlassCard(
                child: Text(
                  snap.connectionState == ConnectionState.waiting
                      ? 'Loading source extension...'
                      : snap.hasError
                          ? 'Extension load error: ${snap.error}'
                          : 'AnimePahe extension: ${(snap.data as dynamic).name ?? (snap.data as dynamic).id}',
                ),
              ),
              const SizedBox(height: 12),
              GlassButton(
                onPressed: () =>
                    ref.read(authControllerProvider.notifier).logout(),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.logout, size: 18),
                    SizedBox(width: 8),
                    Text('Logout AniList',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _openComingSoon(BuildContext context, String title) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => GlassScaffoldBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: GlassCard(
              child: Text('$title page is next in migration.'),
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: GlassCard(
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: const Color(0x551C243A),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Icon(icon, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 18)),
                  Text(subtitle,
                      style: const TextStyle(
                          color: Color(0xFFA1A8BC), fontSize: 12)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}
