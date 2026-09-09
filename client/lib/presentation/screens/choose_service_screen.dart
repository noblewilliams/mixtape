import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/listening/listening_models.dart';
import '../providers/onboarding_provider.dart';
import 'home_screen.dart';
import 'spotify_request_screen.dart';

/// The service gate: what a signed-in listener sees first. Sits where Home
/// used to in main.dart's status switch and resolves to one of three
/// siblings — a spinner while onboarding loads, [ChooseServiceScreen] for a
/// listener with no service, sources, or library, or [HomeScreen]. Nothing
/// here is a pushed route: choosing Spotify shows [SpotifyRequestScreen] as
/// the gate's second step, and "Done, take me to the tapes" swaps in Home.
/// Home stays the only screen that pushes routes and hosts sign-out.
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
      _GateStep.pending || _GateStep.home => const HomeScreen(),
    };
  }
}

/// "Which do you use?" — Apple Music records nothing (the existing library
/// sync from Home is the Apple path); Spotify starts the request flow.
class ChooseServiceScreen extends StatelessWidget {
  const ChooseServiceScreen({
    super.key,
    required this.onApple,
    required this.onSpotify,
  });

  final VoidCallback onApple;
  final VoidCallback onSpotify;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Which do you use?',
                style: textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                'Mixtape builds each mix from what you already listen to.',
                style: textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              FilledButton.icon(
                key: const Key('choose-apple'),
                onPressed: onApple,
                icon: const Icon(Icons.library_music_outlined),
                label: const Text('Apple Music'),
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                key: const Key('choose-spotify'),
                onPressed: onSpotify,
                icon: const Icon(Icons.download_outlined),
                label: const Text('Spotify'),
              ),
              const SizedBox(height: 24),
              Text(
                'Apple Music syncs your library right away. '
                'Spotify takes a data request first, and the DJ helps you through it.',
                style: textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
