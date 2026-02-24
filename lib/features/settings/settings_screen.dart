import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/glass_widgets.dart';
import '../../services/sora_extension_loader.dart';
import '../../state/auth_state.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
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
                  style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900)),
              const SizedBox(height: 12),
              GlassCard(
                child: Row(
                  children: [
                    Icon(
                      connected ? Icons.check_circle_outline : Icons.link_off,
                      color:
                          connected ? Colors.greenAccent : Colors.orangeAccent,
                    ),
                    const SizedBox(width: 10),
                    Text(
                        'AniList: ${connected ? 'Connected' : 'Disconnected'}'),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              GlassCard(
                child: snap.connectionState == ConnectionState.waiting
                    ? const Text('Loading Sora extension...')
                    : snap.hasError
                        ? Text('Sora loader error: ${snap.error}')
                        : Text(
                            'AnimePahe source: ${(snap.data as dynamic).name ?? (snap.data as dynamic).id}'),
              ),
              const SizedBox(height: 8),
              const GlassCard(
                child: Text(
                  'Theme: Liquid glass surfaces enabled.\n'
                  'Discovery: vertical sections with horizontal cards.\n'
                  'AniList auth: token flow only for reliability.',
                ),
              ),
              const SizedBox(height: 10),
              ElevatedButton.icon(
                onPressed: () =>
                    ref.read(authControllerProvider.notifier).logout(),
                icon: const Icon(Icons.logout),
                label: const Text('Logout AniList'),
              ),
            ],
          );
        },
      ),
    );
  }
}
