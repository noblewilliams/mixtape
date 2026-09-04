import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/listening/listening_api.dart';
import 'package:mixtape/data/onboarding/service_preference_store.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/device_providers.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';

import '../../helpers/fake_bridge.dart' show apiWith;

class TestAuthNotifier extends AuthNotifier {
  TestAuthNotifier(this._initial);
  final AuthStatus _initial;

  @override
  AuthStatus build() => _initial;

  void set(AuthStatus status) => state = status;
}

const _blank =
    '{"userId":"u1","sources":[],"hasLibrary":false,"chosenService":null,"markedRequestedAt":null,'
    '"interviewCompletedAt":null,"importCompletedAt":null}';
const _spotify =
    '{"userId":"u1","sources":[],"hasLibrary":false,"chosenService":"spotify","markedRequestedAt":null,'
    '"interviewCompletedAt":null,"importCompletedAt":null}';
const _requested =
    '{"userId":"u1","sources":[],"hasLibrary":false,"chosenService":"spotify",'
    '"markedRequestedAt":"2026-09-01T10:00:00.000Z",'
    '"interviewCompletedAt":null,"importCompletedAt":null}';

/// Answers `GET /me/onboarding` from a queue of bodies (the last one
/// repeats) and records every request; funnel posts answer 201 unless
/// [failFunnel] is set.
class _Server {
  _Server(this.onboardingBodies, {this.failFunnel = false});

  final List<String> onboardingBodies;
  final bool failFunnel;
  final List<http.Request> requests = [];
  int _served = 0;

  MockClient get client => MockClient((request) async {
        requests.add(request);
        if (request.url.path == '/me/onboarding') {
          final index = _served < onboardingBodies.length ? _served : onboardingBodies.length - 1;
          _served++;
          return http.Response(onboardingBodies[index], 200);
        }
        if (request.url.path == '/me/funnel-events') {
          return failFunnel ? http.Response('boom', 500) : http.Response('{"ok":true}', 201);
        }
        return http.Response('not found', 404);
      });

  List<http.Request> get funnelPosts =>
      requests.where((r) => r.url.path == '/me/funnel-events').toList();

  int get onboardingGets => requests.where((r) => r.url.path == '/me/onboarding').length;
}

Future<ProviderContainer> _container(
  _Server server, {
  AuthNotifier? auth,
  ServicePreferenceStore? prefs,
}) async {
  final api = ListeningApi(await apiWith(server.client));
  final container = ProviderContainer(
    overrides: [
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      listeningApiProvider.overrideWithValue(api),
      authProvider.overrideWith(() => auth ?? TestAuthNotifier(AuthStatus.signedIn)),
      servicePreferenceStoreProvider
          .overrideWithValue(prefs ?? InMemoryServicePreferenceStore()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('build reads GET /me/onboarding for the signed-in listener', () async {
    final server = _Server([_blank]);
    final container = await _container(server);

    final state = await container.read(onboardingProvider.future);

    expect(state.chosenService, isNull);
    expect(server.onboardingGets, 1);
    expect(server.requests.single.method, 'GET');
  });

  test('markChoseSpotify posts chose_spotify with the ios surface, then refetches', () async {
    final server = _Server([_blank, _spotify]);
    final container = await _container(server);
    await container.read(onboardingProvider.future);

    await container.read(onboardingProvider.notifier).markChoseSpotify();

    final post = server.funnelPosts.single;
    expect(post.method, 'POST');
    expect(jsonDecode(post.body), {'type': 'chose_spotify', 'surface': 'ios'});
    expect(server.onboardingGets, 2);
    expect(container.read(onboardingProvider).value?.chosenService, 'spotify');
  });

  test('markRequested posts marked_requested, then the state carries markedRequestedAt',
      () async {
    final server = _Server([_spotify, _requested]);
    final container = await _container(server);
    await container.read(onboardingProvider.future);

    await container.read(onboardingProvider.notifier).markRequested();

    expect(jsonDecode(server.funnelPosts.single.body), {
      'type': 'marked_requested',
      'surface': 'ios',
    });
    expect(
      container.read(onboardingProvider).value?.markedRequestedAt,
      DateTime.utc(2026, 9, 1, 10),
    );
  });

  test('a failed funnel post is swallowed (fire-and-forget) and still refetches', () async {
    final server = _Server([_blank, _blank], failFunnel: true);
    final container = await _container(server);
    await container.read(onboardingProvider.future);

    await container.read(onboardingProvider.notifier).markRequested();

    expect(server.funnelPosts, hasLength(1));
    expect(server.onboardingGets, 2);
    expect(container.read(onboardingProvider).hasError, isFalse);
  });

  test('refresh keeps the previous value on failure and reports it', () async {
    final server = _Server([_spotify]);
    final container = await _container(server);
    await container.read(onboardingProvider.future);
    server.onboardingBodies
      ..clear()
      ..add('not json');

    final ok = await container.read(onboardingProvider.notifier).refresh();

    expect(ok, isFalse);
    expect(container.read(onboardingProvider).value?.chosenService, 'spotify');
  });

  test('markChoseApple posts nothing, remembers the choice for this listener on the device, '
      'and the state says apple', () async {
    final server = _Server([_blank]);
    final prefs = InMemoryServicePreferenceStore();
    final container = await _container(server, prefs: prefs);
    await container.read(onboardingProvider.future);

    await container.read(onboardingProvider.notifier).markChoseApple();

    expect(server.funnelPosts, isEmpty);
    expect(await prefs.read('u1'), 'apple');
    expect(container.read(onboardingProvider).value?.chosenService, 'apple');
  });

  test('a remembered choice fills in a blank server answer, on this launch and the next',
      () async {
    final prefs = InMemoryServicePreferenceStore();
    await prefs.write('u1', 'apple');
    final container = await _container(_Server([_blank]), prefs: prefs);
    expect((await container.read(onboardingProvider.future)).chosenService, 'apple');

    final next = await _container(_Server([_blank]), prefs: prefs);
    expect((await next.read(onboardingProvider.future)).chosenService, 'apple');
  });

  test("a remembered choice never overrides the server's, and another account's is ignored",
      () async {
    final prefs = InMemoryServicePreferenceStore();
    await prefs.write('u1', 'apple');
    final container = await _container(_Server([_spotify]), prefs: prefs);
    expect((await container.read(onboardingProvider.future)).chosenService, 'spotify');

    await prefs.write('someone-else', 'apple');
    final other = await _container(_Server([_blank]), prefs: prefs);
    expect((await other.read(onboardingProvider.future)).chosenService, isNull);
  });

  test('a dropped chose_spotify post still yields the Spotify state through the local flag, '
      'now and on the next launch', () async {
    final prefs = InMemoryServicePreferenceStore();
    final server = _Server([_blank, _blank], failFunnel: true);
    final container = await _container(server, prefs: prefs);
    await container.read(onboardingProvider.future);

    await container.read(onboardingProvider.notifier).markChoseSpotify();

    expect(server.funnelPosts, hasLength(1));
    expect(await prefs.read('u1'), 'spotify');
    expect(container.read(onboardingProvider).value?.chosenService, 'spotify');

    final next = await _container(_Server([_blank]), prefs: prefs);
    expect((await next.read(onboardingProvider.future)).chosenService, 'spotify');
  });

  test('an auth transition rebuilds the state for the next listener', () async {
    final server = _Server([_spotify, _blank]);
    final testAuth = TestAuthNotifier(AuthStatus.signedIn);
    final container = await _container(server, auth: testAuth);
    await container.read(onboardingProvider.future);
    expect(container.read(onboardingProvider).value?.chosenService, 'spotify');

    testAuth.set(AuthStatus.signedOut);
    await container.read(onboardingProvider.future);

    expect(server.onboardingGets, 2);
    expect(container.read(onboardingProvider).value?.chosenService, isNull);
  });
}
