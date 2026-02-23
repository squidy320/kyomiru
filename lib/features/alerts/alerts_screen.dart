import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/glass_widgets.dart';
import '../../features/auth/anilist_login_webview_screen.dart';
import '../../features/details/details_screen.dart';
import '../../models/anilist_models.dart';
import '../../state/auth_state.dart';

class AlertsScreen extends ConsumerWidget {
  const AlertsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    if (auth.loading) return const Center(child: CircularProgressIndicator());

    if (auth.token == null || auth.token!.isEmpty) {
      return SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('Alerts',
                style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900)),
            const SizedBox(height: 12),
            const GlassCard(
                child: Text('Connect AniList to see notifications.')),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const AniListLoginWebViewScreen()),
              ),
              child: const Text('Connect AniList'),
            ),
          ],
        ),
      );
    }

    final client = ref.watch(anilistClientProvider);
    return FutureBuilder<List<AniListNotificationItem>>(
      future: client.notifications(auth.token!),
      builder: (context, snap) {
        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('Alerts',
                  style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900)),
              const SizedBox(height: 12),
              if (snap.connectionState == ConnectionState.waiting)
                const Center(child: CircularProgressIndicator())
              else if (snap.hasError)
                GlassCard(
                    child: Text('Notification load failed: ${snap.error}'))
              else if ((snap.data ?? []).isEmpty)
                const GlassCard(child: Text('No notifications.'))
              else
                ...snap.data!.map(
                  (n) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: GestureDetector(
                      onTap: n.media == null
                          ? null
                          : () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) =>
                                        DetailsScreen(mediaId: n.media!.id)),
                              ),
                      child: GlassCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(n.media?.title.best ?? n.type,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(height: 4),
                            Text(n.context ?? n.type),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
