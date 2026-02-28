import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  int tab = 0; // 0 queue, 1 library
  String? _selectedSeries;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(downloadControllerProvider);
    final items = state.items.values.toList()
      ..sort((a, b) => a.animeTitle.compareTo(b.animeTitle));

    final queue = items.where((i) => i.status != 'done').toList();
    final library = items.where((i) => i.status == 'done').toList();
    final current = tab == 0 ? queue : library;
    final groups = <String, List<DownloadItem>>{};
    for (final item in library) {
      groups.putIfAbsent(item.animeTitle, () => []).add(item);
    }
    for (final g in groups.values) {
      g.sort((a, b) => a.episode.compareTo(b.episode));
    }
    final selectedItems =
        _selectedSeries == null ? <DownloadItem>[] : (groups[_selectedSeries!] ?? const []);

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        children: [
          Text('Downloads', style: Theme.of(context).textTheme.displaySmall),
          Text('${queue.length} active', style: const TextStyle(color: Color(0xFFA1A8BC))),
          const SizedBox(height: 12),
          GlassCard(
            padding: const EdgeInsets.all(4),
            child: Row(
              children: [
                Expanded(child: _seg('Queue', tab == 0, () { hapticTap(); setState(() => tab = 0); })),
                Expanded(child: _seg('Library', tab == 1, () { hapticTap(); setState(() => tab = 1); })),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: GlassButton(
              onPressed: () async {
                for (final d in library) {
                  await ref.read(downloadControllerProvider.notifier).delete(d.mediaId, d.episode);
                }
              },
              child: const Text('Clear Finished', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: 8),
          if (tab == 0 && queue.isEmpty)
            const GlassCard(child: Text('No downloads yet.'))
          else if (tab == 1 && library.isEmpty)
            const GlassCard(child: Text('No saved episodes yet.'))
          else if (tab == 1 && _selectedSeries == null)
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
                    onTap: () {
                      hapticTap();
                      setState(() => _selectedSeries = e.key);
                    },
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
                                fontSize: 12, fontWeight: FontWeight.w700),
                          ),
                          Text(
                            '${e.value.length} episodes',
                            style: const TextStyle(
                                fontSize: 11, color: Color(0xFFA1A8BC)),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            )
          else if (tab == 1 && _selectedSeries != null) ...[
            Row(
              children: [
                IconButton(
                  onPressed: () => setState(() => _selectedSeries = null),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                Expanded(
                  child: Text(
                    _selectedSeries!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ...selectedItems.map((d) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: GlassCard(
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Episode ${d.episode}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800)),
                              const Row(
                                children: [
                                  Icon(Icons.check_circle_rounded,
                                      size: 12, color: Color(0xFF86EFAC)),
                                  SizedBox(width: 4),
                                  Text('Local',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: Color(0xFF86EFAC))),
                                ],
                              ),
                            ],
                          ),
                        ),
                        _pillIconButton(
                          icon: Icons.play_arrow_rounded,
                          onTap: () async {
                            hapticTap();
                            final local = d.localFilePath;
                            final exists =
                                local != null && local.isNotEmpty && File(local).existsSync();
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => PlayerScreen(
                                  mediaId: d.mediaId,
                                  episodeNumber: d.episode,
                                  episodeTitle: '${d.animeTitle} - Episode ${d.episode}',
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
                )),
          ]
          else
            ...current.map((d) => Padding(
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
                      await ref.read(downloadControllerProvider.notifier).delete(d.mediaId, d.episode);
                    },
                    child: GlassCard(
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(d.animeTitle, style: const TextStyle(fontWeight: FontWeight.w800)),
                                Text('Episode ${d.episode} | ${d.status}'),
                                if (d.status == 'downloading') ...[
                                  const SizedBox(height: 6),
                                  LinearProgressIndicator(value: d.progress.clamp(0, 1)),
                                ],
                                if (d.error != null)
                                  Text(d.error!, maxLines: 2, overflow: TextOverflow.ellipsis),
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
                          else if (d.status == 'paused' ||
                              (d.status == 'error' && d.resumable))
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
                    ),
                  ),
                )),
        ],
      ),
    );
  }

  Widget _pillIconButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Material(
          color: Colors.black.withValues(alpha: 0.4),
          child: InkWell(
            onTap: onTap,
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Icon(icon, color: Colors.white, size: 18),
            ),
          ),
        ),
      ),
    );
  }

  Widget _seg(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: () { hapticTap(); onTap(); },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: selected ? const Color(0x447C6CFF) : Colors.transparent,
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w800,
              color: selected ? Colors.white : const Color(0xFFA1A8BC),
            ),
          ),
        ),
      ),
    );
  }
}
