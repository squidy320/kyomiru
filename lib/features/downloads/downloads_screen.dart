import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/glass_widgets.dart';
import '../../services/download_manager.dart';

class DownloadsScreen extends ConsumerWidget {
  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(downloadControllerProvider);
    final items = state.items.values.toList()
      ..sort((a, b) => a.animeTitle.compareTo(b.animeTitle));

    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Downloads',
              style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900)),
          const SizedBox(height: 12),
          if (items.isEmpty)
            const GlassCard(child: Text('No downloads yet.'))
          else
            ...items.map((d) {
              return Padding(
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
                                  maxLines: 2, overflow: TextOverflow.ellipsis),
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
              );
            }),
        ],
      ),
    );
  }
}
