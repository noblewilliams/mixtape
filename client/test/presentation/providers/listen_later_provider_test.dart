import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/account_api.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/presentation/providers/account_provider.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/capabilities_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/listen_later_provider.dart';
import 'package:mixtape/presentation/widgets/merge_notice.dart';

/// Only the Listen later surface is wired; anything else fails loudly.
class _FakeDjApi implements DjApi {
  Future<List<ListenLaterEntry>> Function()? onList;
  Future<void> Function(String albumId)? onUnsave;
  Future<ListenLaterEntry> Function(String albumId, String? sessionId)? onSave;
  Future<ListenLaterEntry> Function(String albumId)? onMarkListened;
  int listCalls = 0;
  String? lastSaveSession = 'unset';

  @override
  Future<List<ListenLaterEntry>> listListenLater() {
    listCalls++;
    return onList!();
  }

  @override
  Future<void> unsaveForLater(String albumId) => onUnsave!(albumId);

  @override
  Future<ListenLaterEntry> saveForLater(String albumId, {String? sessionId}) {
    lastSaveSession = sessionId;
    return onSave!(albumId, sessionId);
  }

  @override
  Future<ListenLaterEntry> markListened(String albumId) => onMarkListened!(albumId);

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _FakeAccountApi implements AccountApi {
  _FakeAccountApi(this.next);
  Me Function() next;
  int calls = 0;

  @override
  Future<Me> me() async {
    calls++;
    return next();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _TestAuth extends AuthNotifier {
  _TestAuth(this._initial, {bool anonymous = false}) : _anon = anonymous;
  final AuthStatus _initial;
  bool _anon;

  @override
  AuthStatus build() => _initial;

  @override
  bool get isAnonymous => _anon;

  void set(AuthStatus status, {bool? anonymous}) {
    if (anonymous != null) _anon = anonymous;
    if (state == status) {
      ref.notifyListeners();
    } else {
      state = status;
    }
  }
}

ListenLaterEntry _entry(String id, {required DateTime savedAt, DateTime? listenedAt}) => ListenLaterEntry(
      id: id,
      title: 'Album $id',
      artist: 'Artist',
      type: 'album',
      savedAt: savedAt,
      listenedAt: listenedAt,
    );

Me _me({bool albumPicks = true, bool anonymous = false, MergedMode? merged, String? name}) =>
    Me(id: 'u1', isAnonymous: anonymous, merged: merged, albumPicks: albumPicks, name: name);

({ProviderContainer container, _TestAuth auth, _FakeAccountApi account}) _make(
  _FakeDjApi api, {
  AuthStatus status = AuthStatus.session,
  bool anonymous = false,
  Me Function()? me,
}) {
  final auth = _TestAuth(status, anonymous: anonymous);
  final account = _FakeAccountApi(me ?? _me);
  final container = ProviderContainer(
    overrides: [
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      djApiProvider.overrideWithValue(api),
      authProvider.overrideWith(() => auth),
      accountApiProvider.overrideWithValue(account),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, auth: auth, account: account);
}

/// Waits for /me and the shelf to settle.
Future<List<ListenLaterEntry>> _settled(ProviderContainer container) async {
  container.listen(listenLaterProvider, (_, _) {});
  await container.read(meProvider.future);
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
  return container.read(listenLaterProvider.future);
}

void main() {
  group('albumPicksEnabledProvider', () {
    test('true for a signed-in account whose /me says albumPicks', () async {
      final h = _make(_FakeDjApi());
      h.container.listen(albumPicksEnabledProvider, (_, _) {});
      await h.container.read(meProvider.future);
      expect(h.container.read(albumPicksEnabledProvider), isTrue);
    });

    test('false when /me says albumPicks is off', () async {
      final h = _make(_FakeDjApi(), me: () => _me(albumPicks: false));
      h.container.listen(albumPicksEnabledProvider, (_, _) {});
      await h.container.read(meProvider.future);
      expect(h.container.read(albumPicksEnabledProvider), isFalse);
    });

    test('false for an anonymous listener even when the server flag is on', () async {
      final h = _make(_FakeDjApi(), anonymous: true);
      h.container.listen(albumPicksEnabledProvider, (_, _) {});
      await h.container.read(meProvider.future);
      expect(h.container.read(albumPicksEnabledProvider), isFalse);
    });

    test('false, and no /me read, without a session', () async {
      final h = _make(_FakeDjApi(), status: AuthStatus.noSession);
      expect(await h.container.read(meProvider.future), isNull);
      expect(h.container.read(albumPicksEnabledProvider), isFalse);
      expect(h.account.calls, 0);
    });

    test('false while /me is still loading or failed', () async {
      final h = _make(_FakeDjApi(), me: () => throw ApiException(500, 'boom'));
      h.container.listen(albumPicksEnabledProvider, (_, _) {});
      expect(h.container.read(albumPicksEnabledProvider), isFalse);
      await expectLater(h.container.read(meProvider.future), throwsA(isA<ApiException>()));
      expect(h.container.read(albumPicksEnabledProvider), isFalse);
      expect(h.account.calls, 1); // no retry
    });
  });

  group('mergedModeReaderProvider over meProvider', () {
    test('reads merged from the one /me fetch, and only once per auth generation', () async {
      final h = _make(_FakeDjApi(), me: () => _me(merged: MergedMode.mixesOnly));
      h.container.listen(albumPicksEnabledProvider, (_, _) {});
      await h.container.read(meProvider.future);

      final read = h.container.read(mergedModeReaderProvider);
      expect(await read(), MergedMode.mixesOnly);
      expect(await read(), isNull);
      expect(h.account.calls, 1);
    });
  });

  group('accountNameProvider over meProvider', () {
    test('reads the name from the one /me fetch, leaving merged for the notice', () async {
      final h = _make(_FakeDjApi(), me: () => _me(name: 'Noble', merged: MergedMode.all));

      expect(await h.container.read(accountNameProvider.future), 'Noble');
      expect(await h.container.read(mergedModeReaderProvider)(), MergedMode.all);
      expect(h.account.calls, 1);
    });

    test('null without a session or when /me fails, never an error', () async {
      final signedOut = _make(_FakeDjApi(), status: AuthStatus.noSession);
      expect(await signedOut.container.read(accountNameProvider.future), isNull);
      final failing = _make(_FakeDjApi(), me: () => throw ApiException(500, 'boom'));
      expect(await failing.container.read(accountNameProvider.future), isNull);
    });
  });

  group('listenLaterProvider', () {
    test('a superseded initial read cannot bring back what a later read dropped', () async {
      final first = Completer<List<ListenLaterEntry>>();
      var calls = 0;
      final api = _FakeDjApi()
        ..onList = () {
          calls++;
          return calls == 1 ? first.future : Future.value([_entry('b', savedAt: DateTime(2026, 10, 2))]);
        };
      final h = _make(api);
      h.container.listen(listenLaterProvider, (_, _) {});
      await h.container.read(meProvider.future);
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(calls, 1);

      expect(await h.container.read(listenLaterProvider.notifier).refresh(), isTrue);
      first.complete([
        _entry('a', savedAt: DateTime(2026, 10, 3)),
        _entry('b', savedAt: DateTime(2026, 10, 2)),
      ]);
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(h.container.read(listenLaterProvider).value!.map((e) => e.id), ['b']);
    });

    test('loads the shelf for an account with albums on', () async {
      final api = _FakeDjApi()..onList = () async => [_entry('a', savedAt: DateTime(2026, 10, 2))];
      final h = _make(api);

      final entries = await _settled(h.container);

      expect(entries.map((e) => e.id), ['a']);
      expect(api.listCalls, 1);
    });

    test('is empty without a call for an anonymous listener', () async {
      final api = _FakeDjApi()..onList = () async => [_entry('a', savedAt: DateTime(2026))];
      final h = _make(api, anonymous: true);

      expect(await _settled(h.container), isEmpty);
      expect(api.listCalls, 0);
    });

    test('is empty without a call when albums are off', () async {
      final api = _FakeDjApi()..onList = () async => [_entry('a', savedAt: DateTime(2026))];
      final h = _make(api, me: () => _me(albumPicks: false));

      expect(await _settled(h.container), isEmpty);
      expect(api.listCalls, 0);
    });

    test('resets on an auth transition', () async {
      final api = _FakeDjApi()..onList = () async => [_entry('a', savedAt: DateTime(2026))];
      final h = _make(api);
      expect(await _settled(h.container), hasLength(1));

      h.auth.set(AuthStatus.noSession);
      expect(await _settled(h.container), isEmpty);
      expect(api.listCalls, 1);

      h.auth.set(AuthStatus.session);
      expect(await _settled(h.container), hasLength(1));
      expect(api.listCalls, 2);
    });

    test('remove is optimistic and succeeds', () async {
      final api = _FakeDjApi()
        ..onList = () async => [
              _entry('a', savedAt: DateTime(2026, 10, 3)),
              _entry('b', savedAt: DateTime(2026, 10, 2)),
            ];
      final gate = Completer<void>();
      api.onUnsave = (_) => gate.future;
      final h = _make(api);
      await _settled(h.container);

      final pending = h.container.read(listenLaterProvider.notifier).remove('a');
      expect(h.container.read(listenLaterProvider).value!.map((e) => e.id), ['b']);
      gate.complete();
      expect(await pending, isTrue);
      expect(h.container.read(listenLaterProvider).value!.map((e) => e.id), ['b']);
    });

    test('remove reverts and returns false on failure', () async {
      final api = _FakeDjApi()
        ..onList = () async => [
              _entry('a', savedAt: DateTime(2026, 10, 3)),
              _entry('b', savedAt: DateTime(2026, 10, 2)),
            ];
      api.onUnsave = (_) async => throw ApiException(500, 'boom');
      final h = _make(api);
      await _settled(h.container);

      expect(await h.container.read(listenLaterProvider.notifier).remove('a'), isFalse);
      expect(h.container.read(listenLaterProvider).value!.map((e) => e.id), ['a', 'b']);
    });

    test('restore re-saves with no session and refetches', () async {
      var listed = <ListenLaterEntry>[_entry('b', savedAt: DateTime(2026, 10, 2))];
      final api = _FakeDjApi()..onList = () async => listed;
      api.onSave = (albumId, sessionId) async {
        listed = [_entry('a', savedAt: DateTime(2026, 10, 5)), ...listed];
        return listed.first;
      };
      final h = _make(api);
      await _settled(h.container);

      expect(await h.container.read(listenLaterProvider.notifier).restore('a'), isTrue);
      expect(api.lastSaveSession, isNull);
      expect(api.listCalls, 2);
      expect(h.container.read(listenLaterProvider).value!.map((e) => e.id), ['a', 'b']);
    });

    test('markListened adopts the entry and re-sorts listened after unlistened', () async {
      final api = _FakeDjApi()
        ..onList = () async => [
              _entry('a', savedAt: DateTime(2026, 10, 5)),
              _entry('b', savedAt: DateTime(2026, 10, 4)),
              _entry('old', savedAt: DateTime(2026, 9, 1), listenedAt: DateTime(2026, 10, 1)),
            ];
      api.onMarkListened = (albumId) async =>
          _entry(albumId, savedAt: DateTime(2026, 10, 5), listenedAt: DateTime(2026, 10, 21));
      final h = _make(api);
      await _settled(h.container);

      expect(await h.container.read(listenLaterProvider.notifier).markListened('a'), isTrue);
      final entries = h.container.read(listenLaterProvider).value!;
      expect(entries.map((e) => e.id), ['b', 'a', 'old']);
      expect(entries[1].listened, isTrue);
    });

    test('noteSaved and noteUnsaved keep the shelf in step without a refetch', () async {
      final api = _FakeDjApi()..onList = () async => [_entry('b', savedAt: DateTime(2026, 10, 2))];
      final h = _make(api);
      await _settled(h.container);
      final notifier = h.container.read(listenLaterProvider.notifier);

      notifier.noteSaved(_entry('a', savedAt: DateTime(2026, 10, 9)));
      expect(h.container.read(listenLaterProvider).value!.map((e) => e.id), ['a', 'b']);
      notifier.noteSaved(_entry('a', savedAt: DateTime(2026, 10, 9)));
      expect(h.container.read(listenLaterProvider).value!.map((e) => e.id), ['a', 'b']);
      notifier.noteUnsaved('b');
      expect(h.container.read(listenLaterProvider).value!.map((e) => e.id), ['a']);
      expect(api.listCalls, 1);
    });
  });
}
