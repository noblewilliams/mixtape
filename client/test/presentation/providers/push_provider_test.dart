// The push registration is user-scoped (CLAUDE.md): it follows the session,
// registers on launch and on every sign-in, and comes off at sign-out before
// the bearer is dropped.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/push/push_service.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/push_provider.dart';

import '../../helpers/fake_push_channel.dart';

class _Auth extends AuthNotifier {
  _Auth(this._initial);
  final AuthStatus _initial;

  @override
  AuthStatus build() => _initial;

  void set(AuthStatus next) => state = next;
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late List<(String method, String path, String? bearer)> requests;
  late InMemoryTokenStore store;
  late FakePushChannel channel;

  ApiClient client() => ApiClient(
    baseUrl: 'https://api.test',
    tokenStore: store,
    inner: MockClient((request) async {
      requests.add((
        request.method,
        request.url.path,
        request.headers['Authorization'],
      ));
      if (request.url.path == '/api/auth/sign-out') {
        return http.Response('{}', 200);
      }
      return http.Response('', 204);
    }),
  );

  setUp(() async {
    requests = [];
    store = InMemoryTokenStore();
    await store.write('bearer-1');
    channel = FakePushChannel();
  });

  ProviderContainer container({AuthNotifier Function()? auth}) {
    final c = ProviderContainer(
      overrides: [
        tokenStoreProvider.overrideWithValue(store),
        apiClientProvider.overrideWithValue(client()),
        pushChannelProvider.overrideWithValue(channel),
        if (auth != null) authProvider.overrideWith(auth),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  List<String> pushCalls() => [
    for (final (method, path, _) in requests)
      if (path.startsWith('/push/')) '$method $path',
  ];

  test('a launch with a session and permission registers', () async {
    final c = container(auth: () => _Auth(AuthStatus.session));
    c.listen(pushServiceProvider, (_, _) {});
    await _settle();
    expect(pushCalls(), ['PUT /push/devices']);
  });

  test('no session: nothing registers', () async {
    final c = container(auth: () => _Auth(AuthStatus.noSession));
    c.listen(pushServiceProvider, (_, _) {});
    await _settle();
    expect(requests, isEmpty);
  });

  for (final status in [PushStatus.notDetermined, PushStatus.denied]) {
    test('${status.name}: a launch registers nothing', () async {
      channel.current = status;
      final c = container(auth: () => _Auth(AuthStatus.session));
      c.listen(pushServiceProvider, (_, _) {});
      await _settle();
      expect(requests, isEmpty);
    });
  }

  test('an auth change resets the service and registers again', () async {
    late _Auth auth;
    final c = container(auth: () => auth = _Auth(AuthStatus.session));
    c.listen(pushServiceProvider, (_, _) {});
    await _settle();
    final first = c.read(pushServiceProvider);

    auth.set(AuthStatus.noSession);
    await _settle();
    expect(c.read(pushServiceProvider), isNot(same(first)));
    expect(pushCalls(), ['PUT /push/devices']);

    auth.set(AuthStatus.session);
    await _settle();
    expect(pushCalls(), ['PUT /push/devices', 'PUT /push/devices']);
  });

  test(
    'sign-out DELETEs the device with the bearer, before dropping it',
    () async {
      // The real auth notifier: restore reads the stored token.
      final c = container();
      c.listen(pushServiceProvider, (_, _) {});
      c.read(authProvider);
      await _settle();
      await _settle();
      expect(c.read(authProvider), AuthStatus.session);
      expect(pushCalls(), ['PUT /push/devices']);

      await c.read(authProvider.notifier).signOut();

      expect(c.read(authProvider), AuthStatus.noSession);
      final delete = requests.firstWhere((r) => r.$1 == 'DELETE');
      expect(delete.$2, '/push/devices/${channel.token}');
      expect(delete.$3, 'Bearer bearer-1');
      expect(await store.read(), isNull);
      // Signed out, nothing registers again.
      await _settle();
      expect(pushCalls(), [
        'PUT /push/devices',
        'DELETE /push/devices/${channel.token}',
      ]);
    },
  );

  test('sign-out without permission sends nothing', () async {
    channel.current = PushStatus.denied;
    final c = container();
    c.read(authProvider);
    await _settle();
    await c.read(authProvider.notifier).signOut();
    expect(pushCalls(), isEmpty);
    expect(c.read(authProvider), AuthStatus.noSession);
  });

  group('pending tap', () {
    test('a launch tap is waiting from the start', () async {
      channel.launchTap = const PushTap(
        sessionId: 's1',
        turnId: 't1',
        kind: 'ready',
      );
      final c = container(auth: () => _Auth(AuthStatus.session));
      c.listen(pendingPushTapProvider, (_, _) {});
      await _settle();
      expect(c.read(pendingPushTapProvider)?.sessionId, 's1');
      expect(c.read(pendingPushTapProvider.notifier).take()?.sessionId, 's1');
      expect(c.read(pendingPushTapProvider), isNull);
    });

    test('the same tap handed over twice opens once', () async {
      const tap = PushTap(sessionId: 's3', turnId: 't3', kind: 'ready');
      channel.launchTap = tap;
      final c = container(auth: () => _Auth(AuthStatus.session));
      c.listen(pendingPushTapProvider, (_, _) {});
      await _settle();
      expect(c.read(pendingPushTapProvider.notifier).take(), tap);
      channel.tap(tap); // the same turn again, by onTap
      await _settle();
      expect(c.read(pendingPushTapProvider), isNull);
    });

    test('a warm tap is waiting until taken', () async {
      final c = container(auth: () => _Auth(AuthStatus.session));
      c.listen(pendingPushTapProvider, (_, _) {});
      await _settle();
      channel.tap(const PushTap(sessionId: 's2', turnId: 't2', kind: 'failed'));
      await _settle();
      expect(c.read(pendingPushTapProvider)?.failed, isTrue);
    });
  });

  test('the mix on screen is told to the channel, once per change', () async {
    final c = container(auth: () => _Auth(AuthStatus.session));
    final visible = c.read(visibleMixProvider.notifier);
    final a = Object(), b = Object();
    visible.show(a, 's1');
    visible.show(a, 's1');
    visible.hide(b); // not on screen
    visible.hide(a);
    await _settle();
    expect(channel.visible, ['s1', null]);
  });

  test('the same mix on two tabs: order of reports does not matter', () async {
    final c = container(auth: () => _Auth(AuthStatus.session));
    final visible = c.read(visibleMixProvider.notifier);
    final home = Object(), mixes = Object();
    visible.show(home, 's1');
    // The tab switch: Mixes' screen shows, then Home's hides.
    visible.show(mixes, 's1');
    visible.hide(home);
    await _settle();
    expect(c.read(visibleMixProvider), 's1');
    expect(channel.visible, ['s1']);
  });
}
