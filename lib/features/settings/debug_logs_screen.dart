import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/app_logger.dart';
import '../../core/glass_widgets.dart';

class DebugLogsScreen extends StatelessWidget {
  const DebugLogsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug Logs'),
        actions: [
          IconButton(
            tooltip: 'Clear',
            onPressed: () {
              AppLogger.clear();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Logs cleared.')),
              );
            },
            icon: const Icon(Icons.delete_outline),
          ),
          IconButton(
            tooltip: 'Copy',
            onPressed: () async {
              await Clipboard.setData(
                  ClipboardData(text: AppLogger.dumpAsText()));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Logs copied.')),
              );
            },
            icon: const Icon(Icons.copy_outlined),
          ),
          IconButton(
            tooltip: 'Share',
            onPressed: () {
              final text = AppLogger.dumpAsText();
              if (text.trim().isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('No logs to share.')),
                );
                return;
              }
              Share.share(text, subject: 'Kyomiru debug logs');
            },
            icon: const Icon(Icons.share_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: ValueListenableBuilder<List<String>>(
            valueListenable: AppLogger.entries,
            builder: (context, items, _) {
              if (items.isEmpty) {
                return const GlassCard(
                  child: Text('No logs yet.'),
                );
              }

              return GlassCard(
                padding: const EdgeInsets.all(8),
                child: ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final line = items[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 3),
                      child: SelectableText(
                        line,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          height: 1.2,
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
