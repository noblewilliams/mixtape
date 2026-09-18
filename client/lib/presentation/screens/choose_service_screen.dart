import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/listening/listening_models.dart';
import '../providers/auth_provider.dart';
import '../providers/onboarding_provider.dart';
import '../theme/mixtape_theme.dart';
import '../widgets/foundation/flush_row.dart';
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/large_title_scaffold.dart';
import '../widgets/foundation/service_marks.dart';
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
                        mark: const AppleMusicMark(
                          key: ChooseServiceScreen.appleMarkKey,
                          size: ChooseServiceScreen.markSize,
                        ),
                        title: 'Apple Music',
                        subtitle: 'Syncs your library right away.',
                        onTap: onApple,
                      ),
                      _ServiceRow(
                        buttonKey: const Key('choose-spotify'),
                        mark: const SpotifyMark(
                          key: ChooseServiceScreen.spotifyMarkKey,
                          size: ChooseServiceScreen.markSize,
                        ),
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
                      icon: Icons.fast_forward_rounded,
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
            // account, away from the choices. Transport glyphs throughout
            // (founder, 2026-09-18): Skip fast-forwards, Sign out stops. Fills the screen so it sits on
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
                        icon: Icons.stop_rounded,
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
