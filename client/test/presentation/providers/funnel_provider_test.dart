import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/data/onboarding/funnel_once_store.dart';
import 'package:mixtape/data/onboarding/service_preference_store.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/device_providers.dart';
import 'package:mixtape/presentation/providers/funnel_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';

import '../../helpers/fake_listening_api.dart';
import '../../helpers/onboarding_harness.dart' show TestAuthNotifier;

/// Lets the fire-and-forget posts (unawaited by design) run out.
Future<void> _flush() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

ProviderContainer _container({
  required FakeListeningApi listening,
  required FunnelOnceStore store,
}) {
  final container = ProviderContainer(
    overrides: [
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.signedIn)),
      listeningApiProvider.overrideWithValue(listening),
      servicePreferenceStoreProvider.overrideWithValue(InMemoryServicePreferenceStore()),
      funnelOnceStoreProvider.overrideWithValue(store),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('a rejecting post leaves the once-flag clear, and the next output posts again', () async {
    final listening = FakeListeningApi();
    var attempts = 0;
    listening.onPostFunnelEvent = (_) async {
      if (++attempts == 1) throw StateError('offline');
    };
    final store = InMemoryFunnelOnceStore();
    final container = _container(listening: listening, store: store);
    // The service gate loads this before any signed-in screen exists.
    await container.read(onboardingProvider.future);

    container.read(funnelMilestonesProvider).recordOnce(FunnelEventType.firstOutput);
    await _flush();
    expect(listening.funnelEvents, [FunnelEventType.firstOutput], reason: 'it was attempted');
    expect(
      await store.has('user-1', FunnelEventType.firstOutput),
      isFalse,
      reason: 'a dropped post must not silence the milestone forever',
    );

    container.read(funnelMilestonesProvider).recordOnce(FunnelEventType.firstOutput);
    await _flush();
    expect(listening.funnelEvents, [FunnelEventType.firstOutput, FunnelEventType.firstOutput]);
    expect(await store.has('user-1', FunnelEventType.firstOutput), isTrue);

    container.read(funnelMilestonesProvider).recordOnce(FunnelEventType.firstOutput);
    await _flush();
    expect(listening.funnelEvents, hasLength(2), reason: 'the flag holds once the post lands');
  });

  test('an onboarding read still in flight posts nothing — it is never awaited', () async {
    final listening = FakeListeningApi();
    final pending = Completer<OnboardingState>();
    listening.onGetOnboarding = () => pending.future;
    final container = _container(listening: listening, store: InMemoryFunnelOnceStore());
    container.read(onboardingProvider); // kicks the load off; nothing resolved yet

    container.read(funnelMilestonesProvider).recordOnce(FunnelEventType.firstOutput);
    await _flush();
    expect(listening.funnelEvents, isEmpty);

    // House rule (CLAUDE.md): a user-scoped provider is never awaited across
    // an auth transition, so the milestone is dropped rather than queued
    // behind the read and fired at whoever is signed in when it lands.
    pending.complete(onboardingState(chosenService: 'spotify'));
    await _flush();
    expect(listening.funnelEvents, isEmpty);
  });
}
