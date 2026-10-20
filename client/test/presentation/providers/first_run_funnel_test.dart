// The first run's funnel events (first-run spec → Clients, "Funnel
// events"): held in memory until the anonymous session exists, posted once
// per anonymous listener, never for an account, never by creating a session.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/data/onboarding/funnel_once_store.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/device_providers.dart';
import 'package:mixtape/presentation/providers/first_run_funnel_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';

import '../../helpers/fake_listening_api.dart';
import '../../screens/first_run/first_run_harness.dart' show FirstRunAuth;

class _Auth extends FirstRunAuth {
  _Auth(super.initial, {super.anonymous});

  /// The welcome foot link's sign-in: an account, not a link.
  void signInAccount() => state = AuthStatus.session;
}

class _Rig {
  _Rig({AuthStatus status = AuthStatus.noSession, bool anonymous = false})
    : auth = _Auth(status, anonymous: anonymous);

  final _Auth auth;
  final FakeListeningApi api = FakeListeningApi();
  final InMemoryFunnelOnceStore store = InMemoryFunnelOnceStore();

  late final ProviderContainer container = () {
    final c = ProviderContainer(
      overrides: [
        authProvider.overrideWith(() => auth),
        listeningApiProvider.overrideWithValue(api),
        funnelOnceStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(c.dispose);
    // The auth state is read the way the screens read it: live.
    c.read(authProvider);
    return c;
  }();

  FirstRunFunnel get funnel => container.read(firstRunFunnelProvider);
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('events before the session are held, then posted once, in order, '
      'after signInAnonymously succeeds', () async {
    final r = _Rig();
    r.funnel
      ..record(FunnelEventType.firstRunOpened)
      ..record(FunnelEventType.choseAddMusic)
      ..record(FunnelEventType.choseService)
      ..record(FunnelEventType.firstRunOpened);
    await _settle();
    expect(r.api.funnelEvents, isEmpty, reason: 'no session yet');
    expect(r.auth.anonymousSignIns, 0, reason: 'never created just to post');

    await r.container.read(authProvider.notifier).signInAnonymously();
    await _settle();
    await _settle();
    expect(r.api.funnelEvents, [
      FunnelEventType.firstRunOpened,
      FunnelEventType.choseAddMusic,
      FunnelEventType.choseService,
    ]);

    r.funnel
      ..record(FunnelEventType.choseMethod)
      ..record(FunnelEventType.choseService);
    await _settle();
    await _settle();
    expect(r.api.funnelEvents.last, FunnelEventType.choseMethod);
    expect(r.api.funnelEvents, hasLength(4));
    expect(
      await r.store.has(anonymousFunnelKey, FunnelEventType.choseMethod),
      isTrue,
    );
  });

  test('an account never posts them; events held before an account sign-in '
      'are dropped', () async {
    final r = _Rig();
    r.funnel.record(FunnelEventType.firstRunOpened);
    r.auth.signInAccount();
    await _settle();
    r.funnel.record(FunnelEventType.capReached);
    r.funnel.noteMixReply(4);
    await _settle();
    expect(r.api.funnelEvents, isEmpty);
  });

  test('a flag from an earlier launch keeps a repeat from posting', () async {
    final r = _Rig(status: AuthStatus.session, anonymous: true);
    await r.store.mark(anonymousFunnelKey, FunnelEventType.capReached);
    r.funnel.record(FunnelEventType.capReached);
    await _settle();
    await _settle();
    expect(r.api.funnelEvents, isEmpty);
  });

  group('the first mix reply', () {
    test('content: first_mix_made, once', () async {
      final r = _Rig(status: AuthStatus.session, anonymous: true);
      r.funnel
        ..noteMixReply(12)
        ..noteMixReply(9);
      await _settle();
      await _settle();
      expect(r.api.funnelEvents, [FunnelEventType.firstMixMade]);
    });

    test('an empty first reply: first_mix_refused; content later still '
        'counts as made', () async {
      final r = _Rig(status: AuthStatus.session, anonymous: true);
      r.funnel.noteMixReply(0);
      await _settle();
      await _settle();
      await _settle();
      expect(r.api.funnelEvents, [FunnelEventType.firstMixRefused]);

      r.funnel
        ..noteMixReply(0)
        ..noteMixReply(5);
      await _settle();
      await _settle();
      expect(r.api.funnelEvents, [
        FunnelEventType.firstMixRefused,
        FunnelEventType.firstMixMade,
      ]);
    });

    test('an empty reply after a made one is not a refusal', () async {
      final r = _Rig(status: AuthStatus.session, anonymous: true);
      r.funnel.noteMixReply(3);
      r.funnel.noteMixReply(0);
      await _settle();
      await _settle();
      await _settle();
      expect(r.api.funnelEvents, [FunnelEventType.firstMixMade]);
    });

    test('an empty reply in a later launch, after a made one, is not a '
        'refusal', () async {
      final r = _Rig(status: AuthStatus.session, anonymous: true);
      await r.store.mark(anonymousFunnelKey, FunnelEventType.firstMixMade);
      r.funnel.noteMixReply(0);
      await _settle();
      await _settle();
      await _settle();
      expect(r.api.funnelEvents, isEmpty);
    });
  });

  test('a sign-out starts over for the next listener', () async {
    final r = _Rig(status: AuthStatus.session, anonymous: true);
    r.funnel.record(FunnelEventType.firstRunOpened);
    await _settle();
    await _settle();
    await r.container.read(authProvider.notifier).signOut();
    await r.store.clear(); // what the real sign-out does to the flags
    r.funnel.record(FunnelEventType.firstRunOpened);
    await r.container.read(authProvider.notifier).signInAnonymously();
    await _settle();
    await _settle();
    expect(r.api.funnelEvents, [
      FunnelEventType.firstRunOpened,
      FunnelEventType.firstRunOpened,
    ]);
  });
}
