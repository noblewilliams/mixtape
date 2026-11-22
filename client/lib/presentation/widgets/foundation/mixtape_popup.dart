/// The app's one centred modal (`docs/mockups/approved/2026-11-21-push-permission-modal.md`
/// → Locked behaviour; board `docs/mockups/2026-11-21-push-permission-modal-r3.html`,
/// `.scrim` and `.sheet`).
///
/// Sheets come up from the bottom ([showMixtapeSheet]); a pop-up sits in the
/// middle of a blurred screen: 22 pt in from each side, 30 pt corners on the
/// sheet surface, the screen behind blurred by 16 pt under a light tint. A
/// tap on the overlay closes it, with no answer. No grab handle.
///
/// It comes in with a 200 ms fade and a scale from 0.96 (a fade alone under
/// reduced motion), and scrolls inside itself when its content is taller
/// than the screen.
library;

import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'haptics.dart';
import 'mixtape_sheet.dart';

/// The pop-up's metrics, colours and keys.
abstract final class MixtapePopup {
  /// In from each side of the screen (`.sheet` left/right).
  static const double sideInset = 22;

  /// Clear of the safe area above and below, when the content fills the
  /// screen (the board's 200 % frame).
  static const double edgeInset = 16;

  static const double radius = 30;

  /// The overlay's blur: CSS `blur(16px)` is a 16 pt standard deviation.
  static const double blurSigma = 16;

  /// `saturate(120%)` with the blur.
  static const double saturation = 1.2;

  /// `--scrim`: about 16 % light, 32 % dark.
  static const Color lightTint = Color.fromRGBO(28, 22, 34, 0.16);
  static const Color darkTint = Color.fromRGBO(0, 0, 0, 0.32);

  static const Duration transition = Duration(milliseconds: 200);
  static const double startScale = 0.96;

  /// The card itself, for tests.
  static const Key surfaceKey = Key('mixtape-popup-surface');

  /// The blurred overlay, which closes it on a tap.
  static const Key barrierKey = Key('mixtape-popup-barrier');

  static Color tintOf(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? darkTint : lightTint;

  /// `0 24px 60px` (a CSS blur of 60 is a 30 pt standard deviation) and the
  /// half-point inner edge.
  static List<BoxShadow> shadowOf(Brightness brightness) => [
    BoxShadow(
      color: brightness == Brightness.dark
          ? const Color.fromRGBO(0, 0, 0, 0.6)
          : const Color.fromRGBO(30, 20, 40, 0.28),
      offset: const Offset(0, 24),
      blurRadius: _cssBlur(60),
    ),
  ];

  static Color edgeOf(Brightness brightness) => brightness == Brightness.dark
      ? const Color.fromRGBO(255, 255, 255, 0.1)
      : const Color.fromRGBO(255, 255, 255, 0.6);

  /// A CSS shadow blur (twice the standard deviation) as Flutter's
  /// [BoxShadow.blurRadius] (sigma = r × 0.57735 + 0.5).
  static double _cssBlur(double css) => (css / 2 - 0.5) / 0.57735;

  /// The overlay's filter: the blur, then the saturation.
  static ui.ImageFilter filter(double t) {
    final s = 1 + (saturation - 1) * t;
    final r = 0.2126 * (1 - s), g = 0.7152 * (1 - s), b = 0.0722 * (1 - s);
    return ui.ImageFilter.compose(
      outer: ColorFilter.matrix(<double>[
        r + s, g, b, 0, 0, //
        r, g + s, b, 0, 0, //
        r, g, b + s, 0, 0, //
        0, 0, 0, 1, 0,
      ]),
      inner: ui.ImageFilter.blur(
        sigmaX: blurSigma * t,
        sigmaY: blurSigma * t,
        tileMode: TileMode.clamp,
      ),
    );
  }
}

/// Presents [builder] as the app's centred pop-up on [context]'s navigator.
/// Null when the overlay is tapped. [label] names the route for VoiceOver.
Future<T?> showMixtapePopup<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  required String label,
}) {
  unawaited(Haptics.play(HapticKind.open));
  return Navigator.of(context).push(
    _MixtapePopupRoute<T>(
      builder: builder,
      label: label,
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: Navigator.of(context).context,
      ),
    ),
  );
}

class _MixtapePopupRoute<T> extends PopupRoute<T> {
  _MixtapePopupRoute({
    required this.builder,
    required this.label,
    required this.capturedThemes,
  });

  final WidgetBuilder builder;
  final String label;
  final CapturedThemes capturedThemes;

  // The overlay is drawn in the page (its blur and its tap); the route's own
  // barrier only keeps touches from the screen behind.
  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => null;

  @override
  Duration get transitionDuration => MixtapePopup.transition;

  @override
  Duration get reverseTransitionDuration => MixtapePopup.transition;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => capturedThemes.wrap(
    _MixtapePopupFrame(
      animation: animation,
      label: label,
      onDismiss: () {
        unawaited(Haptics.play(HapticKind.dismiss));
        if (isCurrent) navigator?.pop();
      },
      child: Builder(builder: builder),
    ),
  );
}

class _MixtapePopupFrame extends StatelessWidget {
  const _MixtapePopupFrame({
    required this.animation,
    required this.label,
    required this.onDismiss,
    required this.child,
  });

  final Animation<double> animation;
  final String label;
  final VoidCallback onDismiss;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final reduced = media.disableAnimations;
    final brightness = Theme.of(context).brightness;
    final tint = MixtapePopup.tintOf(context);
    final eased = CurvedAnimation(parent: animation, curve: Curves.easeOut);
    final maxHeight =
        (media.size.height -
                media.padding.vertical -
                media.viewInsets.bottom -
                MixtapePopup.edgeInset * 2)
            .clamp(0.0, double.infinity);

    return Stack(
      fit: StackFit.expand,
      children: [
        // Decorative to VoiceOver: "Not now" is the spoken way out.
        ExcludeSemantics(
          child: GestureDetector(
            key: MixtapePopup.barrierKey,
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
            child: AnimatedBuilder(
              animation: eased,
              builder: (context, _) => BackdropFilter(
                filter: MixtapePopup.filter(eased.value),
                child: ColoredBox(
                  color: tint.withValues(alpha: tint.a * eased.value),
                ),
              ),
            ),
          ),
        ),
        // Above the keyboard when a field is up (Save as playlist): centred in
        // the room left, not behind it.
        AnimatedPadding(
          duration: MixtapePopup.transition,
          curve: Curves.easeOut,
          padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
          child: SafeArea(
            bottom: media.viewInsets.bottom == 0,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: MixtapePopup.sideInset,
                vertical: MixtapePopup.edgeInset,
              ),
              child: Center(
                child: FadeTransition(
                  opacity: eased,
                  child: ScaleTransition(
                    scale: reduced
                        ? const AlwaysStoppedAnimation<double>(1)
                        : Tween<double>(
                            begin: MixtapePopup.startScale,
                            end: 1,
                          ).animate(eased),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minWidth: double.infinity,
                        maxHeight: maxHeight,
                      ),
                      child: Semantics(
                        scopesRoute: true,
                        namesRoute: true,
                        explicitChildNodes: true,
                        label: label,
                        child: DecoratedBox(
                          key: MixtapePopup.surfaceKey,
                          decoration: BoxDecoration(
                            color: MixtapeSheet.surfaceColorOf(context),
                            borderRadius: BorderRadius.circular(
                              MixtapePopup.radius,
                            ),
                            boxShadow: MixtapePopup.shadowOf(brightness),
                          ),
                          position: DecorationPosition.background,
                          child: DecoratedBox(
                            position: DecorationPosition.foreground,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(
                                MixtapePopup.radius,
                              ),
                              border: Border.all(
                                color: MixtapePopup.edgeOf(brightness),
                                width: 0.5,
                              ),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(
                                MixtapePopup.radius,
                              ),
                              child: Material(
                                type: MaterialType.transparency,
                                child: DefaultTextStyle.merge(
                                  style: TextStyle(
                                    color: MixtapeSheet.tokensOf(context).text,
                                  ),
                                  child: child,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
