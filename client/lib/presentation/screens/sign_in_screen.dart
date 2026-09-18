/// Sign-in (`docs/mockups/approved/2026-09-08-mobile-parity.md` → Apple and
/// Google as equal logins; shell board `docs/mockups/approved/
/// 2026-09-17-mobile-shell.md` for the type, gradient and tape controls).
///
/// Since 2026-09-18 this mirrors the web welcome page (`web/src/components/
/// AuthGate.tsx`): the handwritten wordmark, a cassette with its hubs turning
/// for as long as the screen is open, the web's promise, and two full-width
/// pill buttons — the remembered method marked with a pencil note, one
/// reserved line for waiting or failure, and the Apple Music note at the foot.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/auth/account_api.dart';
import '../../data/auth/apple_auth_gateway.dart';
import '../../data/auth/auth_repository.dart';
import '../../data/auth/google_auth_gateway.dart';
import '../providers/auth_provider.dart';
import '../theme/mixtape_theme.dart';
import '../widgets/foundation/cassette_tile.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  /// The reserved status line: waiting, or the safe failure sentence.
  static const Key errorKey = Key('sign-in-error');

  /// The muted reason under the Google button in a build without the
  /// `--dart-define-from-file=config/google-ios.json` configuration.
  static const Key googleUnavailableKey = Key('google-unavailable');

  static const String googleUnavailable =
      'Google sign-in is not available in this build.';

  /// The tape's width where the screen has room for all of it.
  static const double cassetteWidth = 272;

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  AccountProvider? _busy;
  String? _error;

  Future<void> _signIn(AccountProvider provider) async {
    if (_busy != null) return;
    setState(() {
      _busy = provider;
      _error = null;
    });
    try {
      await ref.read(authProvider.notifier).signIn(provider: provider);
    } on AppleSignInCancelled {
      // Dismissing native authentication is not a failure.
    } on GoogleSignInCancelled {
      // The listener remains on this screen and can choose either method.
    } on AuthOperationCancelled {
      // An auth transition or disposal superseded this operation.
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = switch (error) {
          AuthSignInException(code: 'ACCOUNT_NOT_LINKED') =>
            'That account is not linked yet. Sign in with your usual method, then link it from Account.',
          GoogleSignInUnavailable() => SignInScreen.googleUnavailable,
          _ => 'Sign-in failed. Try again.',
        },
      );
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final googleAvailable = ref.watch(googleAuthGatewayProvider).isAvailable;
    final lastUsed = ref.watch(lastSignInProvider).value;

    // The gradient is painted app-wide by MaterialApp's builder.
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        // Centre caps the width against the bounded screen height, so the
        // scroll view below still knows how tall a screenful is.
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width =
                    constraints.maxWidth - MixtapeMetrics.screenSidePadding * 2;
                return SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: MixtapeMetrics.screenSidePadding,
                    vertical: _scrollPadding,
                  ),
                  // A screenful tall, so the Apple Music note sits at the
                  // foot; taller content (200% text) scrolls instead.
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: math.max(
                        0,
                        constraints.maxHeight - _scrollPadding * 2,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _wordmark(tokens),
                        _cassette(
                          _tapeWidth(
                            body: context,
                            tokens: tokens,
                            constraints: constraints,
                            width: width,
                            googleAvailable: googleAvailable,
                            lastUsed: lastUsed,
                          ),
                        ),
                        _promise(tokens, dark, googleAvailable, lastUsed),
                        Text(
                          _footNote,
                          textAlign: TextAlign.center,
                          style: tokens.meta.copyWith(color: tokens.muted),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// The tape's width for this screen: what the fixed rows leave, in the
  /// cassette's 200 : 128 ratio, between [_minCassetteWidth] and
  /// [_cassetteWidth] — or 0 when even the floor would not fit.
  ///
  /// Nothing in the column can be [Expanded] — a scroll view gives it
  /// unbounded height — so the fixed rows are measured with a [TextPainter] at
  /// the same width, styles and text scale the build uses, and the tape takes
  /// the remainder. On a short phone it shrinks rather than pushing the
  /// buttons past the fold; below [_minCassetteWidth] it is dropped outright,
  /// because a stub tape reads as clutter and a listener who cannot see a
  /// sign-in button is worse off than one who cannot see the motif. Very tall
  /// content (200% text) therefore drops the tape and scrolls, which is what
  /// the reserved status line and foot note expect.
  double _tapeWidth({
    required BuildContext body,
    required MixtapeTokens tokens,
    required BoxConstraints constraints,
    required double width,
    required bool googleAvailable,
    required AccountProvider? lastUsed,
  }) {
    final budget =
        constraints.maxHeight -
        _scrollPadding * 2 -
        _cassetteGap * 2 -
        _fixedHeight(
          body: body,
          tokens: tokens,
          width: width,
          googleAvailable: googleAvailable,
          lastUsed: lastUsed,
        );
    final fits = budget * 200 / 128;
    if (fits < _minCassetteWidth) return 0;
    return math.min(
      // The 4° tilt widens the painted box, so cap it to keep the tape's
      // corners inside the scroll view's clip on a narrow screen.
      math.min(_cassetteWidth, math.max(0, width) / 1.05),
      fits,
    );
  }

  /// Every row but the tape, laid out at [width] and the ambient text scale.
  double _fixedHeight({
    required BuildContext body,
    required MixtapeTokens tokens,
    required double width,
    required bool googleAvailable,
    required AccountProvider? lastUsed,
  }) {
    final scaler = MediaQuery.textScalerOf(body);
    // A [Text] merges its style over the ambient default, which carries a
    // line height the tokens without one (meta, the pencil note) inherit;
    // measuring the raw token would come up short by a line or two. [body]
    // is the scroll view's context, inside the Scaffold's Material, where
    // that default is the one the rows actually see.
    final ambient = DefaultTextStyle.of(body).style;
    double text(String value, TextStyle style, double maxWidth) {
      final painter = TextPainter(
        text: TextSpan(text: value, style: ambient.merge(style)),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout(maxWidth: math.max(0, maxWidth));
      final height = painter.height;
      painter.dispose();
      return height;
    }

    var total = text('mixtape', tokens.wordmark, width);
    total += text(_headline, _headlineStyle(tokens), width) + 12;
    total += text(_blurb, _blurbStyle(tokens), width) + 28;

    // The pill's floor, or its label plus the padding it sits in.
    final labelStyle = ProviderSignInButton.labelStyle(tokens);
    final labelWidth = width - 40 - ProviderSignInButton.markSize - 10;
    for (final provider in AccountProvider.values) {
      total += math.max(
        ProviderSignInButton.height,
        math.max(
              ProviderSignInButton.markSize,
              text('Continue with ${_name(provider)}', labelStyle, labelWidth),
            ) +
            ProviderSignInButton.verticalPadding * 2,
      );
      if (lastUsed == provider) {
        total += 8 + text('Last used', _lastUsedStyle(tokens), width);
      }
      if (provider == AccountProvider.google && !googleAvailable) {
        total += 8 + text(SignInScreen.googleUnavailable, tokens.meta, width);
      }
      total += 12;
    }

    // The reserved status line, then the Apple Music note.
    total += scaler.scale(17) * 2;
    return total + text(_footNote, tokens.meta, width);
  }

  /// The product name in the web's marker hand, tilted off the baseline.
  Widget _wordmark(MixtapeTokens tokens) => Center(
    child: Transform.rotate(
      angle: -_wordmarkTilt,
      child: Text('mixtape', style: tokens.wordmark),
    ),
  );

  /// The web's `.auth-cassette`: turning, tilted 4°, on a soft drop shadow.
  ///
  /// [width] comes from [_tapeWidth], which is what the rest of the screen
  /// leaves.
  Widget _cassette(double width) {
    if (width <= 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: _cassetteGap),
      child: Center(
        child: Transform.rotate(
          angle: _cassetteTilt,
          child: DecoratedBox(
            // The case's rx 9 in the 200 × 128 viewBox, scaled to the width.
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(width * 9 / 200),
              boxShadow: const [
                BoxShadow(
                  color: Color.fromRGBO(47, 42, 48, 0.16),
                  offset: Offset(0, 15),
                  blurRadius: 20,
                ),
              ],
            ),
            child: CassetteTile(
              width: width,
              // The web's default case, `#3f4851`.
              caseColor: CassetteTile.caseColors.first,
              // Alive for as long as the screen is open; the tile holds the
              // hubs still under reduced motion.
              spinning: true,
            ),
          ),
        ),
      ),
    );
  }

  Widget _promise(
    MixtapeTokens tokens,
    bool dark,
    bool googleAvailable,
    AccountProvider? lastUsed,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(_headline, style: _headlineStyle(tokens)),
      const SizedBox(height: 12),
      Text(_blurb, style: _blurbStyle(tokens)),
      const SizedBox(height: 28),
      for (final provider in AccountProvider.values) ...[
        _providerButton(provider, dark, googleAvailable),
        if (lastUsed == provider) _lastUsed(tokens),
        if (provider == AccountProvider.google && !googleAvailable)
          Padding(
            key: SignInScreen.googleUnavailableKey,
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              SignInScreen.googleUnavailable,
              textAlign: TextAlign.center,
              style: tokens.meta.copyWith(color: tokens.muted),
            ),
          ),
        const SizedBox(height: 12),
      ],
      _status(tokens),
    ],
  );

  Widget _providerButton(
    AccountProvider provider,
    bool dark,
    bool googleAvailable,
  ) {
    final skin = _skin(provider, dark);
    return ProviderSignInButton(
      key: Key('${provider.name}-sign-in'),
      label: 'Continue with ${_name(provider)}',
      mark: provider == AccountProvider.apple
          ? const AppleMark(size: ProviderSignInButton.markSize)
          : const GoogleMark(size: ProviderSignInButton.markSize),
      background: skin.background,
      foreground: skin.foreground,
      borderColor: skin.border,
      onPressed:
          _busy != null ||
              (provider == AccountProvider.google && !googleAvailable)
          ? null
          : () => _signIn(provider),
    );
  }

  /// The web's `.auth-last-used`: a pencil note on the tape, not a label.
  Widget _lastUsed(MixtapeTokens tokens) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Center(
      child: Transform.rotate(
        angle: -_wordmarkTilt,
        child: Text(
          'Last used',
          textAlign: TextAlign.center,
          style: _lastUsedStyle(tokens),
        ),
      ),
    ),
  );

  /// One reserved line, so a failure or a pending sheet never moves the
  /// buttons under the listener's thumb.
  Widget _status(MixtapeTokens tokens) {
    final busy = _busy;
    final error = _error;
    return ConstrainedBox(
      key: SignInScreen.errorKey,
      constraints: BoxConstraints(
        minHeight: MediaQuery.textScalerOf(context).scale(17) * 2,
      ),
      child: Semantics(
        liveRegion: true,
        child: busy != null
            ? Text(
                'Waiting for ${_name(busy)}…',
                textAlign: TextAlign.center,
                style: tokens.secondary.copyWith(color: tokens.smoke),
              )
            : error == null
            ? const SizedBox.shrink()
            : Text(
                error,
                textAlign: TextAlign.center,
                style: tokens.secondary.copyWith(color: tokens.errInk),
              ),
      ),
    );
  }

  /// The web's provider colours, with Apple inverted and Google on its dark
  /// spec in the dark theme (Sign in with Apple HIG; Google branding).
  static ({Color background, Color foreground, Color border}) _skin(
    AccountProvider provider,
    bool dark,
  ) => switch ((provider, dark)) {
    (AccountProvider.apple, false) => (
      background: const Color(0xFF111114),
      foreground: const Color(0xFFFFFFFF),
      border: const Color.fromRGBO(0, 0, 0, 0.75),
    ),
    (AccountProvider.apple, true) => (
      background: const Color(0xFFFFFFFF),
      foreground: const Color(0xFF000000),
      border: const Color.fromRGBO(255, 255, 255, 0.75),
    ),
    (AccountProvider.google, false) => (
      background: const Color.fromRGBO(250, 249, 246, 0.92),
      foreground: const Color(0xFF3D3A3E),
      border: const Color.fromRGBO(61, 58, 62, 0.12),
    ),
    (AccountProvider.google, true) => (
      background: const Color(0xFF131314),
      foreground: const Color(0xFFFFFFFF),
      border: const Color(0xFF8E918F),
    ),
  };

  /// The web's `transform: rotate(-2deg)` on the wordmark and pencil note.
  static const double _wordmarkTilt = 2 * math.pi / 180;

  /// The pencil note's size: the web's 11 px, up for the phone.
  static const double _lastUsedSize = 13;

  /// The tracking has to come down with the size: `wordmark` carries the 34 pt
  /// style's -0.045em as a flat -1.53, which at 13 pt would be -0.118em and
  /// crush the word. The note's own is -0.025em.
  static TextStyle _lastUsedStyle(MixtapeTokens tokens) =>
      tokens.wordmark.copyWith(
        fontSize: _lastUsedSize,
        letterSpacing: _lastUsedSize * -0.025,
        color: tokens.smoke,
      );

  // A non-breaking space keeps "right now." on one line instead of an orphan.
  static const String _headline = 'Your music, mixed for right\u00a0now.';

  /// The founder's 2026-09-18 sizing: a quieter headline than the shell's
  /// large title, and a 12 pt blurb under it.
  static TextStyle _headlineStyle(MixtapeTokens tokens) => tokens.largeTitle
      .copyWith(fontSize: 26, fontWeight: FontWeight.w500, letterSpacing: -0.4);

  static TextStyle _blurbStyle(MixtapeTokens tokens) =>
      tokens.body.copyWith(fontSize: 12, color: tokens.muted);

  static const String _blurb =
      'Start with a mood, a memory, or one song. Mixtape builds a mix '
      'from music you already love.';

  static const String _footNote = 'Music access is requested separately.';

  /// The scroll view's own vertical padding, top and bottom.
  static const double _scrollPadding = 24;

  /// The air around the tape, top and bottom.
  static const double _cassetteGap = 16;

  /// The web's `.auth-cassette` tilt.
  static const double _cassetteTilt = 4 * math.pi / 180;

  /// The tape's floor: below this it reads as an icon, not the motif, so a
  /// screen with no room left scrolls instead.
  static const double _minCassetteWidth = 120;

  /// The tape's ceiling on a phone; shorter screens shrink it.
  static const double _cassetteWidth = SignInScreen.cassetteWidth;

  static String _name(AccountProvider provider) =>
      provider == AccountProvider.apple ? 'Apple' : 'Google';
}

/// A full-width provider button, from the web's `.provider-sign-in` pill.
///
/// Stacked rather than side by side on the phone, and taller than the web's
/// 44 px so the mark and label clear a thumb. The colours come from the
/// caller: Apple and Google each own their button's appearance, and both
/// invert in the dark theme.
class ProviderSignInButton extends StatefulWidget {
  const ProviderSignInButton({
    super.key,
    required this.label,
    required this.mark,
    required this.background,
    required this.foreground,
    required this.borderColor,
    this.onPressed,
  });

  final String label;

  /// The provider's mark, drawn at [markSize].
  final Widget mark;

  final Color background;

  /// Label ink, and the [IconTheme] the mark inherits.
  final Color foreground;

  final Color borderColor;

  final VoidCallback? onPressed;

  /// The provider button's height floor.
  static const double height = 44;

  /// The label's inset above and below, inside [height].
  static const double verticalPadding = 8;

  /// The pill's label: one step under the row title.
  static TextStyle labelStyle(MixtapeTokens tokens) =>
      tokens.rowTitle.copyWith(fontSize: 14, fontWeight: FontWeight.w600);

  static const double markSize = 18;

  /// The web's `opacity: 0.66` on a disabled provider button.
  static const double disabledOpacity = 0.66;

  /// The press dip, short enough to read as a tap and not a transition.
  static const Duration pressDuration = Duration(milliseconds: 90);

  static const double pressedScale = 0.98;

  @override
  State<ProviderSignInButton> createState() => _ProviderSignInButtonState();
}

class _ProviderSignInButtonState extends State<ProviderSignInButton> {
  bool _pressed = false;

  void _setPressed(bool pressed) {
    if (_pressed == pressed) return;
    setState(() => _pressed = pressed);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final enabled = widget.onPressed != null;

    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      // `excludeSemantics` drops the detector's own tap action, and a node
      // with no action cannot be activated by VoiceOver — on this screen that
      // would leave no way in at all. Declare it here.
      onTap: widget.onPressed,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled ? (_) => _setPressed(true) : null,
        onTapUp: enabled ? (_) => _setPressed(false) : null,
        onTapCancel: enabled ? () => _setPressed(false) : null,
        onTap: widget.onPressed,
        child: AnimatedScale(
          scale: _pressed ? ProviderSignInButton.pressedScale : 1,
          duration: ProviderSignInButton.pressDuration,
          curve: Curves.easeOut,
          child: Opacity(
            opacity: enabled ? 1 : ProviderSignInButton.disabledOpacity,
            // A floor, not a fixed height: the label must grow at 200% text.
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: ProviderSignInButton.height,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: widget.background,
                  borderRadius: BorderRadius.circular(
                    MixtapeMetrics.pillRadius,
                  ),
                  border: Border.all(color: widget.borderColor),
                  boxShadow: enabled
                      ? const [
                          BoxShadow(
                            color: Color.fromRGBO(39, 32, 39, 0.16),
                            offset: Offset(0, 5),
                            blurRadius: 12,
                          ),
                        ]
                      : null,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: ProviderSignInButton.verticalPadding,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconTheme.merge(
                        data: IconThemeData(color: widget.foreground),
                        child: widget.mark,
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          widget.label,
                          textAlign: TextAlign.center,
                          style: ProviderSignInButton.labelStyle(
                            tokens,
                          ).copyWith(color: widget.foreground),
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
    );
  }
}

/// The Apple mark, from the web client's `ProviderMarks.tsx` path.
///
/// Gap: the marks belong beside the other foundation widgets. Task 8.5 may
/// only touch the auth screens, so they live here and Account and Choose
/// service import them.
// TODO(Phase 9): move AppleMark/GoogleMark to widgets/foundation/.
class AppleMark extends StatelessWidget {
  const AppleMark({super.key, this.size = 20, this.color});

  final double size;

  /// Defaults to the ink of whatever surface it sits on.
  final Color? color;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _AppleMarkPainter(color ?? IconTheme.of(context).color!),
      ),
    ),
  );
}

/// Google's four-colour G, from the web client's `ProviderMarks.tsx` paths.
class GoogleMark extends StatelessWidget {
  const GoogleMark({super.key, this.size = 20});

  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: size,
      child: const CustomPaint(painter: _GoogleMarkPainter()),
    ),
  );
}

/// Both marks are drawn in the source SVG's 24 × 24 viewBox.
const double _viewBox = 24;

class _AppleMarkPainter extends CustomPainter {
  const _AppleMarkPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.shortestSide / _viewBox);
    canvas.drawPath(
      Path()
        ..moveTo(16.71, 12.74)
        ..cubicTo(16.73, 14.89, 18.6, 15.61, 18.62, 15.62)
        ..cubicTo(18.6, 15.67, 18.32, 16.64, 17.64, 17.65)
        ..cubicTo(17.05, 18.52, 16.43, 19.38, 15.46, 19.4)
        ..cubicTo(14.51, 19.42, 14.2, 18.83, 13.11, 18.83)
        ..cubicTo(12.02, 18.83, 11.68, 19.38, 10.78, 19.42)
        ..cubicTo(9.84, 19.45, 9.13, 18.48, 8.53, 17.62)
        ..cubicTo(7.31, 15.85, 6.38, 12.62, 7.63, 10.44)
        ..cubicTo(8.231, 9.35, 9.365, 8.66, 10.61, 8.63)
        ..cubicTo(11.54, 8.61, 12.42, 9.26, 12.96, 9.26)
        ..cubicTo(13.5, 9.26, 14.52, 8.48, 15.59, 8.6)
        ..cubicTo(16.04, 8.62, 17.3, 8.78, 18.11, 9.97)
        ..cubicTo(18.04, 10.01, 16.61, 10.85, 16.71, 12.74)
        ..close()
        ..moveTo(14.89, 7.47)
        ..cubicTo(15.38, 6.87, 15.72, 6.04, 15.63, 5.21)
        ..cubicTo(14.91, 5.24, 14.04, 5.69, 13.53, 6.29)
        ..cubicTo(13.07, 6.82, 12.67, 7.67, 12.78, 8.48)
        ..cubicTo(13.58, 8.54, 14.4, 8.07, 14.89, 7.47)
        ..close(),
      Paint()..color = color,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AppleMarkPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _GoogleMarkPainter extends CustomPainter {
  const _GoogleMarkPainter();

  static const Color _blue = Color(0xFF4285F4);
  static const Color _green = Color(0xFF34A853);
  static const Color _yellow = Color(0xFFFBBC05);
  static const Color _red = Color(0xFFEA4335);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.shortestSide / _viewBox);
    canvas.drawPath(
      Path()
        ..moveTo(21.6, 12.23)
        ..cubicTo(21.6, 11.52, 21.54, 10.83, 21.42, 10.17)
        ..lineTo(12, 10.17)
        ..lineTo(12, 14.06)
        ..lineTo(17.38, 14.06)
        ..cubicTo(17.15, 15.3, 16.43, 16.39, 15.38, 17.08)
        ..lineTo(15.38, 19.6)
        ..lineTo(18.62, 19.6)
        ..cubicTo(20.52, 17.86, 21.6, 15.29, 21.6, 12.23)
        ..close(),
      Paint()..color = _blue,
    );
    canvas.drawPath(
      Path()
        ..moveTo(12, 22)
        ..cubicTo(14.7, 22, 16.97, 21.1, 18.62, 19.6)
        ..lineTo(15.38, 17.08)
        ..cubicTo(14.48, 17.68, 13.33, 18.04, 12, 18.04)
        ..cubicTo(9.39, 18.04, 7.18, 16.28, 6.39, 13.91)
        ..lineTo(3.04, 13.91)
        ..lineTo(3.04, 16.51)
        ..cubicTo(4.747, 19.89, 8.215, 22.01, 12, 22)
        ..close(),
      Paint()..color = _green,
    );
    canvas.drawPath(
      Path()
        ..moveTo(6.39, 13.91)
        ..cubicTo(6.184, 13.29, 6.079, 12.65, 6.08, 12)
        ..cubicTo(6.08, 11.34, 6.19, 10.7, 6.39, 10.09)
        ..lineTo(6.39, 7.49)
        ..lineTo(3.04, 7.49)
        ..cubicTo(2.345, 8.891, 1.989, 10.44, 2, 12)
        ..cubicTo(2, 13.61, 2.39, 15.14, 3.04, 16.51)
        ..lineTo(6.39, 13.91)
        ..close(),
      Paint()..color = _yellow,
    );
    canvas.drawPath(
      Path()
        ..moveTo(12, 5.96)
        ..cubicTo(13.47, 5.96, 14.79, 6.47, 15.83, 7.46)
        ..lineTo(18.7, 4.58)
        ..cubicTo(16.88, 2.889, 14.48, 1.965, 12, 2)
        ..cubicTo(8.215, 1.987, 4.747, 4.112, 3.04, 7.49)
        ..lineTo(6.39, 10.09)
        ..cubicTo(7.18, 7.72, 9.39, 5.96, 12, 5.96)
        ..close(),
      Paint()..color = _red,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GoogleMarkPainter oldDelegate) => false;
}
