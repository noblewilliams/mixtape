/// The fallback glass material
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md` → Platform differences).
///
/// iOS 26 surfaces get genuine Liquid Glass from the native host (task 2.1);
/// every blurred surface drawn inside Flutter uses [FrostedSurface] instead.
library;

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';

/// Carries the platform's reduced-transparency setting down the tree.
///
/// Task 2.1 feeds the real iOS value in over a channel; absent, surfaces blur.
class FrostedSurfaceMode extends InheritedWidget {
  const FrostedSurfaceMode({
    super.key,
    required this.reduceTransparency,
    required super.child,
  });

  final bool reduceTransparency;

  static const FrostedSurfaceMode _fallback = FrostedSurfaceMode(
    reduceTransparency: false,
    child: SizedBox.shrink(),
  );

  /// The ambient mode, defaulting to blurred glass when no mode is in scope.
  static FrostedSurfaceMode of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FrostedSurfaceMode>() ??
      _fallback;

  @override
  bool updateShouldNotify(FrostedSurfaceMode oldWidget) =>
      oldWidget.reduceTransparency != reduceTransparency;
}

/// Blur, tint, an inner top highlight, a hairline edge and a soft shadow.
///
/// With [opaque], or under [FrostedSurfaceMode.reduceTransparency], the blur is
/// skipped and the surface paints a solid `tokens.scrimBase` with the same
/// radius, hairline and shadow.
class FrostedSurface extends StatelessWidget {
  const FrostedSurface({
    super.key,
    required this.child,
    this.borderRadius,
    this.blurSigma = 20,
    this.tint,
    this.hairline = true,
    this.shadow = true,
    this.opaque = false,
  });

  final Widget child;

  /// Defaults to [MixtapeMetrics.groupRadius].
  final BorderRadius? borderRadius;
  final double blurSigma;

  /// Defaults to `tokens.glass`. Ignored when the surface is opaque.
  final Color? tint;
  final bool hairline;
  final bool shadow;

  /// Force the opaque material, whatever the ambient mode.
  final bool opaque;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final radius =
        borderRadius ?? BorderRadius.circular(MixtapeMetrics.groupRadius);
    final solid = opaque || FrostedSurfaceMode.of(context).reduceTransparency;

    final fill = BoxDecoration(
      color: solid ? tokens.scrimBase : (tint ?? tokens.glass),
      borderRadius: radius,
      border: hairline ? Border.all(color: tokens.hairline, width: 0.5) : null,
    );

    Widget surface = DecoratedBox(
      decoration: fill,
      child: solid
          ? child
          : Stack(
              children: [
                child,
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    child: SizedBox(
                      height: 1,
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: tokens.glassHighlight),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );

    if (!solid) {
      surface = BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: surface,
      );
    }

    // The shadow sits outside the clip, or the clip would cut it away.
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: shadow
            ? [
                BoxShadow(
                  color: tokens.glassShadow,
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ]
            : null,
      ),
      // The blur is expensive; keep it off its neighbours' repaint list.
      child: RepaintBoundary(
        child: ClipRRect(borderRadius: radius, child: surface),
      ),
    );
  }
}
