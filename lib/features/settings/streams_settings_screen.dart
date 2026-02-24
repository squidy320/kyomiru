import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/glass_widgets.dart';
import '../../state/app_settings_state.dart';

class StreamsSettingsScreen extends ConsumerWidget {
  const StreamsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final controller = ref.read(appSettingsProvider.notifier);

    Widget chip({
      required String label,
      required bool selected,
      required VoidCallback onTap,
    }) {
      return GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            color: selected ? const Color(0x557C6CFF) : const Color(0x44121A30),
            border: Border.all(color: const Color(0x44FFFFFF)),
          ),
          child: Text(label,
              style:
                  const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Library & Streams')),
      body: GlassScaffoldBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            children: [
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Default Stream',
                        style: TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    const Text('Used when "Choose every time" is off.'),
                    const SizedBox(height: 12),
                    const Text('Quality',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        chip(
                          label: '1080p',
                          selected: settings.preferredQuality == '1080p',
                          onTap: () => controller.setPreferredQuality('1080p'),
                        ),
                        chip(
                          label: '720p',
                          selected: settings.preferredQuality == '720p',
                          onTap: () => controller.setPreferredQuality('720p'),
                        ),
                        chip(
                          label: '480p',
                          selected: settings.preferredQuality == '480p',
                          onTap: () => controller.setPreferredQuality('480p'),
                        ),
                        chip(
                          label: '360p',
                          selected: settings.preferredQuality == '360p',
                          onTap: () => controller.setPreferredQuality('360p'),
                        ),
                        chip(
                          label: 'Auto',
                          selected: settings.preferredQuality == 'auto',
                          onTap: () => controller.setPreferredQuality('auto'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text('Audio',
                        style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        chip(
                          label: 'Sub',
                          selected: settings.preferredAudio == 'sub',
                          onTap: () => controller.setPreferredAudio('sub'),
                        ),
                        chip(
                          label: 'Dub',
                          selected: settings.preferredAudio == 'dub',
                          onTap: () => controller.setPreferredAudio('dub'),
                        ),
                        chip(
                          label: 'Any',
                          selected: settings.preferredAudio == 'any',
                          onTap: () => controller.setPreferredAudio('any'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              GlassCard(
                child: SwitchListTile(
                  title: const Text('Choose Stream Every Time'),
                  subtitle: const Text(
                    'Show source picker on every Play/Download action.',
                  ),
                  value: settings.chooseStreamEveryTime,
                  onChanged: controller.setChooseStreamEveryTime,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
