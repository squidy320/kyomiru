import 'package:flutter/material.dart';

import '../../state/app_settings_state.dart';

class AppColors {
  static const background = Color(0xFF040714);
  static const backgroundSoft = Color(0xFF091327);
  static const surface = Color(0xFF0D1224);
  static const surfaceSoft = Color(0xFF141C33);
  static const text = Color(0xFFF4F7FF);
  static const textMuted = Color(0xFF9AA5C1);
}

const _accentMap = {
  'Midnight': Color(0xFF7C6CFF),
  'Ocean': Color(0xFF26B9FF),
  'Rose': Color(0xFFFF5FA2),
  'Emerald': Color(0xFF3DDC97),
  'Sunset': Color(0xFFFF8A3D),
};

ThemeData buildKyomiruTheme(AppSettings settings) {
  final base = ThemeData.dark(useMaterial3: true);
  final accent = _accentMap[settings.theme] ?? _accentMap['Midnight']!;
  final bg = settings.oled ? const Color(0xFF000000) : AppColors.background;

  return base.copyWith(
    scaffoldBackgroundColor: bg,
    splashFactory: settings.touchOutline
        ? InkSparkle.splashFactory
        : NoSplash.splashFactory,
    colorScheme: base.colorScheme.copyWith(
      primary: accent,
      secondary: accent,
      surface: AppColors.surface,
      onSurface: AppColors.text,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        color: AppColors.text,
        fontWeight: FontWeight.w800,
      ),
      iconTheme: const IconThemeData(color: AppColors.text),
    ),
    textTheme: base.textTheme
        .apply(
          bodyColor: AppColors.text,
          displayColor: AppColors.text,
        )
        .copyWith(
          titleLarge:
              const TextStyle(fontWeight: FontWeight.w800, fontSize: 20),
          titleMedium:
              const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
          bodyMedium: const TextStyle(fontSize: 14, height: 1.25),
          bodySmall: const TextStyle(fontSize: 12, color: AppColors.textMuted),
        ),
    cardColor: AppColors.surface,
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      indicatorColor: accent.withValues(alpha: 0.22),
      labelTextStyle: const WidgetStatePropertyAll(
        TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: const Color(0xFF12182A).withValues(alpha: 0.94),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      filled: true,
      fillColor: const Color(0x6611182B),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: accent.withValues(alpha: 0.45)),
      ),
    ),
  );
}
