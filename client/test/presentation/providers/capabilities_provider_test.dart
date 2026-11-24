import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/account_api.dart';
import 'package:mixtape/data/auth/album_picks_memory.dart';
import 'package:mixtape/presentation/providers/account_provider.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/capabilities_provider.dart';

class _AccountApi implements AccountApi {
  _AccountApi(this.next);
  Future<Me> Function() next;
  int calls = 0;

  @override
  Future<Me> me() {
    calls++;
    return next();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _Auth extends AuthNotifier {
  @override
  AuthStatus build() => AuthStatus.session;
  @override
  bool get isAnonymous => false;
  void signOut_() => state = AuthStatus.noSession;
}

const _on = Me(id: 'u1', isAnonymous: false, albumPicks: true);

void main() {
  late _AccountApi api;
  late _Auth auth;
  late ProviderContainer container;
  final seen = <bool>[];

  setUp(() async {
    seen.clear();
    api = _AccountApi(() async => _on);
    auth = _Auth();
    container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(() => auth),
        accountApiProvider.overrideWithValue(api),
        albumPicksMemoryProvider.overrideWithValue(InMemoryAlbumPicksMemory()),
      ],
    );
    addTearDown(container.dispose);
    container.listen(
      albumPicksEnabledProvider,
      (_, next) => seen.add(next),
      fireImmediately: true,
    );
    await container.read(meProvider.future);
    expect(container.read(albumPicksEnabledProvider), isTrue);
    seen.clear();
  });

  test(
    'album picks stay on while /me is refreshed after a name save',
    () async {
      final reread = Completer<Me>();
      api.next = () => reread.future;
      container.invalidate(meProvider);
      container.read(meProvider);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(albumPicksEnabledProvider), isTrue);

      reread.complete(_on);
      await container.read(meProvider.future);
      expect(container.read(albumPicksEnabledProvider), isTrue);
      expect(seen, everyElement(isTrue));
    },
  );

  test('a failed refresh keeps the last answer', () async {
    api.next = () async => throw ApiException(503, 'down');
    container.invalidate(meProvider);
    await expectLater(
      container.read(meProvider.future),
      throwsA(isA<ApiException>()),
    );
    expect(container.read(albumPicksEnabledProvider), isTrue);
    expect(seen, everyElement(isTrue));
  });

  test('signing out still turns them off', () async {
    auth.signOut_();
    await container.read(meProvider.future);
    expect(container.read(albumPicksEnabledProvider), isFalse);
  });

  group('a cold start before /me answers (launch glitch, 2026-11-24)', () {
    late Completer<Me> first;
    late InMemoryAlbumPicksMemory memory;
    late ProviderContainer cold;

    ProviderContainer start(bool? remembered) {
      first = Completer<Me>();
      memory = InMemoryAlbumPicksMemory(remembered);
      final c = ProviderContainer(
        overrides: [
          authProvider.overrideWith(_Auth.new),
          accountApiProvider.overrideWithValue(_AccountApi(() => first.future)),
          albumPicksMemoryProvider.overrideWithValue(memory),
        ],
      );
      addTearDown(c.dispose);
      // The app root listens from launch (main.dart), as here.
      c.listen(rememberedAlbumPicksProvider, (_, _) {});
      c.listen(albumPicksEnabledProvider, (_, _) {});
      return c;
    }

    test('uses the answer this device last had while /me loads', () async {
      cold = start(true);
      await Future<void>.delayed(Duration.zero);
      expect(cold.read(meProvider).isLoading, isTrue);
      expect(cold.read(albumPicksEnabledProvider), isTrue);
    });

    test('nothing remembered stays Mix-only while /me loads', () async {
      cold = start(null);
      await Future<void>.delayed(Duration.zero);
      expect(cold.read(albumPicksEnabledProvider), isFalse);
    });

    test('/me wins over the memory, and is remembered', () async {
      cold = start(true);
      await Future<void>.delayed(Duration.zero);
      first.complete(const Me(id: 'u1', isAnonymous: false));
      await cold.read(meProvider.future);
      await Future<void>.delayed(Duration.zero);
      expect(cold.read(albumPicksEnabledProvider), isFalse);
      expect(memory.value, isFalse);
    });

    test('a fresh /me answer is remembered for the next launch', () async {
      cold = start(null);
      first.complete(_on);
      await cold.read(meProvider.future);
      await Future<void>.delayed(Duration.zero);
      expect(memory.value, isTrue);
    });

    test('signing out forgets it', () async {
      cold = start(true);
      first.complete(_on);
      await cold.read(meProvider.future);
      await Future<void>.delayed(Duration.zero);
      (cold.read(authProvider.notifier) as _Auth).signOut_();
      await Future<void>.delayed(Duration.zero);
      expect(memory.value, isNull);
      expect(cold.read(rememberedAlbumPicksProvider), isNull);
    });
  });
}
