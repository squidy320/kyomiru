import 'package:flutter/material.dart';

class AppColors {
  static const background = Color(0xFF040714);
  static const backgroundSoft = Color(0xFF091327);
  static const surface = Color(0xFF0D1224);
  static const surfaceSoft = Color(0xFF141C33);
  static const text = Color(0xFFF4F7FF);
  static const textMuted = Color(0xFF9AA5C1);
  static const accent = Color(0xFF7C6CFF);
}

ThemeData buildKyomiruTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.accent,
      secondary: AppColors.accent,
      surface: AppColors.surface,
      onSurface: AppColors.text,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.text,
      displayColor: AppColors.text,
    ),
    cardColor: AppColors.surface,
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: Color(0xCC0E1428),
      indicatorColor: Color(0x447C6CFF),
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xAA11182B),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0x33FFFFFF)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0x33FFFFFF)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: AppColors.accent),
      ),
    ),
  );
}
