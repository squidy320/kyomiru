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
            GlassButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const AniListLoginWebViewScreen()),
              ),
              child: const Text('Connect AniList',
                  style: TextStyle(fontWeight: FontWeight.w700)),
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
      future: client.me(token).then((u) async => [
            u,
            await client.librarySections(token, userId: u.id),
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

  bool get _showProgress {
    final t = section.title.toLowerCase();
    return t.contains('current') || t.contains('watching');
  }

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
                  child: _AnimePosterCard(
                    media: e.media,
                    progressText: _showProgress
                        ? '${e.progress}${e.media.episodes != null ? ' / ${e.media.episodes}' : ''}'
                        : null,
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

class _AnimePosterCard extends StatelessWidget {
  const _AnimePosterCard({required this.media, this.progressText});

  final AniListMedia media;
  final String? progressText;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (media.cover.best != null)
            Image.network(media.cover.best!, fit: BoxFit.cover)
          else
            Container(color: const Color(0x22111111)),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Color(0xD80B0F1D)],
                stops: [0.52, 1],
              ),
            ),
          ),
          Positioned(
            top: 10,
            right: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xD8000000),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                media.averageScore?.toString() ?? 'NR',
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
              ),
            ),
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 12,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  media.title.best,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w900, fontSize: 20),
                ),
                if (progressText != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Watched: $progressText',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                      color: Color(0xFFE5E7EB),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
