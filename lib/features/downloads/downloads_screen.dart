import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

import '../../core/glass_widgets.dart';
import '../../core/haptics.dart';
import '../../core/liquid_glass_preset.dart';
import '../../services/download_manager.dart';
import '../../state/app_settings_state.dart';
import '../player/player_screen.dart';

class DownloadsScreen extends ConsumerStatefulWidget {
  const DownloadsScreen({super.key});

  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen> {
  bool _queueInitialized = false;
  String? _selectedSeries;

  List<DownloadItem> _itemsFromBox(Box box) {
    final out = <DownloadItem>[];
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw is Map) out.add(DownloadItem.fromJson(raw));
    }
    out.sort((a, b) => a.animeTitle.compareTo(b.animeTitle));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final downloadsBox = Hive.box('downloads');
    final settings = ref.watch(appSettingsProvider);

    return SafeArea(
      child: DefaultTabController(
        length: 2,
        initialIndex: 0,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: ValueListenableBuilder(
                valueListenable: downloadsBox.listenable(),
                builder: (context, _, __) {
                  final items = _itemsFromBox(downloadsBox);
                  final active = items.where((e) => e.status != 'done').length;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Downloads',
                        style: Theme.of(context).textTheme.displaySmall,
                      ),
                      Text(
                        '$active active',
                        style: const TextStyle(color: Color(0xFFA1A8BC)),
                      ),
                    ],
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: LiquidGlass.withOwnLayer(
                settings:
                    kyomiruLiquidGlassSettings(isOledBlack: settings.isOledBlack),
                shape: const LiquidRoundedSuperellipse(borderRadius: 16),
                child: TabBar(
                  onTap: (index) {
                    if (index == 1 && !_queueInitialized) {
                      setState(() => _queueInitialized = true);
                    }
                    if (index == 0 && _selectedSeries != null) {
                      setState(() => _selectedSeries = null);
                    }
                  },
                  dividerColor: Colors.transparent,
                  indicatorSize: TabBarIndicatorSize.tab,
                  indicator: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    color: Colors.white.withValues(alpha: 0.16),
                    boxShadow: [
                      BoxShadow(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.70),
                        blurRadius: 22,
                        spreadRadius: 1,
                      ),
                      BoxShadow(
                        color: Colors.white.withValues(alpha: 0.24),
                        blurRadius: 10,
                      ),
                    ],
                  ),
                  labelColor: Colors.white,
                  unselectedLabelColor: Colors.white70,
                  tabs: const [
                    Tab(text: 'Downloaded'),
                    Tab(text: 'Queue'),
                  ],
                ),
              ),
            ),
            Expanded(
              child: TabBarView(
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _DownloadedTab(
                    selectedSeries: _selectedSeries,
                    onSelectSeries: (value) {
                      hapticTap();
                      setState(() => _selectedSeries = value);
                    },
                    onClearSeriesSelection: () =>
                        setState(() => _selectedSeries = null),
                  ),
                  _queueInitialized
                      ? const _QueueTab()
                      : const SizedBox.shrink(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DownloadedTab extends ConsumerWidget {
  const _DownloadedTab({
    required this.selectedSeries,
    required this.onSelectSeries,
    required this.onClearSeriesSelection,
  });

  final String? selectedSeries;
  final ValueChanged<String> onSelectSeries;
  final VoidCallback onClearSeriesSelection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloadsBox = Hive.box('downloads');
    return ValueListenableBuilder(
      valueListenable: downloadsBox.listenable(),
      builder: (context, _, __) {
        final items = <DownloadItem>[];
        for (final key in downloadsBox.keys) {
          final raw = downloadsBox.get(key);
          if (raw is Map) items.add(DownloadItem.fromJson(raw));
        }
        items.sort((a, b) => a.animeTitle.compareTo(b.animeTitle));

        final library = items.where((i) => i.status == 'done').toList();
        final groups = <String, List<DownloadItem>>{};
        for (final item in library) {
          groups.putIfAbsent(item.animeTitle, () => []).add(item);
        }
        for (final g in groups.values) {
          g.sort((a, b) => a.episode.compareTo(b.episode));
        }
        final selectedItems = selectedSeries == null
            ? <DownloadItem>[]
            : (groups[selectedSeries!] ?? const []);

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: GlassButton(
                onPressed: () async {
                  for (final d in library) {
                    await ref
                        .read(downloadControllerProvider.notifier)
                        .delete(d.mediaId, d.episode);
                  }
                  onClearSeriesSelection();
                },
                child: const Text(
                  'Clear Finished',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (library.isEmpty)
              const GlassCard(child: Text('No saved episodes yet.'))
            else if (selectedSeries == null)
              GridView.count(
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 3,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                childAspectRatio: 0.62,
                shrinkWrap: true,
                children: [
                  for (final e in groups.entries)
                    GestureDetector(
                      onTap: () => onSelectSeries(e.key),
                      child: GlassCard(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: e.value.first.coverImageUrl == null
                                    ? const ColoredBox(color: Color(0x22111111))
                                    : Image.network(
                                        e.value.first.coverImageUrl!,
                                        fit: BoxFit.cover,
                                        width: double.infinity,
                                        errorBuilder: (_, __, ___) =>
                                            const ColoredBox(
                                                color: Color(0x22111111)),
                                      ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              e.key,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              '${e.value.length} episodes',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Color(0xFFA1A8BC),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              )
            else ...[
              Row(
                children: [
                  IconButton(
                    onPressed: onClearSeriesSelection,
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  Expanded(
                    child: Text(
                      selectedSeries!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ...selectedItems.map(
                (d) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: GlassCard(
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Episode ${d.episode}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w800),
                              ),
                              const Row(
                                children: [
                                  Icon(Icons.phone_iphone_rounded,
                                      size: 12, color: Color(0xFF86EFAC)),
                                  SizedBox(width: 4),
                                  Text(
                                    'Offline',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF86EFAC),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        _pillIconButton(
                          icon: Icons.phone_iphone_rounded,
                          onTap: () async {
                            hapticTap();
                            final localFile = await ref
                                .read(downloadControllerProvider.notifier)
                                .getLocalEpisodeByMedia(d.mediaId, d.episode);
                            if (!context.mounted) return;
                            final local = localFile?.path;
                            final exists = local != null && local.isNotEmpty;
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => PlayerScreen(
                                  mediaId: d.mediaId,
                                  episodeNumber: d.episode,
                                  episodeTitle:
                                      '${d.animeTitle} - Episode ${d.episode}',
                                  sourceUrl: exists ? local : d.sourceUrl,
                                  headers: d.headers,
                                  isLocal: exists,
                                  mediaTitle: d.animeTitle,
                                ),
                              ),
                            );
                          },
                        ),
                        const SizedBox(width: 8),
                        _pillIconButton(
                          icon: Icons.delete_outline_rounded,
                          onTap: () async {
                            HapticFeedback.mediumImpact();
                            await ref
                                .read(downloadControllerProvider.notifier)
                                .delete(d.mediaId, d.episode);
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _QueueTab extends ConsumerWidget {
  const _QueueTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(downloadControllerProvider);
    final queue = state.items.values.where((i) => i.status != 'done').toList()
      ..sort((a, b) => a.animeTitle.compareTo(b.animeTitle));

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 120),
      children: [
        if (queue.isEmpty)
          const GlassCard(child: Text('No active downloads.'))
        else
          ...queue.map(
            (d) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Dismissible(
                key: ValueKey('download-${d.mediaId}-${d.episode}-${d.status}'),
                direction: DismissDirection.endToStart,
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 16),
                  decoration: BoxDecoration(
                    color: Colors.red.shade700,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                onDismissed: (_) async {
                  HapticFeedback.mediumImpact();
                  await ref
                      .read(downloadControllerProvider.notifier)
                      .delete(d.mediaId, d.episode);
                },
                child: _queueTile(context, ref, d),
              ),
            ),
          ),
      ],
    );
  }
}

Widget _queueTile(BuildContext context, WidgetRef ref, DownloadItem d) {
  final accent = Theme.of(context).colorScheme.primary;
  final progress = d.progress.clamp(0, 1).toDouble();
  final percent = '${(progress * 100).toStringAsFixed(1)}%';
  final downloaded = _formatBytes(d.downloadedBytes);
  final total = d.totalBytes > 0 ? _formatBytes(d.totalBytes) : '--';
  final speed = _formatSpeed(d.speedBitsPerSecond);

  return GlassCard(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: 52,
            height: 74,
            child: d.coverImageUrl == null || d.coverImageUrl!.isEmpty
                ? const ColoredBox(color: Color(0x22111111))
                : Image.network(
                    d.coverImageUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        const ColoredBox(color: Color(0x22111111)),
                  ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                d.animeTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              Text('Episode ${d.episode}'),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: SizedBox(
                  height: 3,
                  child: LinearProgressIndicator(
                    value: progress,
                    color: accent,
                    backgroundColor: Colors.white12,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      percent,
                      style:
                          const TextStyle(fontSize: 12, color: Color(0xFFA1A8BC)),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      '$downloaded / $total',
                      textAlign: TextAlign.center,
                      style:
                          const TextStyle(fontSize: 12, color: Color(0xFFA1A8BC)),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      speed,
                      textAlign: TextAlign.end,
                      style:
                          const TextStyle(fontSize: 12, color: Color(0xFFA1A8BC)),
                    ),
                  ),
                ],
              ),
              if (d.error != null && d.error!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    d.error!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.redAccent),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        if (d.status == 'downloading')
          IconButton(
            onPressed: () {
              hapticTap();
              ref
                  .read(downloadControllerProvider.notifier)
                  .cancel(d.mediaId, d.episode);
            },
            icon: const Icon(Icons.close),
          )
        else if (d.status == 'paused' || (d.status == 'error' && d.resumable))
          IconButton(
            onPressed: () {
              hapticTap();
              ref
                  .read(downloadControllerProvider.notifier)
                  .resume(d.mediaId, d.episode);
            },
            icon: const Icon(Icons.refresh_rounded),
          )
        else
          IconButton(
            onPressed: () {
              hapticTap();
              ref
                  .read(downloadControllerProvider.notifier)
                  .delete(d.mediaId, d.episode);
            },
            icon: const Icon(Icons.delete_outline),
          ),
      ],
    ),
  );
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
        width: 38,
        height: 38,
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

String _formatSpeed(double bitsPerSecond) {
  if (bitsPerSecond <= 0) return '0 Kbps';
  final kbps = bitsPerSecond / 1000.0;
  if (kbps >= 1000) return '${(kbps / 1000).toStringAsFixed(2)} Mbps';
  return '${kbps.toStringAsFixed(0)} Kbps';
}
