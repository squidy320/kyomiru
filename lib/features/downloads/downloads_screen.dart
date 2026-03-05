import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/glass_widgets.dart';
import '../../core/haptics.dart';
import '../../services/download_manager.dart';
import '../player/player_screen.dart';

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
      child: _UnifiedDownloadsView(downloadsBox: downloadsBox),
    );
  }
}

class _SeriesDownloads {
  const _SeriesDownloads({
    required this.title,
    required this.items,
  });

  final String title;
  final List<DownloadItem> items;

  String? get coverImageUrl {
    for (final item in items) {
      final cover = item.coverImageUrl?.trim();
      if (cover != null && cover.isNotEmpty) return cover;
    }
    return null;
  }

  int get doneCount => items.where((i) => i.status == 'done').length;
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
}

class _UnifiedDownloadsView extends ConsumerWidget {
  const _UnifiedDownloadsView({required this.downloadsBox});

  final Box downloadsBox;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          grouped.putIfAbsent(item.animeTitle, () => []).add(item);
        }
        final series = grouped.entries
            .map(
              (e) => _SeriesDownloads(
                title: e.key,
                items: [...e.value]..sort((a, b) => a.episode.compareTo(b.episode)),
              ),
            )
            .toList()
          ..sort((a, b) => a.title.compareTo(b.title));

        final doneCount = items.where((i) => i.status == 'done').length;
        final activeCount = items.length - doneCount;

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
          children: [
            Text('Downloads', style: Theme.of(context).textTheme.displaySmall),
            Text(
              '$activeCount active | $doneCount on device',
              style: const TextStyle(color: Color(0xFFA1A8BC)),
            ),
            const SizedBox(height: 14),
            if (series.isEmpty)
              const GlassCard(
                child: Text('No downloads yet.'),
              )
            else
              ...series.map(
                (s) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _seriesCard(context, ref, s),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _seriesCard(BuildContext context, WidgetRef ref, _SeriesDownloads series) {
    final progress = series.seriesProgress;
    final hasActive = series.activeCount > 0;
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _openSeriesSheet(context, ref, series),
      child: GlassCard(
        borderRadius: 18,
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: 132,
                height: 76,
                child: (series.coverImageUrl == null || series.coverImageUrl!.isEmpty)
                    ? const ColoredBox(color: Color(0x22111111))
                    : Image.network(
                        series.coverImageUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            const ColoredBox(color: Color(0x22111111)),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    series.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${series.doneCount}/${series.totalCount} on device',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFFA1A8BC),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
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
                  const SizedBox(height: 4),
                  Text(
                    hasActive
                        ? 'Series download progress ${(progress * 100).round()}%'
                        : 'Library ready',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFFA1A8BC),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.keyboard_arrow_right_rounded, color: Colors.white70),
          ],
        ),
      ),
    );
  }

  Future<void> _openSeriesSheet(
    BuildContext context,
    WidgetRef ref,
    _SeriesDownloads series,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final maxHeight = MediaQuery.of(sheetContext).size.height * 0.78;
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
            child: GlassContainer(
              borderRadius: 24,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: SizedBox(
                height: maxHeight,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            series.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        _pillIconButton(
                          icon: Icons.close_rounded,
                          onTap: () => Navigator.of(sheetContext).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${series.doneCount}/${series.totalCount} episodes on device',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFA1A8BC),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: ListView.separated(
                        itemCount: series.items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, index) {
                          final item = series.items[index];
                          return _episodeRow(
                            context: context,
                            ref: ref,
                            item: item,
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _episodeRow({
    required BuildContext context,
    required WidgetRef ref,
    required DownloadItem item,
  }) {
    final onDevice = item.status == 'done';
    final size = _formatBytes(
      item.totalBytes > 0 ? item.totalBytes : item.downloadedBytes,
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFA1E1E1E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              color: Colors.white.withValues(alpha: 0.06),
              border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            ),
            child: Text(
              '${item.episode}',
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 13,
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
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  onDevice ? 'On Device | $size' : 'Streaming | $size',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFFA1A8BC),
                  ),
                ),
                if (!onDevice) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: SizedBox(
                      height: 3,
                      child: LinearProgressIndicator(
                        value: item.progress.clamp(0.0, 1.0),
                        color: const Color(0xFF60A5FA),
                        backgroundColor: Colors.white10,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            onDevice ? Icons.phone_iphone_rounded : Icons.cloud_outlined,
            size: 20,
            color: onDevice ? const Color(0xFF86EFAC) : const Color(0xFF93C5FD),
          ),
          const SizedBox(width: 8),
          if (onDevice)
            _pillIconButton(
              icon: Icons.play_arrow_rounded,
              onTap: () => _playDownloadedEpisode(context, ref, item),
            )
          else
            _queueActionButton(ref, item),
          const SizedBox(width: 6),
          _pillIconButton(
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

  Widget _queueActionButton(WidgetRef ref, DownloadItem item) {
    if (item.status == 'downloading') {
      return _pillIconButton(
        icon: Icons.close_rounded,
        onTap: () {
          hapticTap();
          ref
              .read(downloadControllerProvider.notifier)
              .cancel(item.mediaId, item.episode);
        },
      );
    }
    if (item.status == 'paused' ||
        (item.status == 'error' && item.resumable)) {
      return _pillIconButton(
        icon: Icons.refresh_rounded,
        onTap: () {
          hapticTap();
          ref
              .read(downloadControllerProvider.notifier)
              .resume(item.mediaId, item.episode);
        },
      );
    }
    return _pillIconButton(
      icon: Icons.cloud_download_rounded,
      onTap: () {},
    );
  }

  Future<void> _playDownloadedEpisode(
    BuildContext context,
    WidgetRef ref,
    DownloadItem item,
  ) async {
    hapticTap();
    final localFile = await ref
        .read(downloadControllerProvider.notifier)
        .getLocalEpisodeByMedia(item.mediaId, item.episode);
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
        ),
      ),
    );
  }
}

Widget _pillIconButton({
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
