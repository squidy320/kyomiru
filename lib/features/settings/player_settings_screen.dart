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

    const qualityOptions = <String>['1080p', '720p', '480p', '360p', 'auto'];
    const audioOptions = <String>['Sub', 'Dub', 'Any'];
    const seekOptions = <int>[5, 10, 15];
    final qualityValue = qualityOptions.contains(settings.defaultQuality)
        ? settings.defaultQuality
        : 'auto';
    final audioValue = audioOptions.contains(settings.defaultAudio)
        ? settings.defaultAudio
        : 'Sub';

    return Scaffold(
      appBar: AppBar(title: const Text('Player & Quality')),
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
                  value: qualityValue,
                  items: qualityOptions
                      .map(
                        (q) => DropdownMenuItem<String>(
                          value: q,
                          child: Text(q == 'auto' ? 'Auto' : q),
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
                title: const Text('Default Audio'),
                subtitle: Text(audioValue),
                trailing: DropdownButton<String>(
                  value: audioValue,
                  items: audioOptions
                      .map(
                        (a) => DropdownMenuItem<String>(
                          value: a,
                          child: Text(a),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    controller.setDefaultAudio(value);
                  },
                ),
              ),
              SwitchListTile.adaptive(
                title: const Text('Choose Stream Every Time'),
                subtitle: const Text(
                  'Show stream picker on every Play/Download action',
                ),
                value: settings.chooseStreamEveryTime,
                onChanged: controller.setChooseStreamEveryTime,
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
