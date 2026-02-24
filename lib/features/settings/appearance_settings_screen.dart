import 'package:flutter/material.dart';

import '../../core/glass_widgets.dart';

class AppearanceSettingsScreen extends StatefulWidget {
  const AppearanceSettingsScreen({super.key});

  @override
  State<AppearanceSettingsScreen> createState() =>
      _AppearanceSettingsScreenState();
}

class _AppearanceSettingsScreenState extends State<AppearanceSettingsScreen> {
  String theme = 'Midnight';
  bool oled = true;
  bool compactBar = true;
  bool touchOutline = true;
  String glass = 'Auto';
  String intensity = 'High';

  @override
  Widget build(BuildContext context) {
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
      appBar: AppBar(title: const Text('Appearance')),
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
                        chip('Midnight', theme,
                            () => setState(() => theme = 'Midnight')),
                        chip('Ocean', theme,
                            () => setState(() => theme = 'Ocean')),
                        chip('Rose', theme,
                            () => setState(() => theme = 'Rose')),
                        chip('Emerald', theme,
                            () => setState(() => theme = 'Emerald')),
                        chip('Sunset', theme,
                            () => setState(() => theme = 'Sunset')),
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
                      value: oled,
                      onChanged: (v) => setState(() => oled = v),
                    ),
                    SwitchListTile(
                      title: const Text('Compact Bottom Bar'),
                      value: compactBar,
                      onChanged: (v) => setState(() => compactBar = v),
                    ),
                    SwitchListTile(
                      title: const Text('Touch Outline'),
                      value: touchOutline,
                      onChanged: (v) => setState(() => touchOutline = v),
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
                        chip('Auto', glass,
                            () => setState(() => glass = 'Auto')),
                        chip('Off', glass, () => setState(() => glass = 'Off')),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      children: [
                        chip('Low', intensity,
                            () => setState(() => intensity = 'Low')),
                        chip('Medium', intensity,
                            () => setState(() => intensity = 'Medium')),
                        chip('High', intensity,
                            () => setState(() => intensity = 'High')),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
