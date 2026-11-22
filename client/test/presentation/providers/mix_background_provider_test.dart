// A mix turn keeps going when the listener leaves the app (2026-11-21): a
// background task holds the app awake while a turn is out, and a turn that
// lands while the app is in the background says so with a notification.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/background/mix_background.dart';
import 'package:mixtape/data/push/push_ask_store.dart';
import 'package:mixtape/data/push/push_service.dart';
import 'package:mixtape/presentation/providers/push_provider.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/mix_activity_provider.dart';
import 'package:mixtape/presentation/providers/mix_background_provider.dart';

import '../../helpers/fake_push_channel.dart';

class _Auth extends AuthNotifier {
  @override
  AuthStatus build() => AuthStatus.session;

  void flip(AuthStatus next) => state = next;
}

class _Holder implements BackgroundTaskHolder {
  final List<String> calls = [];

  @override
  Future<void> begin() async => calls.add('begin');

  @override
  Future<void> end() async => calls.add('end');
}

class _Alerts implements MixReadyAlerts {
  _Alerts({this.granted = true});

  final bool granted;
  int asked = 0;
  int shown = 0;
  Completer<void>? showing;

  @override
  Future<bool> requestPermission() async {
    asked++;
    return granted;
  }

  @override
  Future<void> showMixReady() async {
    shown++;
    await showing?.future;
  }
}

void main() {
  late ProviderContainer container;
  late _Holder holder;
  late _Alerts alerts;
  late FakePushChannel push;
  late InMemoryPushAskStore store;
  var foreground = true;

  MixActivityNotifier activity() =>
      container.read(mixActivityProvider.notifier);

  void build({bool granted = true, bool optedOut = false}) {
    holder = _Holder();
    alerts = _Alerts(granted: granted);
    push = FakePushChannel(
      current: granted ? PushStatus.authorized : PushStatus.notDetermined,
    );
    store = InMemoryPushAskStore(optedOut: optedOut);
    foreground = true;
    container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(_Auth.new),
        backgroundTaskHolderProvider.overrideWithValue(holder),
        mixReadyAlertsProvider.overrideWithValue(alerts),
        pushChannelProvider.overrideWithValue(push),
        pushAskStoreProvider.overrideWithValue(store),
        appInForegroundProvider.overrideWithValue(() => foreground),
      ],
    );
    addTearDown(container.dispose);
    // Read once, as the app does at start.
    container.read(mixActivityProvider);
  }

  test(
    'holds a background task while a turn is out, and lets go after',
    () async {
      build();
      final end = activity().beginTurn('a');
      await pumpEventQueue();
      expect(holder.calls, ['begin']);

      end(ready: true, succeeded: true);
      await pumpEventQueue();
      expect(holder.calls, ['begin', 'end']);
    },
  );

  test('holds one task across overlapping turns and a new mix', () async {
    build();
    final a = activity().beginTurn('a');
    final made = activity().beginNewMix('rainy commute');
    await pumpEventQueue();
    a(ready: true);
    await pumpEventQueue();
    expect(holder.calls, ['begin']);

    made(sessionId: 'b');
    await pumpEventQueue();
    expect(holder.calls, ['begin', 'end']);
  });

  test('never asks: it reads the permission at the first turn', () async {
    build();
    expect(container.read(mixBackgroundProvider), isFalse);
    activity().beginTurn('a')(ready: true);
    activity().beginTurn('b')(ready: true);
    await pumpEventQueue();
    // The Mix ready pop-up is the one ask.
    expect(alerts.asked, 0);
    expect(push.calls, isNot(contains('requestAuthorization')));
    expect(push.calls.where((c) => c == 'status'), hasLength(1));
    expect(container.read(mixBackgroundProvider), isTrue);
  });

  test('not allowed yet leaves pings off', () async {
    build(granted: false);
    activity().beginTurn('a');
    await pumpEventQueue();
    expect(container.read(mixBackgroundProvider), isFalse);
  });

  test('turned off in You: no ping, though iOS allows it', () async {
    build(optedOut: true);
    final end = activity().beginTurn('a');
    await pumpEventQueue();
    expect(container.read(mixBackgroundProvider), isFalse);
    foreground = false;
    end(ready: true, succeeded: true);
    await pumpEventQueue();
    expect(alerts.shown, 0);
  });

  test('an Allow in the pop-up turns pings on (refresh)', () async {
    build(granted: false);
    activity().beginTurn('a');
    await pumpEventQueue();
    push.current = PushStatus.authorized;
    await container.read(mixBackgroundProvider.notifier).refresh();
    expect(container.read(mixBackgroundProvider), isTrue);
  });

  test('a turn that lands while the app is away pings, and the task '
      'outlives the ping', () async {
    build();
    final end = activity().beginTurn('a');
    await pumpEventQueue();
    foreground = false;
    alerts.showing = Completer<void>();

    end(ready: true, succeeded: true);
    await pumpEventQueue();
    expect(alerts.shown, 1);
    expect(holder.calls, ['begin'], reason: 'still posting the ping');

    alerts.showing!.complete();
    await pumpEventQueue();
    expect(holder.calls, ['begin', 'end']);
  });

  test('a new mix made while away pings', () async {
    build();
    final made = activity().beginNewMix('rainy commute');
    foreground = false;
    made(sessionId: 'b', succeeded: true);
    await pumpEventQueue();
    expect(alerts.shown, 1);
  });

  test(
    'no ping in the foreground, for a failure, or for a turn taken back',
    () async {
      build();
      activity().beginTurn('a')(ready: true, succeeded: true);
      foreground = false;
      activity().beginTurn('b')(ready: true);
      activity().beginTurn('c')(ready: false);
      activity().beginNewMix('x')(sessionId: 'd');
      await pumpEventQueue();
      expect(alerts.shown, 0);
    },
  );

  test('a turn that ends after a sign-out does not ping', () async {
    build();
    final end = activity().beginTurn('a');
    (container.read(authProvider.notifier) as _Auth).flip(AuthStatus.noSession);
    container.read(mixActivityProvider);
    foreground = false;
    end(ready: true, succeeded: true);
    await pumpEventQueue();
    expect(alerts.shown, 0);
    expect(holder.calls.last, 'end');
  });
}
