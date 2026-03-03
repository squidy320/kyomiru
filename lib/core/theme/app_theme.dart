import 'package:flutter/material.dart';

import '../../state/app_settings_state.dart';

class AppColors {
  static const background = Color(0xFF000000);
  static const backgroundSoft = Color(0xFF0B0B0D);
  static const surface = Color(0xFF1C1C1E);
  static const surfaceSoft = Color(0xFF232326);
  static const text = Color(0xFFF5F5F7);
  static const textMuted = Color(0xFF9A9AA0);
}

const _accentMap = {
  'Midnight': Color(0xFF7A5CFF),
  'Ocean': Color(0xFF37A6FF),
  'Rose': Color(0xFFFF5D8F),
  'Emerald': Color(0xFF3AD79F),
  'Sunset': Color(0xFFFF8D52),
};

ThemeData buildKyomiruTheme(AppSettings settings) {
  final base = ThemeData.dark(useMaterial3: true);
  final accent = _accentMap[settings.theme] ?? _accentMap['Midnight']!;
  final appBg = !settings.enableDynamicColors
      ? Colors.black
      : (settings.isOledBlack ? Colors.black : const Color(0xFF121212));

  return base.copyWith(
    useMaterial3: true,
    scaffoldBackgroundColor: appBg,
    splashFactory: InkSparkle.splashFactory,
    colorScheme: base.colorScheme.copyWith(
      primary: accent,
      secondary: accent,
      surface: AppColors.surface,
      surfaceContainerHighest: AppColors.surfaceSoft,
      onSurface: AppColors.text,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: appBg,
      surfaceTintColor: appBg,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        color: AppColors.text,
        fontWeight: FontWeight.w700,
        fontSize: 22,
      ),
      iconTheme: const IconThemeData(color: AppColors.text),
    ),
    textTheme: base.textTheme
        .apply(
          bodyColor: AppColors.text,
          displayColor: AppColors.text,
        )
        .copyWith(
          displaySmall:
              const TextStyle(fontWeight: FontWeight.w700, fontSize: 28),
          headlineMedium:
              const TextStyle(fontWeight: FontWeight.w700, fontSize: 24),
          titleLarge: const TextStyle(fontWeight: FontWeight.w700, fontSize: 22),
          titleMedium:
              const TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
          bodyLarge:
              const TextStyle(fontSize: 16, fontWeight: FontWeight.w400),
          bodyMedium: const TextStyle(
            fontSize: 14,
            height: 1.3,
            fontWeight: FontWeight.w400,
          ),
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
      backgroundColor: const Color(0xFF1C1C1E).withValues(alpha: 0.96),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      filled: true,
      fillColor: const Color(0x661C1C1E),
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
