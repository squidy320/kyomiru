import 'dart:ui';

import 'package:flutter/material.dart';

class AppleMaterialOverlay extends StatelessWidget {
  const AppleMaterialOverlay({
    super.key,
    this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(18)),
    this.padding = const EdgeInsets.all(12),
    this.blurSigma = 40,
    this.saturation = 1.5,
    this.borderWidth = 1,
  });

  final Widget? child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry padding;
  final double blurSigma;
  final double saturation;
  final double borderWidth;

  static List<double> _saturationMatrix(double saturation) {
    final inv = 1.0 - saturation;
    final r = 0.213 * inv;
    final g = 0.715 * inv;
    final b = 0.072 * inv;

    return <double>[
      r + saturation,
      g,
      b,
      0,
      0,
      r,
      g + saturation,
      b,
      0,
      0,
      r,
      g,
      b + saturation,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final darkMode = Theme.of(context).brightness == Brightness.dark;
    final fillColor = darkMode
        ? Colors.black.withValues(alpha: 0.20)
        : Colors.white.withValues(alpha: 0.10);

    return ClipRRect(
      borderRadius: borderRadius,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColorFiltered(
            colorFilter: ColorFilter.matrix(_saturationMatrix(saturation)),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
              child: const SizedBox.expand(),
            ),
          ),
          Container(color: fillColor),
          IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: borderRadius,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.20),
                    Colors.white.withValues(alpha: 0.05),
                  ],
                ),
              ),
              child: Container(
                margin: EdgeInsets.all(borderWidth),
                decoration: BoxDecoration(
                  borderRadius: borderRadius,
                  color: Colors.transparent,
                ),
              ),
            ),
          ),
          if (child != null) Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}
