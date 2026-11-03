/// Genuine iOS 26 Liquid Glass for surfaces that live inside Flutter
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md` → Platform
/// differences).
///
/// The dock gets its glass from UIKit directly; the collapsing title bar and
/// the Home panel are Flutter widgets, so they host a native
/// `UIVisualEffectView(effect: UIGlassEffect())` as a platform view instead,
/// and fall back to [FrostedSurface] everywhere the dock is unavailable.
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart' show StandardMessageCodec;

import '../../../data/shell/shell_channel.dart';
import 'frosted_surface.dart';

class LiquidGlassSurface extends StatefulWidget {
  const LiquidGlassSurface({
    super.key,
    required this.child,
    this.fallbackBlurSigma = 20,
    this.fallbackTint,
    this.borderRadius,
    this.circle = false,
    this.fallbackShadows,
    this.allowNative = true,
    this.channel,
  });

  final Widget child;

  /// Blur strength for the [FrostedSurface] fallback.
  final double fallbackBlurSigma;

  /// Tint painted over the fallback blur. The native glass supplies its own
  /// material and ignores it.
  final Color? fallbackTint;

  /// The surface's corners. The fallback clips to the full [BorderRadius];
  /// the native view takes one radius (its top-left) as `cornerRadius`.
  final BorderRadius? borderRadius;

  /// What the native view is asked to round its corners by.
  double get nativeCornerRadius => borderRadius?.topLeft.x ?? 0;

  /// A true circle (the header buttons): the native view rounds with the
  /// circular corner curve rather than the continuous one, which would read
  /// as a squircle at half the side. Pair it with a [borderRadius] of half the
  /// diameter.
  final bool circle;

  /// Replaces the [FrostedSurface] fallback's default shadow.
  final List<BoxShadow>? fallbackShadows;

  /// Set false while a Flutter sheet or dialog is open: a `UiKitView`
  /// composites above route barriers and would punch through the dim.
  final bool allowNative;

  /// The bridge that answers whether the native dock — and so the glass — is
  /// there. Defaults to the app-wide [ShellChannel]; tests inject their own.
  final ShellChannel? channel;

  /// Must match `LiquidGlassViewFactory`'s registration in `AppDelegate`.
  static const String viewType = 'mixtape/liquid_glass';

  /// The availability answer is cached for the life of the process, which a
  /// second test would otherwise inherit.
  @visibleForTesting
  static void resetAvailabilityForTests() {
    _LiquidGlassSurfaceState._nativeAvailable = null;
  }

  @override
  State<LiquidGlassSurface> createState() => _LiquidGlassSurfaceState();
}

class _LiquidGlassSurfaceState extends State<LiquidGlassSurface> {
  /// Resolved once through the shell channel, then shared by every instance.
  static bool? _nativeAvailable;

  @override
  void initState() {
    super.initState();
    if (_nativeAvailable != null) return;
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      _nativeAvailable = false;
      return;
    }
    (widget.channel ?? ShellChannel.instance).isAvailable.then((available) {
      _nativeAvailable = available;
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    // Reduced transparency asks for an opaque fill, which only the fallback
    // draws.
    final reduce = FrostedSurfaceMode.of(context).reduceTransparency;
    if (widget.allowNative && !reduce && _nativeAvailable == true) {
      // The effect view resolves its material against the iOS *system*
      // appearance, so the app's own brightness is handed over at creation.
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final radius = widget.nativeCornerRadius;
      return Stack(
        fit: StackFit.passthrough,
        children: [
          Positioned.fill(
            child: UiKitView(
              // Creation params are read once, so a theme flip has to build a
              // fresh view — hence the brightness-derived key.
              key: ValueKey<String>('$isDark-$radius-${widget.circle}'),
              viewType: LiquidGlassSurface.viewType,
              hitTestBehavior: PlatformViewHitTestBehavior.transparent,
              creationParams: <String, Object?>{
                'isDark': isDark,
                'cornerRadius': radius,
                'circle': widget.circle,
              },
              creationParamsCodec: const StandardMessageCodec(),
            ),
          ),
          widget.child,
        ],
      );
    }

    return FrostedSurface(
      borderRadius: widget.borderRadius,
      blurSigma: widget.fallbackBlurSigma,
      tint: widget.fallbackTint,
      shadows: widget.fallbackShadows,
      child: widget.child,
    );
  }
}
