import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_settings_state.dart';

class GlassCard extends ConsumerWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.borderRadius = 16,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final glassEnabled = settings.glass != 'Off';
    final sigma = switch (settings.intensity) {
      'Low' => 6.0,
      'Medium' => 10.0,
      _ => 14.0,
    };
    final overlayAlpha = switch (settings.intensity) {
      'Low' => 0.72,
      'Medium' => 0.62,
      _ => 0.55,
    };

    final content = Container(
      decoration: BoxDecoration(
        color: const Color(0xFF121A30).withValues(alpha: overlayAlpha),
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: const Color(0x40FFFFFF)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      padding: padding,
      child: child,
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: glassEnabled
          ? BackdropFilter(
              filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
              child: content,
            )
          : content,
    );
  }
}

class GlassScaffoldBackground extends ConsumerWidget {
  const GlassScaffoldBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final background =
        settings.oled ? const Color(0xFF000000) : const Color(0xFF040714);

    return Stack(
      children: [
        Container(color: background),
        Positioned(
          top: -120,
          left: -80,
          child: Container(
            width: 280,
            height: 280,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [Color(0x447C6CFF), Colors.transparent],
              ),
            ),
          ),
        ),
        Positioned(
          bottom: -140,
          right: -100,
          child: Container(
            width: 320,
            height: 320,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [Color(0x3326B9FF), Colors.transparent],
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}
