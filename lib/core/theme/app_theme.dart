import 'package:flutter/material.dart';

class AppColors {
  static const background = Color(0xFF050712);
  static const surface = Color(0xFF0D1120);
  static const surfaceSoft = Color(0xFF13192A);
  static const text = Color(0xFFF4F7FF);
  static const textMuted = Color(0xFF9AA5C1);
  static const accent = Color(0xFF8B5CF6);
}

ThemeData buildKyomiruTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: base.colorScheme.copyWith(
      primary: AppColors.accent,
      secondary: AppColors.accent,
      surface: AppColors.surface,
    ),
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.text,
      displayColor: AppColors.text,
    ),
    cardColor: AppColors.surface,
  );
}
