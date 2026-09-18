import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/listening/listening_models.dart';
import '../providers/auth_provider.dart';
import '../providers/onboarding_provider.dart';
import '../theme/mixtape_theme.dart';
import '../widgets/foundation/flush_row.dart';
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/large_title_scaffold.dart';
import '../widgets/foundation/text_action.dart';
import 'shell/shell_screen.dart';
import 'spotify_request_screen.dart';

/// The service gate: what a signed-in listener sees first. Sits where Home
/// used to in main.dart's status switch and resolves to one of three
/// siblings — a spinner while onboarding loads, [ChooseServiceScreen] for a
/// listener with no service, sources, or library, or [ShellScreen]. Nothing
/// here is a pushed route: choosing Spotify shows [SpotifyRequestScreen] as
/// the gate's second step, and "Done, take me to the tapes" swaps in the
/// shell. Every route the app pushes goes on a tab navigator inside it.
///
/// The decision is latched once made: a later refetch (the `chose_spotify`
/// event lands and onboarding starts saying 'spotify', or a manual refresh
/// after a failed load succeeds) must never swap the screen out from under
/// the listener. An auth transition disposes the gate with the rest of the
/// signed-in tree, so the next listener starts from pending again — and
/// decides only from state loaded for them: the keep-alive provider carries
/// the previous account's value or error into the next one's loading state,
/// which is why [_resolve] sees the value with that history stripped.
class ServiceGate extends ConsumerStatefulWidget {
  const ServiceGate({super.key});

  @override
  ConsumerState<ServiceGate> createState() => _ServiceGateState();
}

enum _GateStep { pending, choose, request, home }

class _ServiceGateState extends ConsumerState<ServiceGate> {
  _GateStep _step = _GateStep.pending;

  /// Same busy guard and failure line as `account_screen.dart`'s `_signOut`:
  /// a second tap while the first is in flight does nothing, and a throw
  /// leaves the listener here with something to read rather than silence.
  bool _signingOut = false;
  String? _signOutError;

  /// Null while onboarding is still loading. An error falls through to Home:
  /// a listener is never locked out of the tapes by an unreadable
  /// onboarding state.
  static _GateStep? _resolve(AsyncValue<OnboardingState> onboarding) {
    if (onboarding.hasValue) {
      return onboarding.value!.chosenService == null
          ? _GateStep.choose
          : _GateStep.home;
    }
    if (onboarding.hasError) return _GateStep.home;
    return null;
  }

  /// Every answer on this screen writes the device's per-user service flag,
  /// and a sign-out clears that flag for the departing listener — so an
  /// answer given while the sign-out is in flight could land after the clear
  /// and leave the next sign-in silently past the gate. The busy guard covers
  /// the whole screen, not just its own action.
  void _chooseApple() {
    if (_signingOut) return;
    // Remembered on the device only (nothing to post), then Home right away.
    unawaited(ref.read(onboardingProvider.notifier).markChoseApple());
    setState(() => _step = _GateStep.home);
  }

  void _chooseSpotify() {
    if (_signingOut) return;
    // Fire-and-forget funnel step, then the request screen right away.
    unawaited(ref.read(onboardingProvider.notifier).markChoseSpotify());
    setState(() => _step = _GateStep.request);
  }

  void _skip() {
    if (_signingOut) return;
    // Like Apple: remembered on the device, nothing posted, shell right away.
    unawaited(ref.read(onboardingProvider.notifier).markSkipped());
    setState(() => _step = _GateStep.home);
  }

  Future<void> _signOut() async {
    if (_signingOut) return;
    setState(() {
      _signingOut = true;
      _signOutError = null;
    });
    try {
      await ref.read(authProvider.notifier).signOut();
    } catch (_) {
      if (mounted) {
        setState(() => _signOutError = 'Couldn’t sign out. Try again.');
      }
    } finally {
      if (mounted) setState(() => _signingOut = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(onboardingProvider, (previous, next) {
      if (_step == _GateStep.request && next.value?.importCompletedAt != null) {
        setState(() => _step = _GateStep.home);
      }
    });
    if (_step == _GateStep.pending) {
      final resolved = _resolve(ref.watch(onboardingProvider).unwrapPrevious());
      if (resolved == null) {
        // Same spinner as AuthStatus.unknown in main.dart.
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      _step = resolved;
    }
    return switch (_step) {
      _GateStep.choose => ChooseServiceScreen(
        onApple: _chooseApple,
        onSpotify: _chooseSpotify,
        onSignOut: _signingOut ? null : _signOut,
        onSkip: _signingOut ? null : _skip,
        signOutError: _signOutError,
      ),
      _GateStep.request => SpotifyRequestScreen(
        onDone: () => setState(() => _step = _GateStep.home),
      ),
      _GateStep.pending || _GateStep.home => const ShellScreen(),
    };
  }
}

/// "Which do you use?" — Apple Music records nothing (the existing library
/// sync from Home is the Apple path); Spotify starts the request flow;
/// skipping remembers that answer and opens the shell anyway.
///
/// Two flush rows under a large title, each with its service mark and the one
/// line that says what choosing it does, then the way past them. The listener
/// is already signed in here and a relaunch brings them back, so Sign out
/// rides the title bar: this screen is never a dead end.
class ChooseServiceScreen extends StatelessWidget {
  const ChooseServiceScreen({
    super.key,
    required this.onApple,
    required this.onSpotify,
    required this.onSkip,
    this.onSignOut,
    this.signOutError,
  });

  final VoidCallback onApple;
  final VoidCallback onSpotify;

  /// Both null while a sign-out is in flight, which dims the action and drops
  /// its tap target — the gate's busy guard, shown.
  final VoidCallback? onSkip;
  final VoidCallback? onSignOut;

  /// Set when the last sign-out threw.
  final String? signOutError;

  /// The service marks, and the hairline's inset past them. Single-tone and
  /// small (founder, 2026-09-18): a glyph in the row's ink, not the app icons.
  static const double markSize = 28;
  static const Key appleMarkKey = Key('choose-apple-mark');
  static const Key spotifyMarkKey = Key('choose-spotify-mark');
  static const Key signOutKey = Key('choose-service-sign-out');
  static const Key skipKey = Key('choose-service-skip');

  static const String intro =
      'Mixtape builds each mix from what you already listen to.';
  static const String skipNote =
      'You can connect a service later from Library.';

  /// The air the founder asked for between the intro line and the first row.
  static const double introGap = 32;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return GradientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: LargeTitleScaffold(
          // Kept from the shipped screen: `service_gate_test` pins this copy.
          title: 'Which do you use?',
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    intro,
                    style: tokens.meta.copyWith(
                      color: tokens.muted,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: introGap),
                  FlushList(
                    children: [
                      _ServiceRow(
                        buttonKey: const Key('choose-apple'),
                        mark: const _AppleMusicMark(),
                        title: 'Apple Music',
                        subtitle: 'Syncs your library right away.',
                        onTap: onApple,
                      ),
                      _ServiceRow(
                        buttonKey: const Key('choose-spotify'),
                        mark: const _SpotifyMark(),
                        title: 'Spotify',
                        subtitle:
                            'Bring your saved music with an Exportify ZIP or CSV.',
                        onTap: onSpotify,
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Center(
                    child: TextAction(
                      key: skipKey,
                      label: 'Skip',
                      icon: Icons.arrow_forward,
                      iconAfter: true,
                      onPressed: onSkip,
                    ),
                  ),
                  Text(
                    skipNote,
                    textAlign: TextAlign.center,
                    style: tokens.meta.copyWith(color: tokens.muted),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
            // Sign out lives at the foot, bottom-left: the way out of an
            // account, away from the choices. Fills the screen so it sits on
            // the bottom edge; on a short screen it scrolls into view.
            SliverFillRemaining(
              hasScrollBody: false,
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Padding(
                  padding: EdgeInsets.only(
                    bottom: MediaQuery.paddingOf(context).bottom + 16,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (signOutError != null) ...[
                        Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: Text(
                            signOutError!,
                            style: tokens.meta.copyWith(color: tokens.errInk),
                          ),
                        ),
                        const SizedBox(height: 4),
                      ],
                      TextAction(
                        key: signOutKey,
                        label: 'Sign out',
                        icon: Icons.logout,
                        quiet: true,
                        onPressed: onSignOut,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A flush row wrapped in a keyed button: the house rule wants every
/// interactive control keyed and findable as a Material button.
class _ServiceRow extends StatelessWidget {
  const _ServiceRow({
    required this.buttonKey,
    required this.mark,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  /// Sits on the button itself: the house rule audits Material controls.
  final Key buttonKey;

  final Widget mark;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => TextButton(
    key: buttonKey,
    onPressed: onTap,
    style: TextButton.styleFrom(
      padding: EdgeInsets.zero,
      minimumSize: const Size.fromHeight(MixtapeMetrics.minTarget),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: const RoundedRectangleBorder(),
      alignment: Alignment.centerLeft,
    ),
    child: FlushRow(
      leading: mark,
      leadingSize: ChooseServiceScreen.markSize,
      title: title,
      subtitle: subtitle,
      // The Spotify line is a full sentence; ellipsising it hid half of it.
      subtitleMaxLines: 2,
      trailing: Icon(
        Icons.chevron_right,
        size: 20,
        color: context.tokens.muted.withValues(alpha: 0.6),
      ),
    ),
  );
}

/// Apple Music: the beamed double eighth note from the app icon, drawn
/// alone in the row's ink (no tile, no red).
class _AppleMusicMark extends StatelessWidget {
  const _AppleMusicMark();

  @override
  Widget build(BuildContext context) => SizedBox.square(
    key: ChooseServiceScreen.appleMarkKey,
    dimension: ChooseServiceScreen.markSize,
    child: ExcludeSemantics(
      child: CustomPaint(painter: _AppleMusicMarkPainter(context.tokens.text)),
    ),
  );
}

/// Spotify: the disc with its three waves knocked out, in the row's ink.
class _SpotifyMark extends StatelessWidget {
  const _SpotifyMark();

  @override
  Widget build(BuildContext context) => SizedBox.square(
    key: ChooseServiceScreen.spotifyMarkKey,
    dimension: ChooseServiceScreen.markSize,
    child: ExcludeSemantics(
      child: CustomPaint(painter: _SpotifyMarkPainter(context.tokens.text)),
    ),
  );
}

/// Both marks are drawn in a 24 × 24 box and scaled to the mark's size, the
/// same way `sign_in_screen.dart` draws the Apple and Google marks.
const double _viewBox = 24;

class _AppleMusicMarkPainter extends CustomPainter {
  const _AppleMusicMarkPainter(this.ink);

  final Color ink;

  /// The glyph's share of the box: the same optical size as the disc beside it.
  static const double _glyphFraction = 0.82;

  /// Left stem, right stem — the right one is shorter, as the mark draws it.
  static const Rect _leftStem = Rect.fromLTRB(8.6, 4.3, 10.6, 18.0);
  static const Rect _rightStem = Rect.fromLTRB(19.4, 6.4, 21.4, 16.2);

  /// The beam joining the stem tops, slanting down to the right.
  static const List<Offset> _beam = [
    Offset(8.6, 2.7),
    Offset(21.4, 5.1),
    Offset(21.4, 8.7),
    Offset(8.6, 6.3),
  ];

  /// Note heads: centre, radii, and the tilt every music face gives them.
  static const Offset _leftHead = Offset(6.6, 17.6);
  static const Offset _rightHead = Offset(17.6, 15.8);
  static const Size _leftHeadRadii = Size(4.0, 3.15);
  static const Size _rightHeadRadii = Size(3.8, 3.0);
  static const double _headTilt = -0.33;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    final glyph = side * _glyphFraction;
    canvas.save();
    canvas.translate((side - glyph) / 2, (side - glyph) / 2);
    canvas.scale(glyph / _viewBox);

    final paint = Paint()..color = ink;
    canvas.drawPath(
      Path()
        ..addRect(_leftStem)
        ..addRect(_rightStem)
        ..addPolygon(_beam, true),
      paint,
    );
    _drawHead(canvas, paint, _leftHead, _leftHeadRadii);
    _drawHead(canvas, paint, _rightHead, _rightHeadRadii);

    canvas.restore();
  }

  void _drawHead(Canvas canvas, Paint ink, Offset center, Size radii) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(_headTilt);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset.zero,
        width: radii.width * 2,
        height: radii.height * 2,
      ),
      ink,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AppleMusicMarkPainter oldDelegate) =>
      oldDelegate.ink != ink;
}

class _SpotifyMarkPainter extends CustomPainter {
  const _SpotifyMarkPainter(this.ink);

  /// One tone: the disc is [ink] and the waves are cut out of it.
  final Color ink;

  /// Every wave bows the same share of its own width, so the three read as
  /// one family rather than as nested rings — concentric arcs about a single
  /// centre make the short bottom one curl up like a wifi glyph, which the
  /// logo's does not.
  static const double _bow = 0.30;

  /// Where each wave's apex sits, half the chord it spans, and its stroke —
  /// the official proportions, as fractions of the 24 pt disc: the top wave
  /// is the widest (66% of the diameter) and the thickest (9%), the bottom
  /// the shortest (46%) and the thinnest (7%), the apexes evenly spaced and
  /// the group centred a touch above the disc's own centre.
  static const List<(double, double, double)> _waves = [
    (6.6, 7.92, 2.16),
    (10.3, 6.72, 1.92),
    (14.0, 5.52, 1.68),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    // A layer, so the waves knock through to whatever is behind the mark.
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.scale(size.shortestSide / _viewBox);
    canvas.drawCircle(const Offset(12, 12), 12, Paint()..color = ink);
    for (final (apex, halfChord, stroke) in _waves) {
      // Bowed upward in the middle: the apex is the top of a circle whose
      // centre hangs below the disc, far enough that the wave rises [_bow]
      // of its half-chord above the line joining its ends.
      final sagitta = halfChord * _bow;
      final radius =
          (halfChord * halfChord + sagitta * sagitta) / (2 * sagitta);
      final sweep = 2 * math.asin(halfChord / radius);
      canvas.drawArc(
        Rect.fromCircle(center: Offset(12, apex + radius), radius: radius),
        -math.pi / 2 - sweep / 2,
        sweep,
        false,
        Paint()
          ..blendMode = BlendMode.clear
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SpotifyMarkPainter oldDelegate) => oldDelegate.ink != ink;
}
