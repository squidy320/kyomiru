import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_settings_state.dart';

class PlayerSettingsScreen extends ConsumerWidget {
  const PlayerSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final controller = ref.read(appSettingsProvider.notifier);

    const qualityOptions = <String>['1080p', '720p', '480p', 'Auto'];
    const seekOptions = <int>[5, 10, 15];

    return Scaffold(
      appBar: AppBar(title: const Text('Player')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          CupertinoListSection.insetGrouped(
            backgroundColor: Colors.transparent,
            children: [
              ListTile(
                title: const Text('Default Video Quality'),
                subtitle: Text(settings.defaultQuality),
                trailing: DropdownButton<String>(
                  value: qualityOptions.contains(settings.defaultQuality)
                      ? settings.defaultQuality
                      : 'Auto',
                  items: qualityOptions
                      .map(
                        (q) => DropdownMenuItem<String>(
                          value: q,
                          child: Text(q),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    controller.setDefaultQuality(value);
                  },
                ),
              ),
              ListTile(
                title: const Text('Double Tap to Seek'),
                subtitle: Text('${settings.doubleTapSeekSeconds}s'),
                trailing: DropdownButton<int>(
                  value: seekOptions.contains(settings.doubleTapSeekSeconds)
                      ? settings.doubleTapSeekSeconds
                      : 10,
                  items: seekOptions
                      .map(
                        (s) => DropdownMenuItem<int>(
                          value: s,
                          child: Text('${s}s'),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    controller.setDoubleTapSeekSeconds(value);
                  },
                ),
              ),
              SwitchListTile.adaptive(
                title: const Text('Auto-Play Next Episode'),
                value: settings.autoPlayNextEpisode,
                onChanged: controller.setAutoPlayNextEpisode,
              ),
              SwitchListTile.adaptive(
                title: const Text('Smart Skip (AniSkip)'),
                subtitle: const Text('Automatically skip detected intros'),
                value: settings.smartSkipEnabled,
                onChanged: controller.setSmartSkipEnabled,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
