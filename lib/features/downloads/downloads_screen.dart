import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/glass_widgets.dart';
import '../../core/haptics.dart';
import '../../core/image_cache.dart';
import '../../models/anilist_models.dart';
import '../../services/download_manager.dart';
import '../../state/auth_state.dart';
import '../player/player_screen.dart';

const double _kCardWidth = 152;
const double _kCardHeight = 232;

final anilistDownloadedWatchedProgressProvider =
    FutureProvider.family<int, int>((ref, mediaId) async {
  final auth = ref.watch(authControllerProvider);
  final token = auth.token;
  if (token == null || token.isEmpty) return 0;
  final entry =
      await ref.watch(anilistClientProvider).trackingEntry(token, mediaId);
  return (entry?.progress ?? 0).clamp(0, 99999);
});

class DownloadsScreen extends ConsumerStatefulWidget {
  const DownloadsScreen({super.key});

  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen> {
  @override
  Widget build(BuildContext context) {
    final downloadsBox = Hive.box('downloads');
    return SafeArea(
      child: _DownloadsLibraryView(downloadsBox: downloadsBox),
    );
  }
}

class _DownloadedSeries {
  const _DownloadedSeries({
    required this.mediaId,
    required this.title,
    required this.items,
    this.cachedMedia,
  });

  final int mediaId;
  final String title;
  final List<DownloadItem> items;
  final AniListMedia? cachedMedia;

  List<DownloadItem> get downloadedEpisodes =>
      items.where((i) => i.status == 'done').toList()
        ..sort((a, b) => a.episode.compareTo(b.episode));

  int get doneCount => downloadedEpisodes.length;
  int get totalCount => items.length;
  int get activeCount => items.where((i) => i.status != 'done').length;

  double get seriesProgress {
    if (items.isEmpty) return 0;
    var sum = 0.0;
    for (final item in items) {
      sum += item.status == 'done' ? 1.0 : item.progress.clamp(0.0, 1.0);
    }
    return (sum / items.length).clamp(0.0, 1.0);
  }

  String? get coverUrl {
    final cachedCover = cachedMedia?.cover.best?.trim();
    if (cachedCover != null && cachedCover.isNotEmpty) return cachedCover;
    for (final item in items) {
      final cover = item.coverImageUrl?.trim();
      if (cover != null && cover.isNotEmpty) return cover;
    }
    return null;
  }

  String? get bannerUrl {
    final b = cachedMedia?.bannerImage?.trim();
    if (b != null && b.isNotEmpty) return b;
    return coverUrl;
  }
}

class _DownloadsLibraryView extends ConsumerWidget {
  const _DownloadsLibraryView({required this.downloadsBox});

  final Box downloadsBox;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaBox = Hive.isBoxOpen('anilist_media_cache')
        ? Hive.box('anilist_media_cache')
        : null;
    return ValueListenableBuilder(
      valueListenable: downloadsBox.listenable(),
      builder: (context, _, __) {
        final items = <DownloadItem>[];
        for (final key in downloadsBox.keys) {
          final raw = downloadsBox.get(key);
          if (raw is Map) items.add(DownloadItem.fromJson(raw));
        }
        items.sort((a, b) {
          final byTitle = a.animeTitle.compareTo(b.animeTitle);
          if (byTitle != 0) return byTitle;
          return a.episode.compareTo(b.episode);
        });

        final grouped = <String, List<DownloadItem>>{};
        for (final item in items) {
          final groupKey = item.mediaId > 0
              ? 'id:${item.mediaId}'
              : 'title:${item.animeTitle.toLowerCase()}';
          grouped.putIfAbsent(groupKey, () => []).add(item);
        }

        final series = grouped.values.map((group) {
          final first = group.first;
          final media = _readCachedMedia(mediaBox, first.mediaId);
          return _DownloadedSeries(
            mediaId: first.mediaId,
            title: media?.title.best ?? first.animeTitle,
            items: [...group]..sort((a, b) => a.episode.compareTo(b.episode)),
            cachedMedia: media,
          );
        }).toList()
          ..sort((a, b) => a.title.compareTo(b.title));

        final doneCount = items.where((i) => i.status == 'done').length;
        final activeCount = items.length - doneCount;

        return ListView(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 120),
          children: [
            Text('Downloads', style: Theme.of(context).textTheme.displaySmall),
            Text(
              '$activeCount active | $doneCount downloaded',
              style: const TextStyle(color: Color(0xFFA1A8BC)),
            ),
            const SizedBox(height: 12),
            const Text(
              'Downloaded Library',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            if (series.isEmpty)
              const GlassCard(child: Text('No downloaded series yet.'))
            else
              SizedBox(
                height: _kCardHeight,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: series.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (context, index) {
                    final s = series[index];
                    return SizedBox(
                      width: _kCardWidth,
                      child: _DownloadedSeriesCard(
                        series: s,
                        onTap: () {
                          hapticTap();
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => _DownloadedSeriesScreen(series: s),
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
              ),
            if (activeCount > 0) ...[
              const SizedBox(height: 14),
              const Text(
                'Active Queue',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 10),
              ...series
                  .where((s) => s.activeCount > 0)
                  .map(
                    (s) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _ActiveSeriesTile(series: s),
                    ),
                  ),
            ],
          ],
        );
      },
    );
  }

  AniListMedia? _readCachedMedia(Box<dynamic>? mediaBox, int mediaId) {
    if (mediaBox == null || mediaId <= 0) return null;
    final raw = mediaBox.get(mediaId.toString());
    if (raw is! Map) return null;
    final data = raw['data'];
    if (data is! Map) return null;
    try {
      return AniListMedia.fromJson(Map<String, dynamic>.from(data));
    } catch (_) {
      return null;
    }
  }
}

class _DownloadedSeriesCard extends StatelessWidget {
  const _DownloadedSeriesCard({
    required this.series,
    required this.onTap,
  });

  final _DownloadedSeries series;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final progress = series.seriesProgress;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFA1E1E1E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (series.coverUrl != null)
                KyomiruImageCache.image(
                  series.coverUrl!,
                  fit: BoxFit.cover,
                  error: const ColoredBox(color: Color(0x22111111)),
                )
              else
                const ColoredBox(color: Color(0x22111111)),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.80),
                      ],
                      stops: const [0.45, 1.0],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 10,
                right: 10,
                bottom: 10,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      series.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${series.doneCount}/${series.totalCount} downloaded',
                      style: const TextStyle(
                        color: Color(0xFFD1D5DB),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: SizedBox(
                        height: 3,
                        child: LinearProgressIndicator(
                          value: progress,
                          color: const Color(0xFF60A5FA),
                          backgroundColor: Colors.white24,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActiveSeriesTile extends StatelessWidget {
  const _ActiveSeriesTile({required this.series});

  final _DownloadedSeries series;

  @override
  Widget build(BuildContext context) {
    final progress = series.seriesProgress;
    return GlassCard(
      child: Row(
        children: [
          Expanded(
            child: Text(
              series.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 110,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: SizedBox(
                height: 4,
                child: LinearProgressIndicator(
                  value: progress,
                  color: const Color(0xFF60A5FA),
                  backgroundColor: Colors.white12,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${(progress * 100).round()}%',
            style: const TextStyle(
              color: Color(0xFFA1A8BC),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadedSeriesScreen extends ConsumerWidget {
  const _DownloadedSeriesScreen({required this.series});

  final _DownloadedSeries series;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final done = series.downloadedEpisodes;
    final isWide = MediaQuery.sizeOf(context).width > 600;
    if (isWide) {
      return _WideDownloadedSeriesScreen(series: series, done: done);
    }
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            _SeriesBannerHero(series: series),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Downloaded Episodes (${done.length})',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (done.isEmpty)
                    const GlassCard(
                      child: Text('No fully downloaded episodes in this series.'),
                    )
                  else
                    ...done.map(
                      (item) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _DownloadedEpisodeTile(item: item),
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

class _WideDownloadedSeriesScreen extends ConsumerWidget {
  const _WideDownloadedSeriesScreen({
    required this.series,
    required this.done,
  });

  final _DownloadedSeries series;
  final List<DownloadItem> done;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final banner = series.bannerUrl;
    final studio = (series.cachedMedia?.studios.isNotEmpty ?? false)
        ? series.cachedMedia!.studios.first
        : 'Offline Library';
    final description = (series.cachedMedia?.description ?? '')
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .trim();

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (banner != null)
            KyomiruImageCache.image(
              banner,
              fit: BoxFit.cover,
              error: const ColoredBox(color: Color(0x22111111)),
            )
          else
            const ColoredBox(color: Color(0x22111111)),
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x11000000),
                  Color(0xB8000000),
                  Color(0xEE090B13),
                ],
                stops: [0.0, 0.62, 1.0],
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 28, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
                  ),
                  const Spacer(flex: 4),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 760),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _wideMetaPill(
                          '${series.cachedMedia?.episodes ?? '-'} EPS  •  $studio  •  ${series.doneCount}/${series.totalCount} Downloaded',
                        ),
                        const SizedBox(height: 10),
                        if (description.isNotEmpty)
                          Text(
                            description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 14,
                              height: 1.25,
                            ),
                          ),
                        if (description.isNotEmpty) const SizedBox(height: 10),
                        Text(
                          series.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 56,
                            fontWeight: FontWeight.w800,
                            height: 0.95,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: done.isEmpty
                                    ? null
                                    : () => _playDownloadedEpisode(
                                          context,
                                          ref,
                                          done.last,
                                        ),
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(0xFF6366F1),
                                  foregroundColor: Colors.white,
                                  minimumSize: const Size(260, 54),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  textStyle: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 17,
                                  ),
                                ),
                                icon: const Icon(Icons.play_arrow_rounded, size: 24),
                                label: const Text('Play Latest'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            _iconButton(
                              icon: Icons.download_done_rounded,
                              onTap: () {},
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 42,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: const [
                        _WideSeriesChip(
                          label: 'Current Series',
                          active: true,
                        ),
                        SizedBox(width: 8),
                        _WideSeriesChip(
                          label: 'Downloaded',
                          active: false,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (done.isEmpty)
                    const GlassCard(
                      child: Text('No fully downloaded episodes in this series.'),
                    )
                  else
                    SizedBox(
                      height: 152,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: done.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 10),
                        itemBuilder: (context, index) {
                          final item = done[index];
                          return SizedBox(
                            width: 320,
                            child: _DownloadedEpisodeWideCard(
                              item: item,
                              onPlay: () => _playDownloadedEpisode(
                                context,
                                ref,
                                item,
                              ),
                              onDelete: () async {
                                HapticFeedback.mediumImpact();
                                await ref
                                    .read(downloadControllerProvider.notifier)
                                    .delete(item.mediaId, item.episode);
                              },
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _wideMetaPill(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.18),
          width: 0.5,
        ),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Future<void> _playDownloadedEpisode(
    BuildContext context,
    WidgetRef ref,
    DownloadItem item,
  ) async {
    hapticTap();
    final dm = ref.read(downloadControllerProvider.notifier);
    final localFile = await dm.getLocalEpisodeByMedia(item.mediaId, item.episode) ??
        await dm.getLocalEpisodeByTitle(item.animeTitle, item.episode);
    int? malId;
    try {
      malId = (await ref.read(anilistClientProvider).mediaDetails(item.mediaId)).idMal;
    } catch (_) {}
    if (!context.mounted) return;
    final local = localFile?.path;
    final exists = local != null && local.isNotEmpty;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          mediaId: item.mediaId,
          episodeNumber: item.episode,
          episodeTitle: '${item.animeTitle} - Episode ${item.episode}',
          sourceUrl: exists ? local : item.sourceUrl,
          headers: item.headers,
          isLocal: exists,
          mediaTitle: item.animeTitle,
          malId: malId,
        ),
      ),
    );
  }
}

class _WideSeriesChip extends StatelessWidget {
  const _WideSeriesChip({
    required this.label,
    required this.active,
  });

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: active
            ? Colors.white.withValues(alpha: 0.24)
            : Colors.black.withValues(alpha: 0.22),
        border: Border.all(
          color: active
              ? Colors.white.withValues(alpha: 0.92)
              : Colors.white.withValues(alpha: 0.20),
          width: active ? 1.0 : 0.6,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: active ? Colors.white : Colors.white70,
        ),
      ),
    );
  }
}

class _DownloadedEpisodeWideCard extends ConsumerWidget {
  const _DownloadedEpisodeWideCard({
    required this.item,
    required this.onPlay,
    required this.onDelete,
  });

  final DownloadItem item;
  final VoidCallback onPlay;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final watchedThrough =
        ref.watch(anilistDownloadedWatchedProgressProvider(item.mediaId))
            .valueOrNull ??
            0;
    final watchedInAniList =
        watchedThrough > 0 && item.episode <= watchedThrough;
    final ratio = (item.lastDurationMs > 0)
        ? (item.lastPositionMs / item.lastDurationMs).clamp(0.0, 1.0)
        : 0.0;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFA1E1E1E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _DownloadedEpisodeThumb(item: item),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.76),
                    ],
                    stops: const [0.46, 1.0],
                  ),
                ),
              ),
            ),
            Positioned(
              right: 8,
              top: 8,
              child: Row(
                children: [
                  _iconButton(
                    icon: Icons.play_arrow_rounded,
                    onTap: onPlay,
                  ),
                  const SizedBox(width: 6),
                  _iconButton(
                    icon: Icons.delete_outline_rounded,
                    onTap: onDelete,
                  ),
                ],
              ),
            ),
            Positioned(
              left: 10,
              right: 10,
              bottom: 10,
              child: Text(
                '${item.animeTitle} - Episode ${item.episode}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                  height: 1.15,
                  color: Colors.white.withValues(
                    alpha: watchedInAniList ? 0.52 : 1.0,
                  ),
                ),
              ),
            ),
            if (ratio > 0)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  height: 2.5,
                  color: Colors.white24,
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: ratio,
                    child: Container(color: const Color(0xFF60A5FA)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}


class _SeriesBannerHero extends StatelessWidget {
  const _SeriesBannerHero({required this.series});

  final _DownloadedSeries series;

  @override
  Widget build(BuildContext context) {
    final banner = series.bannerUrl;
    final type = (series.cachedMedia?.mediaType ?? 'ANIME').toUpperCase();
    final score = series.cachedMedia?.averageScore;
    return SizedBox(
      height: 260,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (banner != null)
            KyomiruImageCache.image(
              banner,
              fit: BoxFit.cover,
              error: const ColoredBox(color: Color(0x22111111)),
            )
          else
            const ColoredBox(color: Color(0x22111111)),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.20),
                    Colors.black.withValues(alpha: 0.88),
                    const Color(0xFF000000),
                  ],
                  stops: const [0.0, 0.72, 1.0],
                ),
              ),
            ),
          ),
          Positioned(
            top: 10,
            left: 10,
            child: Material(
              color: Colors.black.withValues(alpha: 0.38),
              borderRadius: BorderRadius.circular(999),
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => Navigator.of(context).pop(),
                child: const Padding(
                  padding: EdgeInsets.all(8),
                  child: Icon(Icons.arrow_back_rounded, color: Colors.white),
                ),
              ),
            ),
          ),
          Positioned(
            left: 14,
            right: 14,
            bottom: 14,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  series.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w900,
                    height: 1.04,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _metaPill(type),
                    _metaPill('${series.doneCount}/${series.totalCount} Downloaded'),
                    if (score != null) _metaPill('$score% Score'),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static Widget _metaPill(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _DownloadedEpisodeTile extends ConsumerWidget {
  const _DownloadedEpisodeTile({required this.item});

  final DownloadItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final watchedThrough =
        ref.watch(anilistDownloadedWatchedProgressProvider(item.mediaId))
            .valueOrNull ??
            0;
    final watchedInAniList =
        watchedThrough > 0 && item.episode <= watchedThrough;
    final size =
        _formatBytes(item.totalBytes > 0 ? item.totalBytes : item.downloadedBytes);
    final ratio = (item.lastDurationMs > 0)
        ? (item.lastPositionMs / item.lastDurationMs).clamp(0.0, 1.0)
        : 0.0;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFA1E1E1E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 136,
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _DownloadedEpisodeThumb(item: item),
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.42),
                            ],
                            stops: const [0.58, 1.0],
                          ),
                        ),
                      ),
                    ),
                    if (ratio > 0)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          height: 2.5,
                          color: Colors.white24,
                          child: FractionallySizedBox(
                            alignment: Alignment.centerLeft,
                            widthFactor: ratio,
                            child: Container(color: const Color(0xFF60A5FA)),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Episode ${item.episode}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Colors.white.withValues(
                      alpha: watchedInAniList ? 0.52 : 1.0,
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  size,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFA1A8BC),
                  ),
                ),
              ],
            ),
          ),
          _iconButton(
            icon: Icons.play_arrow_rounded,
            onTap: () => _playDownloadedEpisode(context, ref, item),
          ),
          const SizedBox(width: 6),
          _iconButton(
            icon: Icons.delete_outline_rounded,
            onTap: () async {
              HapticFeedback.mediumImpact();
              await ref
                  .read(downloadControllerProvider.notifier)
                  .delete(item.mediaId, item.episode);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _playDownloadedEpisode(
    BuildContext context,
    WidgetRef ref,
    DownloadItem item,
  ) async {
    hapticTap();
    final dm = ref.read(downloadControllerProvider.notifier);
    final localFile = await dm.getLocalEpisodeByMedia(item.mediaId, item.episode) ??
        await dm.getLocalEpisodeByTitle(item.animeTitle, item.episode);
    int? malId;
    try {
      malId = (await ref.read(anilistClientProvider).mediaDetails(item.mediaId)).idMal;
    } catch (_) {}
    if (!context.mounted) return;
    final local = localFile?.path;
    final exists = local != null && local.isNotEmpty;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          mediaId: item.mediaId,
          episodeNumber: item.episode,
          episodeTitle: '${item.animeTitle} - Episode ${item.episode}',
          sourceUrl: exists ? local : item.sourceUrl,
          headers: item.headers,
          isLocal: exists,
          mediaTitle: item.animeTitle,
          malId: malId,
        ),
      ),
    );
  }
}

class _DownloadedEpisodeThumb extends ConsumerWidget {
  const _DownloadedEpisodeThumb({required this.item});

  final DownloadItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localThumb = ref.watch(
      localEpisodeArtworkFileProvider(
        LocalEpisodeArtworkQuery(mediaId: item.mediaId, episode: item.episode),
      ),
    );
    final file = localThumb.valueOrNull;
    if (file != null) {
      return Image.file(
        file,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _fallback(item),
      );
    }
    return _fallback(item);
  }

  Widget _fallback(DownloadItem item) {
    final cover = item.coverImageUrl?.trim();
    if (cover != null && cover.isNotEmpty) {
      return KyomiruImageCache.image(
        cover,
        fit: BoxFit.cover,
        error: const ColoredBox(color: Color(0x22111111)),
      );
    }
    return const ColoredBox(color: Color(0x22111111));
  }
}

Widget _iconButton({
  required IconData icon,
  required VoidCallback onTap,
}) {
  return Material(
    color: const Color(0xFA1E1E1E),
    borderRadius: BorderRadius.circular(999),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Icon(icon, color: Colors.white, size: 18),
      ),
    ),
  );
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 MB';
  final mb = bytes / (1024 * 1024);
  return '${mb.toStringAsFixed(1)} MB';
}
