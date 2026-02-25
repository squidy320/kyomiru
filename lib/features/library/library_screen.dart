import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/glass_widgets.dart';
import '../../features/auth/anilist_login_webview_screen.dart';
import '../../features/details/details_screen.dart';
import '../../models/anilist_models.dart';
import '../../state/auth_state.dart';

const double _kCardWidth = 156;
const double _kCardHeight = 236;

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
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 100),
          children: [
            const Text('Library',
                style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900)),
            const Text('All your AniList collections',
                style: TextStyle(color: Color(0xFFA1A8BC))),
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

    return FutureBuilder<List<dynamic>>(
      future: Future.wait<dynamic>([
        client.me(token),
        client.librarySections(token),
      ]),
      builder: (context, snap) {
        final loading = snap.connectionState == ConnectionState.waiting;
        final hasError = snap.hasError;
        final user =
            !loading && !hasError ? snap.data![0] as AniListUser : null;
        final sections = !loading && !hasError
            ? snap.data![1] as List<AniListLibrarySection>
            : const <AniListLibrarySection>[];

        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 100),
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Library',
                            style: TextStyle(
                                fontSize: 34, fontWeight: FontWeight.w900)),
                        Text('All your AniList collections',
                            style: TextStyle(color: Color(0xFFA1A8BC))),
                      ],
                    ),
                  ),
                  if (user?.avatar != null)
                    CircleAvatar(
                        radius: 18,
                        backgroundImage: NetworkImage(user!.avatar!)),
                ],
              ),
              const SizedBox(height: 12),
              if (loading)
                const Center(child: CircularProgressIndicator())
              else if (hasError)
                GlassCard(child: Text('Failed loading library: ${snap.error}'))
              else if (sections.isEmpty)
                const GlassCard(child: Text('No library items found.'))
              else
                ...sections.map((section) => Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: _LibrarySection(section: section),
                    )),
            ],
          ),
        );
      },
    );
  }
}

class _LibrarySection extends StatelessWidget {
  const _LibrarySection({required this.section});

  final AniListLibrarySection section;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${section.title} (${section.items.length})',
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        SizedBox(
          height: _kCardHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: section.items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final e = section.items[index];
              return SizedBox(
                width: _kCardWidth,
                child: GestureDetector(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => DetailsScreen(mediaId: e.media.id)),
                  ),
                  child: GlassCard(
                    padding: const EdgeInsets.all(6),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: e.media.cover.best == null
                                ? Container(color: const Color(0x22111111))
                                : Image.network(e.media.cover.best!,
                                    fit: BoxFit.cover),
                          ),
                        ),
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xAA0C1324),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              e.media.averageScore?.toString() ?? 'NR',
                              style: const TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.w700),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 10,
                          right: 10,
                          bottom: 10,
                          child: Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              color: const Color(0xAA0B0F1D),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  e.media.title.best,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                      fontSize: 16),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Progress: ${e.progress}${e.media.episodes != null ? ' / ${e.media.episodes}' : ''}',
                                  style: const TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFFCDD6F7),
                                      fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
