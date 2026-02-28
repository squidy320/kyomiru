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

  @override
  Widget build(BuildContext context) {
    final darkMode = Theme.of(context).brightness == Brightness.dark;
    final fillColor = darkMode
        ? Colors.black.withValues(alpha: 0.20)
        : Colors.white.withValues(alpha: 0.10);

    return Container(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        color: fillColor,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.10),
          width: borderWidth,
        ),
      ),
      child: child == null ? null : Padding(padding: padding, child: child),
    );
  }
}
