// The listener's saved shares in Mixes (spec 2026-11-13 shared-mixes,
// Recipient in the app → Mixes): read, refresh, optimistic Remove, an auth
// change resets them, and the merge with the listener's own mixes.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/shared_mixes_provider.dart';

SharedMixRow _row(String token, DateTime savedAt, {String? name = 'Ada'}) =>
    SharedMixRow(
      token: token,
      title: 'Mix $token',
      caseColor: '#bc5734',
      sharerName: name,
      savedAt: savedAt,
      trackCount: 10,
      durationMs: 2460000,
    );

DjSession _own(String id, DateTime updatedAt) => DjSession(
  id: id,
  title: 'Own $id',
  status: 'active',
  queueVersion: 1,
  updatedAt: updatedAt,
);

class _Api implements DjApi, DjSharedMixes {
  Future<List<SharedMixRow>> Function() onList = () async => const [];
  Future<void> Function(String token) onRemove = (_) async {};
  int lists = 0;
  final removed = <String>[];

  @override
  Future<List<SharedMixRow>> listSharedMixes() {
    lists++;
    return onList();
  }

  @override
  Future<void> removeSharedMix(String token) {
    removed.add(token);
    return onRemove(token);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Auth extends AuthNotifier {
  @override
  AuthStatus build() => AuthStatus.session;

  void set(AuthStatus next) => state = next;
}

({ProviderContainer container, _Api api}) _make([
  Future<List<SharedMixRow>> Function()? list,
]) {
  final api = _Api();
  if (list != null) api.onList = list;
  final container = ProviderContainer(
    overrides: [
      djApiProvider.overrideWithValue(api),
      authProvider.overrideWith(_Auth.new),
    ],
  );
  addTearDown(container.dispose);
  container.listen(sharedMixesProvider, (_, _) {});
  return (container: container, api: api);
}

void main() {
  final now = DateTime(2026, 11, 13, 12);

  group('sharedMixesProvider', () {
    test('lists the saved shares', () async {
      final h = _make(() async => [_row('a', now)]);
      final rows = await h.container.read(sharedMixesProvider.future);
      expect(rows.map((r) => r.token), ['a']);
    });

    test(
      'a failed first read is an error, and does not retry by itself',
      () async {
        final h = _make(() async => throw ApiException(500, 'boom'));
        await expectLater(
          h.container.read(sharedMixesProvider.future),
          throwsA(isA<ApiException>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(h.api.lists, 1);
      },
    );

    test('refresh reads again; a failed refresh keeps the last list', () async {
      var rows = [_row('a', now)];
      final h = _make(() async => rows);
      await h.container.read(sharedMixesProvider.future);

      rows = [_row('b', now), _row('a', now)];
      expect(
        await h.container.read(sharedMixesProvider.notifier).refresh(),
        isTrue,
      );
      expect(h.container.read(sharedMixesProvider).value!.map((r) => r.token), [
        'b',
        'a',
      ]);

      h.api.onList = () async => throw ApiException(500, 'boom');
      expect(
        await h.container.read(sharedMixesProvider.notifier).refresh(),
        isFalse,
      );
      expect(h.container.read(sharedMixesProvider).value!.map((r) => r.token), [
        'b',
        'a',
      ]);
    });

    test('a revoked share is gone on the next read', () async {
      var rows = [_row('a', now), _row('b', now)];
      final h = _make(() async => rows);
      await h.container.read(sharedMixesProvider.future);
      rows = [_row('b', now)];
      await h.container.read(sharedMixesProvider.notifier).refresh();
      expect(h.container.read(sharedMixesProvider).value!.map((r) => r.token), [
        'b',
      ]);
    });

    test('remove drops the row at once and deletes the save', () async {
      final h = _make(() async => [_row('a', now), _row('b', now)]);
      await h.container.read(sharedMixesProvider.future);
      final done = Completer<void>();
      h.api.onRemove = (_) => done.future;

      final removing = h.container
          .read(sharedMixesProvider.notifier)
          .remove('a');
      expect(h.container.read(sharedMixesProvider).value!.map((r) => r.token), [
        'b',
      ]);
      done.complete();
      expect(await removing, isTrue);
      expect(h.api.removed, ['a']);
    });

    test('a failed remove puts the row back in its place', () async {
      final h = _make(
        () async => [
          _row('a', now),
          _row('b', now.subtract(const Duration(hours: 1))),
        ],
      );
      await h.container.read(sharedMixesProvider.future);
      h.api.onRemove = (_) async => throw ApiException(500, 'boom');

      expect(
        await h.container.read(sharedMixesProvider.notifier).remove('a'),
        isFalse,
      );
      expect(h.container.read(sharedMixesProvider).value!.map((r) => r.token), [
        'a',
        'b',
      ]);
    });

    test('a read landing mid-remove does not bring the row back', () async {
      final h = _make(() async => [_row('a', now), _row('b', now)]);
      await h.container.read(sharedMixesProvider.future);
      final done = Completer<void>();
      h.api.onRemove = (_) => done.future;

      final removing = h.container
          .read(sharedMixesProvider.notifier)
          .remove('a');
      await h.container.read(sharedMixesProvider.notifier).refresh();
      expect(h.container.read(sharedMixesProvider).value!.map((r) => r.token), [
        'b',
      ]);
      done.complete();
      await removing;
    });

    test('an auth change reads the list again for whoever is next', () async {
      var account = 'first';
      final h = _make(() async => [_row(account, now)]);
      await h.container.read(sharedMixesProvider.future);
      expect(h.api.lists, 1);

      account = 'second';
      (h.container.read(authProvider.notifier) as _Auth).set(
        AuthStatus.noSession,
      );
      final rows = await h.container.read(sharedMixesProvider.future);
      expect(h.api.lists, 2);
      expect(rows.map((r) => r.token), ['second']);
    });
  });

  group('mergeMixesEntries', () {
    test('shared rows sit among own mixes by the time they were saved', () {
      final entries = mergeMixesEntries(
        [
          _own('o1', now),
          _own('o2', now.subtract(const Duration(hours: 2))),
          _own('o3', now.subtract(const Duration(days: 3))),
        ],
        [
          _row('s2', now.subtract(const Duration(days: 1))),
          _row('s1', now.add(const Duration(minutes: 1))),
        ],
      );
      expect(
        entries.map(
          (e) => switch (e) {
            OwnMixEntry(:final session) => session.id,
            SharedMixEntry(:final mix) => mix.token,
          },
        ),
        ['s1', 'o1', 'o2', 's2', 'o3'],
      );
    });

    test('own mixes keep their order; no shared rows is the own list', () {
      final own = [_own('o1', now), _own('o2', now)];
      final entries = mergeMixesEntries(own, const []);
      expect(entries.map((e) => (e as OwnMixEntry).session.id), ['o1', 'o2']);
    });
  });
}
