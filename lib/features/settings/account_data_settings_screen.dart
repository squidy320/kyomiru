import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_settings_state.dart';
import '../../state/auth_state.dart';
import '../auth/anilist_login_webview_screen.dart';

class AccountDataSettingsScreen extends ConsumerWidget {
  const AccountDataSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    final settings = ref.watch(appSettingsProvider);
    final controller = ref.read(appSettingsProvider.notifier);
    final connected = auth.token != null && auth.token!.isNotEmpty;
    final userAsync = ref.watch(currentUserProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Account & Data')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          CupertinoListSection.insetGrouped(
            backgroundColor: Colors.transparent,
            children: [
              if (connected)
                userAsync.when(
                  data: (user) => ListTile(
                    leading: CircleAvatar(
                      backgroundImage:
                          (user?.avatar != null && user!.avatar!.isNotEmpty)
                              ? NetworkImage(user.avatar!)
                              : null,
                      child: (user?.avatar == null || user!.avatar!.isEmpty)
                          ? const Icon(Icons.person_rounded)
                          : null,
                    ),
                    title: Text(user?.name ?? 'AniList'),
                    subtitle: const Text('Connected'),
                    trailing: FilledButton.tonal(
                      onPressed: () =>
                          ref.read(authControllerProvider.notifier).logout(),
                      child: const Text('Logout'),
                    ),
                  ),
                  loading: () => const ListTile(
                    leading: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    title: Text('Loading AniList profile...'),
                  ),
                  error: (_, __) => ListTile(
                    leading: const Icon(Icons.error_outline_rounded),
                    title: const Text('Failed to load AniList profile'),
                    trailing: FilledButton.tonal(
                      onPressed: () =>
                          ref.read(authControllerProvider.notifier).logout(),
                      child: const Text('Logout'),
                    ),
                  ),
                )
              else
                ListTile(
                  title: const Text('AniList Integration'),
                  subtitle: const Text('Connect your AniList account'),
                  trailing: FilledButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const AniListLoginWebViewScreen(),
                      ),
                    ),
                    child: const Text('Login to AniList'),
                  ),
                ),
              SwitchListTile.adaptive(
                title: const Text('Auto-sync progress to AniList'),
                value: settings.autoSyncProgressToAniList,
                onChanged: controller.setAutoSyncProgressToAniList,
              ),
              SwitchListTile.adaptive(
                title: const Text('Fetch private lists'),
                value: settings.fetchPrivateLists,
                onChanged: controller.setFetchPrivateLists,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
