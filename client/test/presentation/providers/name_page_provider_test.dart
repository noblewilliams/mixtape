// The name page gate (2026-11-02 profile name, plan Task 6): GET /me's
// askName decides; a device flag decides whether the shell waits for it.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/account_api.dart';
import 'package:mixtape/data/auth/name_page_store.dart';
import 'package:mixtape/presentation/providers/account_provider.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/capabilities_provider.dart';
import 'package:mixtape/presentation/providers/name_page_provider.dart';
import 'package:mixtape/presentation/widgets/merge_notice.dart';

class _Auth extends AuthNotifier {
  _Auth(this._initial, {bool anonymous = false}) : _anon = anonymous;
  final AuthStatus _initial;
  bool _anon;

  @override
  AuthStatus build() => _initial;

  @override
  bool get isAnonymous => _anon;

  void become(AuthStatus next, {bool anonymous = false}) {
    _anon = anonymous;
    state = next;
  }
}

class _Api implements AccountApi {
  _Api({this.fail = false});
  bool fail;
  final writes = <String?>[];
  Completer<void>? gate;

  @override
  Future<void> updateUser({String? name}) async {
    writes.add(name);
    final hold = gate;
    if (hold != null) await hold.future;
    if (fail) throw AccountApiException(500, '', null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Store implements NamePageStore {
  _Store({this.settled = false, this.failRead = false});
  bool settled;
  bool failRead;
  Completer<void>? gate;
  int clears = 0;

  @override
  Future<bool> read() async {
    final hold = gate;
    if (hold != null) await hold.future;
    if (failRead) throw StateError('keychain');
    return settled;
  }

  @override
  Future<void> markSettled() async => settled = true;

  @override
  Future<void> clear() async {
    clears++;
    settled = false;
  }
}

const _askMe = Me(id: 'u1', isAnonymous: false, askName: true);
const _named = Me(id: 'u1', isAnonymous: false, name: 'Ada');

ProviderContainer _container({
  required _Auth auth,
  _Store? store,
  _Api? api,
  Future<Me?> Function()? me,
}) {
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith(() => auth),
      namePageStoreProvider.overrideWithValue(store ?? _Store()),
      accountApiProvider.overrideWithValue(api ?? _Api()),
      if (me != null)
        meProvider.overrideWith((ref) {
          ref.watch(authProvider);
          return me();
        }),
    ],
  );
  addTearDown(container.dispose);
  // Keeps the gate alive between reads, as the root does.
  container.listen(nameGateProvider, (_, _) {});
  container.listen(namePageSettledProvider, (_, _) {});
  return container;
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('nameGateProvider', () {
    test('no session or an anonymous session is never asked', () async {
      final none = _container(
        auth: _Auth(AuthStatus.noSession),
        me: () async => _askMe,
      );
      await _settle();
      expect(none.read(nameGateProvider), NameGate.off);

      final anonymous = _container(
        auth: _Auth(AuthStatus.session, anonymous: true),
        me: () async => _askMe,
      );
      await _settle();
      expect(anonymous.read(nameGateProvider), NameGate.off);
    });

    test('while /me loads: hold unless this device has settled it', () async {
      final pending = Completer<Me?>();
      final store = _Store();
      final c = _container(
        auth: _Auth(AuthStatus.session),
        store: store,
        me: () => pending.future,
      );
      await _settle();
      expect(c.read(nameGateProvider), NameGate.hold);

      final settled = _container(
        auth: _Auth(AuthStatus.session),
        store: _Store(settled: true),
        me: () => Completer<Me?>().future,
      );
      await _settle();
      expect(settled.read(nameGateProvider), NameGate.off);
    });

    test('an unreadable flag never holds the shell', () async {
      final c = _container(
        auth: _Auth(AuthStatus.session),
        store: _Store(failRead: true),
        me: () => Completer<Me?>().future,
      );
      await _settle();
      expect(c.read(nameGateProvider), NameGate.off);
    });

    test('waits (no image, no shell) while the flag itself loads', () async {
      final store = _Store()..gate = Completer<void>();
      final c = _container(
        auth: _Auth(AuthStatus.session),
        store: store,
        me: () => Completer<Me?>().future,
      );
      await _settle();
      expect(c.read(nameGateProvider), NameGate.wait);
      store.gate!.complete();
      await _settle();
      expect(c.read(nameGateProvider), NameGate.hold);
    });

    test('askName asks; a named account or a failed read goes on', () async {
      final ask = _container(
        auth: _Auth(AuthStatus.session),
        me: () async => _askMe,
      );
      await ask.read(meProvider.future);
      expect(ask.read(nameGateProvider), NameGate.ask);

      final named = _container(
        auth: _Auth(AuthStatus.session),
        me: () async => _named,
      );
      await named.read(meProvider.future);
      expect(named.read(nameGateProvider), NameGate.off);

      final failed = _container(
        auth: _Auth(AuthStatus.session),
        me: () async => throw StateError('offline'),
      );
      await expectLater(failed.read(meProvider.future), throwsStateError);
      expect(failed.read(nameGateProvider), NameGate.off);
    });

    test('a sign-in clears the device flag, so the next account is held', () {
      final store = _Store(settled: true);
      final c = _container(auth: _Auth(AuthStatus.noSession), store: store);
      return Future(() async {
        await _settle();
        expect(c.read(namePageSettledProvider), isTrue);
        c.read(namePageSettledProvider.notifier).reset();
        expect(c.read(namePageSettledProvider), isFalse);
        await _settle();
        expect(store.clears, 1);
        expect(store.settled, isFalse);
      });
    });
  });

  group('namePageProvider', () {
    test('Continue writes the name, rereads /me and closes the page', () async {
      final api = _Api();
      final store = _Store();
      var reads = 0;
      final c = _container(
        auth: _Auth(AuthStatus.session),
        api: api,
        store: store,
        me: () async => ++reads == 1 ? _askMe : _named,
      );
      await c.read(meProvider.future);
      expect(c.read(nameGateProvider), NameGate.ask);

      await c.read(namePageProvider.notifier).save('Ada');
      expect(api.writes, ['Ada']);
      expect(reads, 2);
      expect(c.read(namePageProvider), isTrue);
      expect(c.read(nameGateProvider), NameGate.off);
      await _settle();
      expect(store.settled, isTrue);
    });

    test('a failed Continue throws and leaves the page open', () async {
      final api = _Api(fail: true);
      final c = _container(
        auth: _Auth(AuthStatus.session),
        api: api,
        me: () async => _askMe,
      );
      await c.read(meProvider.future);
      await expectLater(
        c.read(namePageProvider.notifier).save('Ada'),
        throwsA(isA<AccountApiException>()),
      );
      expect(c.read(nameGateProvider), NameGate.ask);
    });

    test(
      'Skip records the flag and moves on even when the write fails',
      () async {
        final api = _Api(fail: true);
        final store = _Store();
        final c = _container(
          auth: _Auth(AuthStatus.session),
          api: api,
          store: store,
          me: () async => _askMe,
        );
        await c.read(meProvider.future);
        c.read(namePageProvider.notifier).skip();
        expect(c.read(nameGateProvider), NameGate.off);
        await _settle();
        expect(api.writes, [null]);
        expect(store.settled, isTrue);
      },
    );

    test(
      'closing is per auth generation: a new account is asked again',
      () async {
        final auth = _Auth(AuthStatus.session);
        final c = _container(auth: auth, me: () async => _askMe);
        await c.read(meProvider.future);
        c.read(namePageProvider.notifier).skip();
        expect(c.read(nameGateProvider), NameGate.off);
        auth.become(AuthStatus.noSession);
        auth.become(AuthStatus.session);
        await c.read(meProvider.future);
        expect(c.read(namePageProvider), isFalse);
        expect(c.read(nameGateProvider), NameGate.ask);
      },
    );

    test('the merge notice survives the /me reread after Continue', () async {
      var reads = 0;
      final c = _container(
        auth: _Auth(AuthStatus.session),
        me: () async => ++reads == 1
            ? const Me(
                id: 'u1',
                isAnonymous: false,
                askName: true,
                merged: MergedMode.mixesOnly,
              )
            : _named,
      );
      await c.read(meProvider.future);
      await c.read(namePageProvider.notifier).save('Ada');
      expect(reads, 2);
      final reader = c.read(mergedModeReaderProvider);
      expect(await reader(), MergedMode.mixesOnly);
      // Answered once, as the server does.
      expect(await reader(), isNull);
    });

    test('Skip during a save moves on and lets the save finish', () async {
      final api = _Api()..gate = Completer<void>();
      var reads = 0;
      final c = _container(
        auth: _Auth(AuthStatus.session),
        api: api,
        me: () async => ++reads == 1 ? _askMe : _named,
      );
      await c.read(meProvider.future);
      final saving = c.read(namePageProvider.notifier).save('Ada');
      c.read(namePageProvider.notifier).skip();
      expect(c.read(nameGateProvider), NameGate.off);
      api.gate!.complete();
      await saving;
      expect(api.writes, ['Ada', null]);
      expect(reads, 2);
    });
  });
}
