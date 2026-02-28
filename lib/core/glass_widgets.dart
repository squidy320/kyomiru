import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/app_settings_state.dart';
import 'haptics.dart';

class GlassContainer extends ConsumerStatefulWidget {
  const GlassContainer({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.margin,
    this.borderRadius = 20,
    this.blur,
    this.duration = const Duration(milliseconds: 240),
    this.animateIn = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double borderRadius;
  final double? blur;
  final Duration duration;
  final bool animateIn;

  @override
  ConsumerState<GlassContainer> createState() => _GlassContainerState();
}

class _GlassContainerState extends ConsumerState<GlassContainer> {
  double _visible = 0;

  @override
  void initState() {
    super.initState();
    if (!widget.animateIn) {
      _visible = 1;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _visible = 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(appSettingsProvider);
    final brightness = Theme.of(context).brightness;
    final solid = DecoratedBox(
      decoration: BoxDecoration(
        color: settings.oled
            ? const Color(0xFF000000)
            : (brightness == Brightness.dark
                ? const Color(0xFA1E1E1E)
                : const Color(0xFA222222)),
        borderRadius: BorderRadius.circular(widget.borderRadius),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.10),
          width: 1,
        ),
      ),
      child: Padding(
        padding: widget.padding,
        child: widget.child,
      ),
    );

    return Container(
      margin: widget.margin,
      child: AnimatedOpacity(
        duration: widget.duration,
        curve: Curves.easeOutCubic,
        opacity: _visible,
        child: AnimatedScale(
        duration: widget.duration,
        curve: Curves.easeOutCubic,
        scale: 0.985 + (_visible * 0.015),
          child: solid,
        ),
      ),
    );
  }
}

class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.borderRadius = 16,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return GlassContainer(
      borderRadius: borderRadius,
      padding: padding,
      child: child,
    );
  }
}

class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    this.borderRadius = 14,
  });

  final Widget child;
  final VoidCallback? onPressed;
  final EdgeInsetsGeometry padding;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        if (onPressed == null) return;
        hapticTap();
        onPressed!();
      },
      borderRadius: BorderRadius.circular(borderRadius),
      child: GlassContainer(
        borderRadius: borderRadius,
        padding: padding,
        child: Center(child: child),
      ),
    );
  }
}

class GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  const GlassAppBar({
    super.key,
    required this.title,
    this.leading,
    this.actions,
  });

  final Widget title;
  final Widget? leading;
  final List<Widget>? actions;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight + 10);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: GlassContainer(
          borderRadius: 18,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              leading ?? const SizedBox(width: 40),
              Expanded(
                child: DefaultTextStyle.merge(
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                  child: title,
                ),
              ),
              if (actions == null)
                const SizedBox(width: 40)
              else
                Row(mainAxisSize: MainAxisSize.min, children: actions!),
            ],
          ),
        ),
      ),
    );
  }
}

class GlassScaffoldBackground extends ConsumerWidget {
  const GlassScaffoldBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsProvider);
    final background =
        settings.oled ? const Color(0xFF000000) : const Color(0xFF040714);

    return Stack(
      children: [
        Container(color: background),
        child,
      ],
    );
  }
}

