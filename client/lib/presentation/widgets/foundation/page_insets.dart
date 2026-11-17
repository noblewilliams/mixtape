/// Fits a page to a screen whose system bar may not run across the top.
///
/// The system can stand its bar on one side edge for as long as a pose
/// lasts: the iPhone Duo's closed outer screen (in portrait, and on the left
/// in landscape) and its unfolded inner screen (in landscape) carry the
/// status column on a side, as a left or right inset of 84 pt. An iPhone in
/// landscape has one on each side for the sensor housing. The two sides are
/// read separately and are usually unequal.
///
/// Two things follow, and this does both:
///
/// * **Sides.** The page is padded by the left and right insets, which it
///   then removes from [MediaQuery], so a nested page (a tab's own
///   navigator) and the page's widgets do not count the bar twice. The
///   gradient behind the app keeps running under the bar, and
///   [GradientBleed] carries the inset down to a screen that paints its own
///   gradient, so no seam shows at the bar.
/// * **Top.** With no bar across it, the top inset is 0, and every header
///   that sits on it would touch the top edge (the status bar is what
///   normally holds a header down). The top inset is raised to
///   [MixtapeMetrics.minTopInset] there. Only the reported inset changes: the
///   page still starts at the top edge, so its background does too.
///
/// Every page route is wrapped in this by [InsetPageTransitionsBuilder], so
/// pages stop at the bar while dialog and sheet barriers, which are not
/// pages, still dim the whole screen. A sheet's content takes the sides only
/// ([top] false): its own top is the sheet's edge, not the screen's.
library;

import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';
import 'gradient_background.dart';

class PageInsets extends StatelessWidget {
  const PageInsets({super.key, this.top = true, required this.child});

  /// Whether a top with no status bar is given [MixtapeMetrics.minTopInset].
  final bool top;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final left = media.padding.left;
    final right = media.padding.right;
    final raiseTop = top && media.padding.top < MixtapeMetrics.minTopInset;
    if (left == 0 && right == 0 && !raiseTop) return child;

    EdgeInsets fit(EdgeInsets insets) => insets.copyWith(
      left: 0,
      right: 0,
      top: raiseTop ? MixtapeMetrics.minTopInset : insets.top,
    );

    return Padding(
      padding: EdgeInsets.only(left: left, right: right),
      child: MediaQuery(
        data: media.copyWith(
          padding: fit(media.padding),
          viewPadding: fit(media.viewPadding),
        ),
        child: GradientBleed(
          left: GradientBleed.leftOf(context) + left,
          right: GradientBleed.rightOf(context) + right,
          child: child,
        ),
      ),
    );
  }
}

/// Wraps [inner]'s page transitions so each page sits inside [PageInsets].
/// Duration and the delegated (previous-page) transition are [inner]'s.
class InsetPageTransitionsBuilder extends PageTransitionsBuilder {
  const InsetPageTransitionsBuilder(this.inner);

  final PageTransitionsBuilder inner;

  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      inner.delegatedTransition;

  @override
  Duration get transitionDuration => inner.transitionDuration;

  @override
  Duration get reverseTransitionDuration => inner.reverseTransitionDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => inner.buildTransitions(
    route,
    context,
    animation,
    secondaryAnimation,
    PageInsets(child: child),
  );
}

/// Flutter's own page transitions on every platform, each fitted by
/// [PageInsets].
PageTransitionsTheme insetPageTransitionsTheme() => PageTransitionsTheme(
  builders: {
    for (final entry in const PageTransitionsTheme().builders.entries)
      entry.key: InsetPageTransitionsBuilder(entry.value),
  },
);
