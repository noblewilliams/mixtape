import 'package:flutter_riverpod/flutter_riverpod.dart';
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
_make(AuthStatus auth, {String? stored}) {
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
    expect(await h.store.read(), 'tok');
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
      final h = _make(AuthStatus.unknown, stored: 'old');
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
      expect(await h.store.read(), 'tok');
    },
  );
}
