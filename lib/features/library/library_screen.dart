import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/glass_widgets.dart';
import '../../features/auth/anilist_login_webview_screen.dart';
import '../../features/details/details_screen.dart';
import '../../models/anilist_models.dart';
import '../../state/auth_state.dart';

class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);

    if (auth.loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (auth.token == null || auth.token!.isEmpty) {
      return SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('Library',
                style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900)),
            const SizedBox(height: 12),
            const GlassCard(
              child: Text(
                  'No account connected. Sign in with AniList to sync lists and tracking.'),
            ),
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

    return _LibraryDataView(token: auth.token!);
  }
}

class _LibraryDataView extends ConsumerWidget {
  const _LibraryDataView({required this.token});

  final String token;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(anilistClientProvider);

    return FutureBuilder<List<AniListLibraryEntry>>(
      future: client.libraryCurrent(token),
      builder: (context, snap) {
        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text('Library',
                  style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900)),
              const SizedBox(height: 12),
              if (snap.connectionState == ConnectionState.waiting)
                const Center(child: CircularProgressIndicator())
              else if (snap.hasError)
                GlassCard(child: Text('Failed loading library: ${snap.error}'))
              else if ((snap.data ?? []).isEmpty)
                const GlassCard(child: Text('No current watching entries.'))
              else
                ...snap.data!.map(
                  (e) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: GestureDetector(
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => DetailsScreen(mediaId: e.media.id)),
                      ),
                      child: GlassCard(
                        child: Row(
                          children: [
                            Container(
                              width: 56,
                              height: 78,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                image: e.media.cover.best != null
                                    ? DecorationImage(
                                        image:
                                            NetworkImage(e.media.cover.best!),
                                        fit: BoxFit.cover,
                                      )
                                    : null,
                                color: const Color(0x22111111),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    e.media.title.best,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                      'Progress ${e.progress}${e.media.episodes != null ? ' / ${e.media.episodes}' : ''}'),
                                ],
                              ),
                            ),
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
