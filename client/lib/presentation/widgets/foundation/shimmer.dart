import 'package:flutter/material.dart';

/// A band of light that sweeps across [child], left to right, so a line of
/// text reads as something still loading (founder, 2026-11-16: the DJ's
/// working lines lost their trailing ellipses for this).
///
/// [child] is painted in [base], with the band in [highlight]; only the
/// child's own shape takes the colour (a [ShaderMask] in `srcIn`). Under
/// reduced motion it stands still and the child is drawn as it is.
class Shimmer extends StatefulWidget {
  const Shimmer({
    super.key,
    required this.base,
    required this.highlight,
    required this.child,
  });

  final Color base;
  final Color highlight;
  final Widget child;

  /// One sweep, edge to edge.
  static const Duration period = Duration(milliseconds: 1800);

  /// The band's highlight for text in [base]: lighter on light ink (dark
  /// backgrounds), darker on dark ink, so it always gains contrast.
  static Color highlightFor(Color base) => Color.lerp(
    base.withValues(alpha: 1),
    base.computeLuminance() > 0.25 ? Colors.white : Colors.black,
    0.6,
  )!;

  @override
  ShimmerState createState() => ShimmerState();
}

/// Public so tests can assert it never runs under reduced motion.
class ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _sweep = AnimationController(
    vsync: this,
    duration: Shimmer.period,
  );
  bool _reducedMotion = false;

  /// Whether the sweep is running.
  @visibleForTesting
  bool get isShimmering => _sweep.isAnimating;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    if (_reducedMotion) {
      _sweep.stop();
    } else if (!_sweep.isAnimating) {
      _sweep.repeat();
    }
  }

  @override
  void dispose() {
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_reducedMotion) return widget.child;
    return AnimatedBuilder(
      animation: _sweep,
      child: widget.child,
      builder: (_, child) => ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (bounds) => LinearGradient(
          colors: [
            widget.base,
            widget.base,
            widget.highlight,
            widget.base,
            widget.base,
          ],
          stops: const [0, 0.38, 0.5, 0.62, 1],
          // From fully off the left edge to fully off the right.
          transform: _Slide(_sweep.value * 2 - 1),
        ).createShader(bounds),
        child: child,
      ),
    );
  }
}

/// Moves the gradient sideways by [fraction] of the bounds' width.
class _Slide extends GradientTransform {
  const _Slide(this.fraction);

  final double fraction;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * fraction, 0, 0);
}
