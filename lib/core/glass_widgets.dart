import 'package:flutter/material.dart';

class GlassCard extends StatelessWidget {
  const GlassCard(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.all(14)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xAA101726),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x33FFFFFF)),
      ),
      padding: padding,
      child: child,
    );
  }
}
