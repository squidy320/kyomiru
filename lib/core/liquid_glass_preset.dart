import 'package:flutter/material.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

LiquidGlassSettings kyomiruLiquidGlassSettings({
  required bool isOledBlack,
}) {
  return LiquidGlassSettings(
    blur: 35.0,
    thickness: 15,
    refractiveIndex: 1.02,
    saturation: 1.2,
    glassColor: isOledBlack
        ? Colors.black.withValues(alpha: 0.08)
        : Colors.white.withValues(alpha: 0.03),
  );
}
