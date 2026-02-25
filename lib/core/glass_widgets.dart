import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

import '../state/app_settings_state.dart';

class GlassCard extends ConsumerWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.borderRadius = 16,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  bool _supportsLiquidGlass(String mode) {
    if (mode == 'Off') return false;
    return !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final glassEnabled = settings.glass != 'Off';
    final liquidEnabled = _supportsLiquidGlass(settings.glass);
    final sigma = switch (settings.intensity) {
      'Low' => 6.0,
      'Medium' => 10.0,
      _ => 14.0,
    };
    final overlayAlpha = switch (settings.intensity) {
      'Low' => 0.28,
      'Medium' => 0.22,
      _ => 0.16,
    };

    final content = Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0D1224).withValues(alpha: overlayAlpha),
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: const Color(0x30FFFFFF), width: 0.8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 16,
            offset: Offset(0, 6),
          ),
        ],
      ),
      padding: padding,
      child: child,
    );

    if (liquidEnabled) {
      return LiquidGlass.withOwnLayer(
        shape: LiquidRoundedSuperellipse(borderRadius: borderRadius),
        fake: !ImageFilter.isShaderFilterSupported,
        glassContainsChild: true,
        settings: LiquidGlassSettings(
          blur: sigma,
          thickness: 10,
          lightAngle: 0.65,
          lightIntensity: 0.7,
          ambientStrength: 0.25,
          saturation: 1.15,
          glassColor: Colors.white.withValues(alpha: 0.10),
          refractiveIndex: 1.12,
        ),
        child: content,
      );
    }

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

    final base = Stack(
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

    final liquidEnabled = !kIsWeb &&
        settings.glass != 'Off' &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS);

    if (!liquidEnabled) return base;
    return LiquidGlassLayer(child: base);
  }
}
