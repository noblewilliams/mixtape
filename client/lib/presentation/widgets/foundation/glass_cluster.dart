/// The header buttons (`docs/mockups/approved/2026-11-03-mix-conversation-
/// redesign.md` → Header buttons; `.gbtn` on
/// `docs/mockups/2026-11-03-mix-conversation-redesign.html`, section 6).
///
/// Every top-of-screen button is its own small circle of glass: 34 pt visible,
/// a 17 pt glyph and a 44 pt target. Native Liquid Glass on iOS 26 and later,
/// frosted elsewhere, opaque with reduced transparency. This replaces the
/// 46 pt capsule that grouped neighbouring buttons (the shell board's
/// `.glassbtns`).
library;

import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';
import 'liquid_glass_surface.dart';

/// Neighbouring [GlassButton]s side by side, 4 pt apart. No capsule: each
/// button paints its own glass.
class GlassCluster extends StatelessWidget {
  const GlassCluster({super.key, required this.children});

  final List<Widget> children;

  /// The gap between neighbouring 44 pt targets, per the board.
  static const double gap = 4;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: gap),
          children[i],
        ],
      ],
    );
  }
}

/// The glass a header control sits on: [LiquidGlassSurface] with the board's
/// tighter shadow, and native glass only while its route is on top — a
/// platform view composites above Flutter's route barriers, so a sheet or
/// dialog over the screen would otherwise show the circle through its dim.
class _HeaderGlass extends StatelessWidget {
  const _HeaderGlass({
    required this.radius,
    required this.child,
    this.circle = false,
  });

  final double radius;
  final bool circle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return LiquidGlassSurface(
      borderRadius: BorderRadius.circular(radius),
      circle: circle,
      fallbackBlurSigma: 10,
      fallbackShadows: [
        BoxShadow(
          color: tokens.glassShadow.withValues(
            alpha: tokens.glassShadow.a * 0.75,
          ),
          blurRadius: 10,
          offset: const Offset(0, 3),
        ),
      ],
      allowNative: ModalRoute.of(context)?.isCurrent ?? true,
      child: child,
    );
  }
}

/// A single round glyph button: its own 34 pt glass circle inside a 44 pt
/// target.
class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    this.icon,
    this.child,
    required this.label,
    this.onPressed,
  }) : assert(
         (icon == null) != (child == null),
         'a GlassButton carries either an icon or a child, never both',
       );

  /// The glyph, for the buttons that wear one of Material's.
  final IconData? icon;

  /// A drawn mark instead of [icon] — the Library tab's Sync button carries
  /// the Apple Music note (smoke round four, note 3). Sized and inked by the
  /// caller; everything else about the button is unchanged.
  final Widget? child;

  /// The accessibility label; the button itself is a glyph.
  final String label;
  final VoidCallback? onPressed;

  /// The painted circle. The tap target is [MixtapeMetrics.minTarget].
  static const double diameter = 34;
  static const double iconSize = 17;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final enabled = onPressed != null;

    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox.square(
          dimension: MixtapeMetrics.minTarget,
          child: Center(
            child: SizedBox.square(
              dimension: diameter,
              child: _HeaderGlass(
                radius: diameter / 2,
                circle: true,
                child: Opacity(
                  opacity: enabled ? 1 : 0.4,
                  child: Center(
                    child:
                        child ?? Icon(icon, size: iconSize, color: tokens.text),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A glass button that says what it does: a glyph and a word (approval
/// `docs/mockups/approved/2026-11-03-library-sources.md`: the Library title's
/// "Sync" and "Your music").
///
/// With the shared capsule gone it wears its own: 34 pt of glass, as tall as
/// a [GlassButton]'s circle, inside a 44 pt target. The word stops growing at
/// [maxTextScale] so a pair always fits one line.
class GlassLabelButton extends StatelessWidget {
  const GlassLabelButton({
    super.key,
    required this.icon,
    required this.label,
    this.semanticLabel,
    this.onPressed,
  });

  final IconData icon;

  /// The word on the button.
  final String label;

  /// What a screen reader says, when it is more than the word ("Sync Apple
  /// Music" for "Sync").
  final String? semanticLabel;
  final VoidCallback? onPressed;

  static const double iconSize = 18;
  static const double maxTextScale = 1.3;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final enabled = onPressed != null;

    return Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel ?? label,
      onTap: onPressed,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: MixtapeMetrics.minTarget,
            minWidth: MixtapeMetrics.minTarget,
          ),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: GlassButton.diameter,
              ),
              child: _HeaderGlass(
                radius: GlassButton.diameter / 2,
                child: Opacity(
                  opacity: enabled ? 1 : 0.4,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 10, right: 12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: iconSize, color: tokens.text),
                        const SizedBox(width: 6),
                        Text(
                          label,
                          maxLines: 1,
                          textScaler: MediaQuery.textScalerOf(
                            context,
                          ).clamp(maxScaleFactor: maxTextScale),
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: tokens.text,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
