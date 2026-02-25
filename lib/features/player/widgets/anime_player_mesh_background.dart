import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

class AnimePlayerMeshBackground extends StatefulWidget {
  const AnimePlayerMeshBackground({
    super.key,
    this.imageProvider,
    this.backgroundImageUrl,
    this.speed = const Duration(seconds: 22),
  });

  final ImageProvider? imageProvider;
  final String? backgroundImageUrl;
  final Duration speed;

  @override
  State<AnimePlayerMeshBackground> createState() =>
      _AnimePlayerMeshBackgroundState();
}

class _AnimePlayerMeshBackgroundState extends State<AnimePlayerMeshBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  List<Color> _palette = const <Color>[
    Color(0xFF2A344A),
    Color(0xFF293A59),
    Color(0xFF4A2C5A),
    Color(0xFF1B243B),
  ];

  ImageProvider? _resolvedImageProvider;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.speed)
      ..repeat();
    _resolvedImageProvider = _buildImageProvider();
    _extractPalette();
  }

  @override
  void didUpdateWidget(covariant AnimePlayerMeshBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextProvider = _buildImageProvider();
    if (nextProvider != _resolvedImageProvider) {
      _resolvedImageProvider = nextProvider;
      _extractPalette();
    }
    if (oldWidget.speed != widget.speed) {
      _controller
        ..duration = widget.speed
        ..repeat();
    }
  }

  ImageProvider? _buildImageProvider() {
    if (widget.imageProvider != null) return widget.imageProvider;
    final raw = widget.backgroundImageUrl;
    if (raw == null || raw.trim().isEmpty) return null;
    return NetworkImage(raw.trim());
  }

  Future<void> _extractPalette() async {
    final provider = _resolvedImageProvider;
    if (provider == null) return;
    try {
      final palette = await PaletteGenerator.fromImageProvider(
        provider,
        maximumColorCount: 12,
      );

      final colors = <Color>[
        if (palette.dominantColor?.color != null) palette.dominantColor!.color,
        if (palette.vibrantColor?.color != null) palette.vibrantColor!.color,
        if (palette.darkVibrantColor?.color != null)
          palette.darkVibrantColor!.color,
        if (palette.lightVibrantColor?.color != null)
          palette.lightVibrantColor!.color,
        if (palette.mutedColor?.color != null) palette.mutedColor!.color,
        if (palette.darkMutedColor?.color != null)
          palette.darkMutedColor!.color,
      ];

      if (!mounted || colors.isEmpty) return;

      setState(() {
        _palette = List<Color>.generate(
          4,
          (i) {
            final base = colors[i % colors.length];
            return Color.lerp(base, Colors.black, 0.20)!
                .withValues(alpha: 0.95);
          },
        );
      });
    } catch (_) {
      // Keep fallback colors if palette extraction fails.
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            painter: _MeshGradientPainter(
              t: _controller.value,
              colors: _palette,
            ),
            child: const SizedBox.expand(),
          );
        },
      ),
    );
  }
}

class _MeshGradientPainter extends CustomPainter {
  const _MeshGradientPainter({
    required this.t,
    required this.colors,
  });

  final double t;
  final List<Color> colors;

  Offset _flow({
    required Size size,
    required double px,
    required double py,
    required double phase,
    required double amp,
  }) {
    final x = px + math.sin((t * 2 * math.pi) + phase) * amp;
    final y = py + math.cos((t * 2 * math.pi * 0.9) + phase) * amp;
    return Offset(size.width * x, size.height * y);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = const Color(0xFF0B0F1B));

    final points = <Offset>[
      _flow(size: size, px: 0.18, py: 0.22, phase: 0.0, amp: 0.08),
      _flow(size: size, px: 0.80, py: 0.20, phase: 1.5, amp: 0.09),
      _flow(size: size, px: 0.25, py: 0.78, phase: 3.0, amp: 0.07),
      _flow(size: size, px: 0.82, py: 0.76, phase: 4.6, amp: 0.08),
    ];

    for (var i = 0; i < 4; i++) {
      final color = colors[i % colors.length];
      final radius =
          size.shortestSide * (0.58 + (0.06 * math.sin(t * 2 * math.pi + i)));
      final shader = RadialGradient(
        colors: [
          color.withValues(alpha: 0.42),
          color.withValues(alpha: 0.10),
          Colors.transparent,
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(Rect.fromCircle(center: points[i], radius: radius));

      canvas.drawCircle(
        points[i],
        radius,
        Paint()
          ..shader = shader
          ..blendMode = BlendMode.plus,
      );
    }

    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.18)
        ..blendMode = BlendMode.srcOver,
    );
  }

  @override
  bool shouldRepaint(covariant _MeshGradientPainter oldDelegate) {
    return oldDelegate.t != t || oldDelegate.colors != colors;
  }
}
