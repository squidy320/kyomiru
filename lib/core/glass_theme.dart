import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../state/app_settings_state.dart';

class GlassTheme {
  const GlassTheme._();

  static bool isApplePlatform() {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  static bool allowsTransparency(BuildContext context, AppSettings settings) {
    if (settings.glass == 'Off') return false;
    final media = MediaQuery.of(context);
    if (media.highContrast || media.accessibleNavigation) return false;
    return true;
  }

  static double blurSigma(
    BuildContext context,
    AppSettings settings, {
    double? override,
  }) {
    if (override != null) {
      return override.clamp(2.0, 20.0);
    }
    final isApple = isApplePlatform();
    final intensity = settings.intensity;
    final base = switch (intensity) {
      'Low' => isApple ? 10.0 : 7.0,
      'Medium' => isApple ? 14.0 : 9.0,
      _ => isApple ? 18.0 : 11.0,
    };
    return base.clamp(2.0, 20.0);
  }

  static Color fallbackSurface(Brightness brightness) {
    return brightness == Brightness.dark
        ? const Color(0xFF171C2A)
        : const Color(0xFFF1F3F9);
  }

  static Color fillColor(Brightness brightness) {
    return brightness == Brightness.dark
        ? Colors.black.withValues(alpha: 0.20)
        : Colors.white.withValues(alpha: 0.10);
  }

  static LinearGradient fillGradient(Brightness brightness) {
    if (brightness == Brightness.dark) {
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: 0.22),
          Colors.white.withValues(alpha: 0.07),
        ],
      );
    }
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Colors.white.withValues(alpha: 0.35),
        Colors.white.withValues(alpha: 0.16),
      ],
    );
  }

  static LinearGradient borderGradient() {
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Colors.white.withValues(alpha: 0.36),
        Colors.white.withValues(alpha: 0.18),
      ],
    );
  }

  static List<BoxShadow> layeredShadows(Brightness brightness) {
    if (brightness == Brightness.dark) {
      return const [
        BoxShadow(
          color: Color(0x48000000),
          blurRadius: 24,
          spreadRadius: -4,
          offset: Offset(0, 12),
        ),
        BoxShadow(
          color: Color(0x1AFFFFFF),
          blurRadius: 10,
          spreadRadius: -6,
          offset: Offset(0, 1),
        ),
      ];
    }
    return const [
      BoxShadow(
        color: Color(0x2A111827),
        blurRadius: 18,
        spreadRadius: -4,
        offset: Offset(0, 8),
      ),
    ];
  }
}
