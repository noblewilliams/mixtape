import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/pending_share_save_provider.dart';

/// Only the share calls are wired; anything else fails loudly.
class _ShareApi implements DjApi, DjSharedMixes {
  final saved = <String>[];
  Object? failWith;

  @override
  Future<void> saveSharedMix(String token) async {
    saved.add(token);
    final error = failWith;
    if (error != null) throw error;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _Auth extends AuthNotifier {
  _Auth(this._initial);
  final AuthStatus _initial;

  @override
  AuthStatus build() => _initial;

  void set(AuthStatus next) => state = next;
}

({ProviderContainer container, _ShareApi api, InMemoryPendingShareStore store})
_make(AuthStatus auth, {PendingShare? stored}) {
  final api = _ShareApi();
  final store = InMemoryPendingShareStore(stored);
  final container = ProviderContainer(
    overrides: [
      djApiProvider.overrideWithValue(api),
      authProvider.overrideWith(() => _Auth(auth)),
      pendingShareStoreProvider.overrideWithValue(store),
    ],
  );
  addTearDown(container.dispose);
  // As the app's root does: kept alive for the whole launch.
  container.listen(pendingShareSaveProvider, (_, _) {});
  return (container: container, api: api, store: store);
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('with no session the token waits on the device, unsaved', () async {
    final h = _make(AuthStatus.noSession);
    await h.container.read(pendingShareSaveProvider.notifier).hold('tok');
    await _settle();
    expect(h.api.saved, isEmpty);
    expect((await h.store.read())?.token, 'tok');
    expect(h.container.read(pendingShareSaveProvider), 'tok');
  });

  test(
    'a session appearing saves the pending token once, then clears it',
    () async {
      final h = _make(AuthStatus.noSession);
      await h.container.read(pendingShareSaveProvider.notifier).hold('tok');
      await _settle();
      (h.container.read(authProvider.notifier) as _Auth).set(
        AuthStatus.session,
      );
      await _settle();
      await _settle();
      expect(h.api.saved, ['tok']);
      expect(await h.store.read(), isNull);
      expect(h.container.read(pendingShareSaveProvider), isNull);
      // A later auth change finds nothing left to save.
      (h.container.read(authProvider.notifier) as _Auth).set(
        AuthStatus.noSession,
      );
      await _settle();
      (h.container.read(authProvider.notifier) as _Auth).set(
        AuthStatus.session,
      );
      await _settle();
      expect(h.api.saved, ['tok']);
    },
  );

  test(
    'a token kept from an earlier launch saves once a session restores',
    () async {
      final h = _make(AuthStatus.unknown, stored: const PendingShare('old'));
      await _settle();
      expect(h.api.saved, isEmpty);
      (h.container.read(authProvider.notifier) as _Auth).set(
        AuthStatus.session,
      );
      await _settle();
      await _settle();
      expect(h.api.saved, ['old']);
      expect(await h.store.read(), isNull);
    },
  );

  test('with a session, hold saves at once and keeps nothing', () async {
    final h = _make(AuthStatus.session);
    await _settle();
    await h.container.read(pendingShareSaveProvider.notifier).hold('tok');
    await _settle();
    expect(h.api.saved, ['tok']);
    expect(await h.store.read(), isNull);
  });

  test('a share gone by then is dropped, not retried', () async {
    final h = _make(AuthStatus.session);
    h.api.failWith = const SharedMixGoneException(SharedMixGoneReason.revoked);
    await _settle();
    await h.container.read(pendingShareSaveProvider.notifier).hold('tok');
    await _settle();
    expect(await h.store.read(), isNull);
    expect(h.container.read(pendingShareSaveProvider), isNull);
  });

  test(
    'a save that fails otherwise stays pending for the next launch',
    () async {
      final h = _make(AuthStatus.session);
      h.api.failWith = Exception('offline');
      await _settle();
      await h.container.read(pendingShareSaveProvider.notifier).hold('tok');
      await _settle();
      expect(h.api.saved, ['tok']);
      expect((await h.store.read())?.token, 'tok');
    },
  );

  test('a token opened with no session is kept as such', () async {
    final h = _make(AuthStatus.noSession);
    await h.container.read(pendingShareSaveProvider.notifier).hold('tok');
    expect((await h.store.read())?.heldWithSession, isFalse);
  });

  test('a token waiting for a retry under a session says so', () async {
    final h = _make(AuthStatus.session);
    h.api.failWith = Exception('offline');
    await _settle();
    await h.container.read(pendingShareSaveProvider.notifier).hold('tok');
    expect((await h.store.read())?.heldWithSession, isTrue);
  });

  test('signing out drops a token still waiting under that session', () async {
    final h = _make(AuthStatus.session);
    h.api.failWith = Exception('offline');
    await _settle();
    await h.container.read(pendingShareSaveProvider.notifier).hold('tok');
    expect((await h.store.read())?.token, 'tok');

    h.api.failWith = null;
    (h.container.read(authProvider.notifier) as _Auth).set(
      AuthStatus.noSession,
    );
    await _settle();
    await _settle();
    expect(await h.store.read(), isNull);
    expect(h.container.read(pendingShareSaveProvider), isNull);

    // The next account does not inherit it.
    (h.container.read(authProvider.notifier) as _Auth).set(AuthStatus.session);
    await _settle();
    await _settle();
    expect(h.api.saved, ['tok']);
  });

  test(
    'a link opened after signing out still waits for the next session',
    () async {
      final h = _make(AuthStatus.session);
      await _settle();
      (h.container.read(authProvider.notifier) as _Auth).set(
        AuthStatus.noSession,
      );
      await _settle();
      await h.container.read(pendingShareSaveProvider.notifier).hold('tok');
      await _settle();
      expect((await h.store.read())?.token, 'tok');

      (h.container.read(authProvider.notifier) as _Auth).set(
        AuthStatus.session,
      );
      await _settle();
      await _settle();
      expect(h.api.saved, ['tok']);
    },
  );

  test('a launch with no session drops a token kept under an earlier one '
      '(a reinstall, the keychain kept)', () async {
    final h = _make(
      AuthStatus.unknown,
      stored: const PendingShare('old', heldWithSession: true),
    );
    await _settle();
    (h.container.read(authProvider.notifier) as _Auth).set(
      AuthStatus.noSession,
    );
    await _settle();
    await _settle();
    expect(await h.store.read(), isNull);
    expect(h.container.read(pendingShareSaveProvider), isNull);

    (h.container.read(authProvider.notifier) as _Auth).set(AuthStatus.session);
    await _settle();
    await _settle();
    expect(h.api.saved, isEmpty);
  });

  test('a launch with no session keeps a token opened before any session, '
      'until first run makes one', () async {
    final h = _make(AuthStatus.noSession, stored: const PendingShare('fresh'));
    await _settle();
    await _settle();
    expect((await h.store.read())?.token, 'fresh');
    expect(h.container.read(pendingShareSaveProvider), 'fresh');

    (h.container.read(authProvider.notifier) as _Auth).set(AuthStatus.session);
    await _settle();
    await _settle();
    expect(h.api.saved, ['fresh']);
  });

  group('SecurePendingShareStore', () {
    setUp(() => FlutterSecureStorage.setMockInitialValues({}));

    test('round-trips the token and whether a session held it', () async {
      final store = SecurePendingShareStore();
      expect(await store.read(), isNull);
      await store.write(const PendingShare('tok', heldWithSession: true));
      final read = await store.read();
      expect(read?.token, 'tok');
      expect(read?.heldWithSession, isTrue);
      await store.clear();
      expect(await store.read(), isNull);
    });

    test('an unreadable value is no token', () async {
      FlutterSecureStorage.setMockInitialValues({
        'mixtape_pending_share_save': '{not json',
      });
      expect(await SecurePendingShareStore().read(), isNull);
    });
  });
}
