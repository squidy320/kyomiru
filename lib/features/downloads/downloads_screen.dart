import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/glass_widgets.dart';
import '../../services/download_manager.dart';

class DownloadsScreen extends ConsumerStatefulWidget {
  const DownloadsScreen({super.key});

  @override
  ConsumerState<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends ConsumerState<DownloadsScreen> {
  int tab = 0; // 0 queue, 1 library

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(downloadControllerProvider);
    final items = state.items.values.toList()
      ..sort((a, b) => a.animeTitle.compareTo(b.animeTitle));

    final queue = items.where((i) => i.status != 'done').toList();
    final library = items.where((i) => i.status == 'done').toList();

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
        children: [
          const Text('Downloads',
              style: TextStyle(fontSize: 42, fontWeight: FontWeight.w900)),
          Text('${queue.length} active',
              style: const TextStyle(color: Color(0xFFA1A8BC))),
          const SizedBox(height: 12),
          GlassCard(
            padding: const EdgeInsets.all(4),
            child: Row(
              children: [
                Expanded(
                    child:
                        _seg('Queue', tab == 0, () => setState(() => tab = 0))),
                Expanded(
                    child: _seg(
                        'Library', tab == 1, () => setState(() => tab = 1))),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: () async {
                for (final d in library) {
                  await ref
                      .read(downloadControllerProvider.notifier)
                      .delete(d.mediaId, d.episode);
                }
              },
              child: const Text('Clear Finished'),
            ),
          ),
          const SizedBox(height: 8),
          if (tab == 0 && queue.isEmpty)
            const GlassCard(child: Text('No downloads yet.'))
          else if (tab == 1 && library.isEmpty)
            const GlassCard(child: Text('No saved episodes yet.'))
          else
            ...((tab == 0 ? queue : library).map((d) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: GlassCard(
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(d.animeTitle,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800)),
                              Text('Episode ${d.episode} | ${d.status}'),
                              if (d.status == 'downloading') ...[
                                const SizedBox(height: 6),
                                LinearProgressIndicator(
                                    value: d.progress.clamp(0, 1)),
                              ],
                              if (d.error != null)
                                Text(d.error!,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (d.status == 'downloading')
                          IconButton(
                            onPressed: () => ref
                                .read(downloadControllerProvider.notifier)
                                .cancel(d.mediaId, d.episode),
                            icon: const Icon(Icons.close),
                          )
                        else
                          IconButton(
                            onPressed: () => ref
                                .read(downloadControllerProvider.notifier)
                                .delete(d.mediaId, d.episode),
                            icon: const Icon(Icons.delete_outline),
                          ),
                      ],
                    ),
                  ),
                ))),
        ],
      ),
    );
  }

  Widget _seg(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: selected ? const Color(0x447C6CFF) : Colors.transparent,
        ),
        child: Center(
          child: Text(label,
              style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: selected ? Colors.white : const Color(0xFFA1A8BC))),
        ),
      ),
    );
  }
}
