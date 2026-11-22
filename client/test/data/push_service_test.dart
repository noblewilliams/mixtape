// Mix-ready pushes (spec 2026-11-21 durable mix turns → Device registration,
// iOS client): the device token goes to `PUT /push/devices` on every launch
// with permission, and comes off with `DELETE /push/devices/:token`.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/push/push_service.dart';

import '../helpers/fake_push_channel.dart';

void main() {
  late List<http.Request> requests;
  late int status;
  late InMemoryTokenStore store;

  ApiClient client() => ApiClient(
    baseUrl: 'https://api.test',
    tokenStore: store,
    inner: MockClient((request) async {
      requests.add(request);
      return http.Response('', status);
    }),
  );

  setUp(() async {
    requests = [];
    status = 204;
    store = InMemoryTokenStore();
    await store.write('bearer-1');
  });

  PushService service(FakePushChannel channel, {String env = 'sandbox'}) =>
      PushService(channel: channel, api: client(), environment: env);

  group('registerIfAuthorized', () {
    test('authorized: registers and PUTs the device', () async {
      final channel = FakePushChannel();
      await service(channel).registerIfAuthorized();

      expect(requests, hasLength(1));
      final put = requests.single;
      expect(put.method, 'PUT');
      expect(put.url.path, '/push/devices');
      expect(put.headers['Authorization'], 'Bearer bearer-1');
      expect(jsonDecode(put.body), {
        'provider': 'apns',
        'platform': 'ios',
        'token': channel.token,
        'environment': 'sandbox',
        'appVersion': '1.2.0 (15)',
      });
    });

    test('the environment is the build\'s', () async {
      await service(
        FakePushChannel(),
        env: 'production',
      ).registerIfAuthorized();
      expect(jsonDecode(requests.single.body)['environment'], 'production');
      expect(PushService.buildEnvironment, 'sandbox'); // tests are debug
    });

    test('the signing profile\'s environment wins over the build mode', () async {
      final channel = FakePushChannel()..apsEnvironment = 'production';
      await PushService(channel: channel, api: client()).registerIfAuthorized();
      expect(jsonDecode(requests.single.body)['environment'], 'production');
    });

    test('an unknown answer falls back to the build mode', () async {
      final channel = FakePushChannel()..apsEnvironment = 'staging';
      await PushService(channel: channel, api: client()).registerIfAuthorized();
      expect(jsonDecode(requests.single.body)['environment'], 'sandbox');
    });

    for (final denied in [PushStatus.notDetermined, PushStatus.denied]) {
      test('${denied.name}: neither registers nor asks', () async {
        final channel = FakePushChannel(current: denied);
        await service(channel).registerIfAuthorized();
        expect(requests, isEmpty);
        expect(channel.calls, isNot(contains('register')));
        expect(channel.calls, isNot(contains('requestAuthorization')));
      });
    }

    test('a failed registration is swallowed, and nothing is sent', () async {
      final channel = FakePushChannel()
        ..registerError = PlatformException(code: 'register_failed');
      await service(channel).registerIfAuthorized();
      expect(requests, isEmpty);
    });

    test('a refused PUT is swallowed', () async {
      status = 500;
      await expectLater(
        service(FakePushChannel()).registerIfAuthorized(),
        completes,
      );
      expect(requests, hasLength(1));
    });

    test('a disposed service never sends what it was getting', () async {
      final channel = FakePushChannel();
      final push = service(channel);
      final pending = push.registerIfAuthorized();
      push.dispose();
      await pending;
      expect(requests, isEmpty);
    });
  });

  group('requestAndRegister', () {
    test('notDetermined: asks, then registers on a yes', () async {
      final channel = FakePushChannel(current: PushStatus.notDetermined);
      final result = await service(channel).requestAndRegister();
      expect(result, PushStatus.authorized);
      expect(
        channel.calls,
        containsAllInOrder(['requestAuthorization', 'register']),
      );
      expect(requests.single.method, 'PUT');
    });

    test('notDetermined: a no registers nothing', () async {
      final channel = FakePushChannel(
        current: PushStatus.notDetermined,
        afterRequest: PushStatus.denied,
      );
      expect(await service(channel).requestAndRegister(), PushStatus.denied);
      expect(requests, isEmpty);
    });

    test('denied: never asks again', () async {
      final channel = FakePushChannel(current: PushStatus.denied);
      expect(await service(channel).requestAndRegister(), PushStatus.denied);
      expect(channel.calls, isNot(contains('requestAuthorization')));
      expect(requests, isEmpty);
    });

    test('already authorized: registers without asking', () async {
      final channel = FakePushChannel();
      expect(
        await service(channel).requestAndRegister(),
        PushStatus.authorized,
      );
      expect(channel.calls, isNot(contains('requestAuthorization')));
      expect(requests.single.method, 'PUT');
    });
  });

  group('unregister', () {
    test('DELETEs the registered token with the bearer', () async {
      final channel = FakePushChannel();
      final push = service(channel);
      await push.registerIfAuthorized();
      await push.unregister();

      expect(requests.map((r) => r.method), ['PUT', 'DELETE']);
      final delete = requests.last;
      expect(delete.url.path, '/push/devices/${channel.token}');
      expect(delete.headers['Authorization'], 'Bearer bearer-1');
    });

    test('authorized but not registered this launch: still DELETEs', () async {
      final channel = FakePushChannel();
      await service(channel).unregister();
      expect(requests.single.method, 'DELETE');
      expect(requests.single.url.path, '/push/devices/${channel.token}');
    });

    test('never allowed: nothing to delete', () async {
      await service(FakePushChannel(current: PushStatus.denied)).unregister();
      expect(requests, isEmpty);
    });

    test('a registration in flight lands before the DELETE', () async {
      final channel = FakePushChannel();
      final push = service(channel);
      final registering = push.registerIfAuthorized();
      await push.unregister();
      await registering;
      expect(requests.last.method, 'DELETE');
    });

    test('a failed DELETE is swallowed', () async {
      status = 500;
      final push = service(FakePushChannel());
      await expectLater(push.unregister(), completes);
    });
  });

  test('taps and the launch tap come from the channel', () async {
    const tap = PushTap(sessionId: 's1', turnId: 't1', kind: 'ready');
    final channel = FakePushChannel(launchTap: tap);
    final push = service(channel);
    expect(await push.initialTap(), tap);
    expect(await push.initialTap(), isNull);
    final next = push.taps.first;
    channel.tap(const PushTap(sessionId: 's2', turnId: 't2', kind: 'failed'));
    expect((await next).sessionId, 's2');
  });

  group('PushTap.fromMap', () {
    test('reads the payload', () {
      final tap = PushTap.fromMap({
        'sessionId': 's1',
        'turnId': 't1',
        'kind': 'failed',
      });
      expect(tap, const PushTap(sessionId: 's1', turnId: 't1', kind: 'failed'));
      expect(tap!.failed, isTrue);
    });

    test('a missing kind reads as ready', () {
      final tap = PushTap.fromMap({'sessionId': 's1', 'turnId': 't1'});
      expect(tap!.kind, 'ready');
      expect(tap.failed, isFalse);
    });

    test('anything without a session is not a tap', () {
      expect(PushTap.fromMap({'turnId': 't1'}), isNull);
      expect(PushTap.fromMap(null), isNull);
      expect(PushTap.fromMap('s1'), isNull);
    });
  });

  test('PushStatus reads the native names, unknown as denied', () {
    expect(PushStatus.parse('authorized'), PushStatus.authorized);
    expect(PushStatus.parse('notDetermined'), PushStatus.notDetermined);
    expect(PushStatus.parse('denied'), PushStatus.denied);
    expect(PushStatus.parse('whatever'), PushStatus.denied);
    expect(PushStatus.parse(null), PushStatus.denied);
  });
}
