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
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('Settings',
                  style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900)),
              const SizedBox(height: 12),
              GlassCard(
                child: Text(
                    'AniList: ${auth.token == null || auth.token!.isEmpty ? 'Disconnected' : 'Connected'}'),
              ),
              const SizedBox(height: 8),
              GlassCard(
                child: snap.connectionState == ConnectionState.waiting
                    ? const Text('Loading Sora extension...')
                    : snap.hasError
                        ? Text('Sora loader error: ${snap.error}')
                        : Text(
                            'Sora extension loaded: ${(snap.data as dynamic).id}'),
              ),
              const SizedBox(height: 8),
              const GlassCard(
                child: Text(
                  'Player + download engine parity with the old app is in migration.\n'
                  'This Flutter base already has AniList auth, discovery search, alerts, details tabs, and episode progress persistence.',
                ),
              ),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () =>
                    ref.read(authControllerProvider.notifier).logout(),
                child: const Text('Logout AniList'),
              ),
            ],
          );
        },
      ),
    );
  }
}
