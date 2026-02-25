import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/glass_widgets.dart';
import '../../state/app_settings_state.dart';

class AppearanceSettingsScreen extends ConsumerWidget {
  const AppearanceSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final controller = ref.read(appSettingsProvider.notifier);

    Widget chip(String label, String value, void Function() onTap) {
      final selected = value == label;
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
      appBar: GlassAppBar(
        title: const Text('Appearance'),
        leading: IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
        ),
      ),
      body: GlassScaffoldBackground(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
            children: [
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Theme',
                        style: TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    const Text(
                        'Pick the accent and tone that matches your style.'),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        chip('Midnight', settings.theme,
                            () => controller.setTheme('Midnight')),
                        chip('Ocean', settings.theme,
                            () => controller.setTheme('Ocean')),
                        chip('Rose', settings.theme,
                            () => controller.setTheme('Rose')),
                        chip('Emerald', settings.theme,
                            () => controller.setTheme('Emerald')),
                        chip('Sunset', settings.theme,
                            () => controller.setTheme('Sunset')),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Display',
                        style: TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w800)),
                    SwitchListTile(
                      title: const Text('OLED Black Mode'),
                      value: settings.oled,
                      onChanged: controller.setOled,
                    ),
                    SwitchListTile(
                      title: const Text('Compact Bottom Bar'),
                      value: settings.compactBar,
                      onChanged: controller.setCompactBar,
                    ),
                    SwitchListTile(
                      title: const Text('Touch Outline'),
                      value: settings.touchOutline,
                      onChanged: controller.setTouchOutline,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Glass Effects',
                        style: TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        chip('Auto', settings.glass,
                            () => controller.setGlass('Auto')),
                        chip('Off', settings.glass,
                            () => controller.setGlass('Off')),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      children: [
                        chip('Low', settings.intensity,
                            () => controller.setIntensity('Low')),
                        chip('Medium', settings.intensity,
                            () => controller.setIntensity('Medium')),
                        chip('High', settings.intensity,
                            () => controller.setIntensity('High')),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              GlassButton(
                onPressed: controller.reset,
                child: const Text('Reset All Customizations',
                    style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
