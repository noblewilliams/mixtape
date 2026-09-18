import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/listening/listening_models.dart';
import '../providers/onboarding_provider.dart';
import '../theme/mixtape_theme.dart';
import '../widgets/foundation/flush_row.dart';
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/large_title_scaffold.dart';
import 'shell/shell_screen.dart';
import 'sign_in_screen.dart' show AppleMark;
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

  void _chooseApple() {
    // Remembered on the device only (nothing to post), then Home right away.
    unawaited(ref.read(onboardingProvider.notifier).markChoseApple());
    setState(() => _step = _GateStep.home);
  }

  void _chooseSpotify() {
    // Fire-and-forget funnel step, then the request screen right away.
    unawaited(ref.read(onboardingProvider.notifier).markChoseSpotify());
    setState(() => _step = _GateStep.request);
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
      ),
      _GateStep.request => SpotifyRequestScreen(
        onDone: () => setState(() => _step = _GateStep.home),
      ),
      _GateStep.pending || _GateStep.home => const ShellScreen(),
    };
  }
}

/// "Which do you use?" — Apple Music records nothing (the existing library
/// sync from Home is the Apple path); Spotify starts the request flow.
///
/// Two flush rows under a large title, each with its service mark and the one
/// line that says what choosing it does.
class ChooseServiceScreen extends StatelessWidget {
  const ChooseServiceScreen({
    super.key,
    required this.onApple,
    required this.onSpotify,
  });

  final VoidCallback onApple;
  final VoidCallback onSpotify;

  /// The service marks, and the hairline's inset past them.
  static const double markSize = 44;
  static const Key appleMarkKey = Key('choose-apple-mark');
  static const Key spotifyMarkKey = Key('choose-spotify-mark');

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
                    'Mixtape builds each mix from what you already listen to.',
                    style: tokens.body.copyWith(color: tokens.muted),
                  ),
                  const SizedBox(height: 20),
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
                  const SizedBox(height: 24),
                ],
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
      trailing: Icon(
        Icons.chevron_right,
        size: 20,
        color: context.tokens.muted.withValues(alpha: 0.6),
      ),
    ),
  );
}

/// Apple Music: the Apple mark on the board's tile.
class _AppleMusicMark extends StatelessWidget {
  const _AppleMusicMark();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      key: ChooseServiceScreen.appleMarkKey,
      width: ChooseServiceScreen.markSize,
      height: ChooseServiceScreen.markSize,
      decoration: BoxDecoration(
        color: tokens.tapeFill,
        border: Border.all(color: tokens.tapeEdge),
        borderRadius: BorderRadius.circular(MixtapeMetrics.tileRadius),
      ),
      child: Center(child: AppleMark(size: 22, color: tokens.tapeInk)),
    );
  }
}

/// Spotify: the three waves on their green disc.
class _SpotifyMark extends StatelessWidget {
  const _SpotifyMark();

  @override
  Widget build(BuildContext context) => SizedBox.square(
    key: ChooseServiceScreen.spotifyMarkKey,
    dimension: ChooseServiceScreen.markSize,
    child: const ExcludeSemantics(
      child: CustomPaint(painter: _SpotifyMarkPainter()),
    ),
  );
}

class _SpotifyMarkPainter extends CustomPainter {
  const _SpotifyMarkPainter();

  static const Color _green = Color(0xFF1DB954);
  static const Color _ink = Color(0xFF121212);

  /// Radius, stroke and sweep of each wave, in the mark's own 24 pt box.
  static const List<(double, double, double)> _waves = [
    (8.0, 2.2, 0.62),
    (5.9, 1.9, 0.66),
    (3.9, 1.6, 0.70),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.shortestSide / 24);
    canvas.drawCircle(const Offset(12, 12), 12, Paint()..color = _green);
    for (final (radius, stroke, sweep) in _waves) {
      canvas.drawArc(
        Rect.fromCircle(center: const Offset(12, 15.5), radius: radius),
        -3.14159 * (0.5 + sweep / 2),
        3.14159 * sweep,
        false,
        Paint()
          ..color = _ink
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SpotifyMarkPainter oldDelegate) => false;
}
