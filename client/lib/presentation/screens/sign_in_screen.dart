/// Sign-in (`docs/mockups/approved/2026-09-08-mobile-parity.md` → Apple and
/// Google as equal logins; shell board `docs/mockups/approved/
/// 2026-09-17-mobile-shell.md` for the type, gradient and tape controls).
///
/// Two providers, side by side and equal: the wordmark, the promise, a
/// full-width tape button each, the remembered method marked, one reserved
/// line for waiting or failure, and the Apple Music note at the foot.
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
import '../widgets/foundation/gradient_background.dart';

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  /// The reserved status line: waiting, or the safe failure sentence.
  static const Key errorKey = Key('sign-in-error');

  /// The muted reason under the Google button in a build without the
  /// `--dart-define-from-file=config/google-ios.json` configuration.
  static const Key googleUnavailableKey = Key('google-unavailable');

  static const String googleUnavailable =
      'Google sign-in is not available in this build.';

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
    final googleAvailable = ref.watch(googleAuthGatewayProvider).isAvailable;
    final lastUsed = ref.watch(lastSignInProvider).value;

    return GradientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          // Centre caps the width against the bounded screen height, so the
          // scroll view below still knows how tall a screenful is.
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: MixtapeMetrics.screenSidePadding,
                    vertical: 24,
                  ),
                  // A screenful tall, so the Apple Music note sits at the
                  // foot; taller content (200% text) scrolls instead.
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: math.max(0, constraints.maxHeight - 48),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('mixtape', style: tokens.smallTitle),
                        _promise(tokens, googleAvailable, lastUsed),
                        Text(
                          'Apple Music access is requested separately.',
                          style: tokens.meta.copyWith(color: tokens.muted),
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

  Widget _promise(
    MixtapeTokens tokens,
    bool googleAvailable,
    AccountProvider? lastUsed,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      const SizedBox(height: 28),
      Text('Your music.\nYour moment.', style: tokens.largeTitle),
      const SizedBox(height: 12),
      Text(
        'Sign in to keep your mixes and preferences.',
        style: tokens.body.copyWith(color: tokens.muted),
      ),
      const SizedBox(height: 32),
      for (final provider in AccountProvider.values) ...[
        ProviderSignInButton(
          key: Key('${provider.name}-sign-in'),
          label: 'Continue with ${_name(provider)}',
          mark: provider == AccountProvider.apple
              ? const AppleMark()
              : const GoogleMark(),
          onPressed:
              _busy != null ||
                  (provider == AccountProvider.google && !googleAvailable)
              ? null
              : () => _signIn(provider),
        ),
        if (lastUsed == provider)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Last used',
              textAlign: TextAlign.center,
              style: tokens.meta.copyWith(color: tokens.muted),
            ),
          ),
        if (provider == AccountProvider.google && !googleAvailable)
          Padding(
            key: SignInScreen.googleUnavailableKey,
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              SignInScreen.googleUnavailable,
              textAlign: TextAlign.center,
              style: tokens.meta.copyWith(color: tokens.muted),
            ),
          ),
        const SizedBox(height: 14),
      ],
      _status(tokens),
    ],
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

  static String _name(AccountProvider provider) =>
      provider == AccountProvider.apple ? 'Apple' : 'Google';
}

/// A full-width provider button in the board's tape shell.
///
/// [TapeButton] shrink-wraps to its label by design (it is the 40 pt inline
/// mix control), so the 56 pt full-width sign-in bar is composed here from the
/// same tokens rather than by widening the shared control.
class ProviderSignInButton extends StatelessWidget {
  const ProviderSignInButton({
    super.key,
    required this.label,
    required this.mark,
    this.onPressed,
  });

  final String label;

  /// The provider's mark, drawn at [markSize].
  final Widget mark;

  final VoidCallback? onPressed;

  /// The board's provider button height.
  static const double height = 56;

  static const double markSize = 20;

  static const BorderRadius _radius = BorderRadius.only(
    topLeft: Radius.circular(MixtapeMetrics.tapeRadiusTop),
    topRight: Radius.circular(MixtapeMetrics.tapeRadiusTop),
    bottomLeft: Radius.circular(MixtapeMetrics.tapeRadiusBottom),
    bottomRight: Radius.circular(MixtapeMetrics.tapeRadiusBottom),
  );

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final enabled = onPressed != null;

    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Opacity(
          opacity: enabled ? 1 : 0.5,
          // A floor, not a fixed height: the label must grow at 200% text.
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: height),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: tokens.tapeFill,
                borderRadius: _radius,
                border: Border.all(color: tokens.tapeEdge),
                boxShadow: enabled
                    ? [
                        BoxShadow(
                          color: tokens.tapeShadow,
                          offset: const Offset(0, 2),
                          blurRadius: 0,
                        ),
                      ]
                    : null,
              ),
              child: ClipRRect(
                borderRadius: _radius,
                child: Stack(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconTheme.merge(
                            data: IconThemeData(color: tokens.tapeInk),
                            child: mark,
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              label,
                              textAlign: TextAlign.center,
                              style: tokens.rowTitle.copyWith(
                                fontWeight: FontWeight.w600,
                                color: tokens.tapeInk,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // The board's top highlight on the tape shell.
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: Container(
                        height: 1,
                        color: Colors.white.withValues(alpha: 0.13),
                      ),
                    ),
                  ],
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
