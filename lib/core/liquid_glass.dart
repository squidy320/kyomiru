import 'dart:ui';

import 'package:flutter/material.dart';

class LiquidGlass extends StatelessWidget {
  const LiquidGlass({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.borderRadius = 20,
    this.sigmaX = 15,
    this.sigmaY = 15,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final double sigmaX;
  final double sigmaY;

  static List<double> _saturationMatrix(double saturation) {
    final s = saturation;
    const invR = 0.213;
    const invG = 0.715;
    const invB = 0.072;
    final ir = (1 - s) * invR;
    final ig = (1 - s) * invG;
    final ib = (1 - s) * invB;

    return <double>[
      ir + s, ig, ib, 0, 0,
      ir, ig + s, ib, 0, 0,
      ir, ig, ib + s, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tint = isDark
        ? Colors.black.withValues(alpha: 0.20)
        : Colors.white.withValues(alpha: 0.05);

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: ColorFiltered(
        colorFilter: ColorFilter.matrix(_saturationMatrix(1.5)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: sigmaX, sigmaY: sigmaY),
          child: Container(
            decoration: BoxDecoration(
              color: tint,
              borderRadius: BorderRadius.circular(borderRadius),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.12),
                width: 1,
              ),
            ),
            child: Padding(
              padding: padding,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
