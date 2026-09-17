import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'dj_providers_test.dart' show FakeDjApi, TestAuthNotifier;

void main() {
  final note = DjMemory(
    id: 'note',
    note: 'Preference',
    createdAt: DateTime(2026),
  );
  late FakeDjApi api;
  late TestAuthNotifier auth;
  late ProviderContainer container;
  setUp(() {
    api = FakeDjApi()..onListMemories = () async => [note];
    auth = TestAuthNotifier(AuthStatus.signedIn);
    container = ProviderContainer(
      overrides: [
        djApiProvider.overrideWithValue(api),
        authProvider.overrideWith(() => auth),
      ],
    );
  });
  tearDown(() => container.dispose());

  test(
    'lost DELETE response is success when canonical read confirms absence',
    () async {
      await container.read(memoriesProvider.future);
      api.onDeleteMemory = (_) async {
        throw StateError('lost response');
      };
      api.onListMemories = () async => [];
      expect(
        await container.read(memoriesProvider.notifier).forget('note'),
        isTrue,
      );
      expect(container.read(memoriesProvider).value, isEmpty);
    },
  );
  test(
    'failed canonical read hides stale notes and blocks another delete',
    () async {
      await container.read(memoriesProvider.future);
      var writes = 0;
      api.onDeleteMemory = (_) async {
        writes++;
      };
      api.onListMemories = () async => throw StateError('offline');
      final notifier = container.read(memoriesProvider.notifier);
      expect(await notifier.forget('note'), isFalse);
      expect(container.read(memoriesProvider).value ?? [], isEmpty);
      expect(container.read(memoriesProvider).hasError, isTrue);
      expect(await notifier.forget('note'), isFalse);
      expect(writes, 1);
      api.onListMemories = () async => [note];
      expect(await notifier.refresh(), isTrue);
    },
  );
  test('401 is retained and does not try a canonical read', () async {
    await container.read(memoriesProvider.future);
    final unauthorized = ApiException(401, 'unauthorized');
    api.onDeleteMemory = (_) async => throw unauthorized;
    expect(
      await container.read(memoriesProvider.notifier).forget('note'),
      isFalse,
    );
    expect(container.read(memoriesProvider).error, same(unauthorized));
    expect(api.listMemoriesCallCount, 1);
  });
  test(
    'auth transition rejects a pending delete and its follow-up read',
    () async {
      await container.read(memoriesProvider.future);
      final pending = Completer<void>();
      api.onDeleteMemory = (_) => pending.future;
      final mutation = container.read(memoriesProvider.notifier).forget('note');
      auth.set(AuthStatus.signedOut);
      await container.read(memoriesProvider.future);
      pending.complete();
      expect(await mutation, isFalse);
      expect(api.listMemoriesCallCount, 2);
      expect(
        await container.read(memoriesProvider.notifier).forget('note'),
        isFalse,
      );
      expect(container.read(memoriesProvider).value, [note]);
    },
  );
  test(
    'confirmed presence keeps the note and duplicate confirmation is blocked',
    () async {
      await container.read(memoriesProvider.future);
      final pending = Completer<void>();
      var writes = 0;
      api.onDeleteMemory = (_) {
        writes++;
        return pending.future;
      };
      final notifier = container.read(memoriesProvider.notifier);
      final first = notifier.forget('note');
      expect(await notifier.forget('note'), isFalse);
      pending.complete();
      expect(await first, isFalse);
      expect(writes, 1);
      expect(container.read(memoriesProvider).value, [note]);
      expect(notifier.canForget, isTrue);
    },
  );
  test(
    'a stale refresh cannot bring back a canonically deleted note',
    () async {
      await container.read(memoriesProvider.future);
      final oldRead = Completer<List<DjMemory>>();
      api.onListMemories = () => oldRead.future;
      final notifier = container.read(memoriesProvider.notifier);
      final refresh = notifier.refresh();
      api.onDeleteMemory = (_) async {};
      api.onListMemories = () async => [];
      expect(await notifier.forget('note'), isTrue);
      oldRead.complete([note]);
      expect(await refresh, isFalse);
      expect(container.read(memoriesProvider).value, isEmpty);
    },
  );
  test('disposed provider ignores a late delete response', () async {
    await container.read(memoriesProvider.future);
    final pending = Completer<void>();
    api.onDeleteMemory = (_) => pending.future;
    final mutation = container.read(memoriesProvider.notifier).forget('note');
    container.invalidate(memoriesProvider);
    pending.complete();
    expect(await mutation, isFalse);
    expect(api.listMemoriesCallCount, 1);
  });
}
