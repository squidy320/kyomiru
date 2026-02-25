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
            const Text('Notifications',
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
    final unread = ref.watch(unreadAlertsProvider).valueOrNull ?? 0;

    return FutureBuilder<List<AniListNotificationItem>>(
      future: client.notifications(auth.token!),
      builder: (context, snap) {
        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('Notifications',
                  style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900)),
              const SizedBox(height: 4),
              Text(
                'AniList unread: $unread',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFFA1A8BC),
                ),
              ),
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
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _NotificationTile(item: n),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.item});

  final AniListNotificationItem item;

  String _timeAgo(int unixSeconds) {
    if (unixSeconds <= 0) return 'now';
    final created = DateTime.fromMillisecondsSinceEpoch(unixSeconds * 1000);
    final diff = DateTime.now().difference(created);
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    final weeks = (diff.inDays / 7).floor();
    return '${weeks}w ago';
  }

  String _titleFor(AniListNotificationItem n) {
    final lower = n.type.toLowerCase();
    if (lower.contains('airing')) {
      final mediaTitle = n.media?.title.best ?? 'Episode update';
      if (n.episode != null) return '$mediaTitle aired episode ${n.episode}';
      return n.context ?? mediaTitle;
    }
    if (lower.contains('activity_like')) {
      return '${n.userName ?? 'Someone'} liked your activity.';
    }
    if (lower.contains('activity_reply_like')) {
      return '${n.userName ?? 'Someone'} liked your reply.';
    }
    if (lower.contains('activity_reply')) {
      return '${n.userName ?? 'Someone'} replied to your activity.';
    }
    if (lower.contains('following')) {
      return '${n.userName ?? 'Someone'} started following you.';
    }
    return n.context ?? n.media?.title.best ?? n.type;
  }

  @override
  Widget build(BuildContext context) {
    final imageUrl = item.media?.cover.best ?? item.userAvatar;
    final subtitle = '${item.type.toLowerCase()} • ${_timeAgo(item.createdAt)}';

    return GestureDetector(
      onTap: item.media == null
          ? null
          : () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DetailsScreen(mediaId: item.media!.id),
                ),
              ),
      child: GlassCard(
        borderRadius: 14,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 68,
                height: 68,
                child: imageUrl == null || imageUrl.isEmpty
                    ? const ColoredBox(
                        color: Color(0x221E2335),
                        child: Icon(Icons.notifications_outlined,
                            color: Color(0xFFA1A8BC)),
                      )
                    : Image.network(imageUrl, fit: BoxFit.cover),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _titleFor(item),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 14,
                      color: Color(0xFFA1A8BC),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
