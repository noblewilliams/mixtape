import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';

import 'dj_providers_test.dart' show FakeDjApi, TestAuthNotifier;

DjSession session({
  String title = 'Before',
  String status = 'active',
  int version = 4,
}) => DjSession(
  id: 'mix',
  title: title,
  status: status,
  queueVersion: version,
  updatedAt: DateTime(2026, 9, 8),
  notPersonal: true,
);

void main() {
  late FakeDjApi api;
  late TestAuthNotifier auth;
  late ProviderContainer container;
  setUp(() {
    api = FakeDjApi()..onListSessions = () async => [session()];
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
    'archive adopts every canonical field even if follow-up read fails',
    () async {
      await container.read(sessionsProvider.future);
      final canonical = session(
        status: 'archived',
        title: 'Canonical',
        version: 9,
      );
      api.onSetStatus = (_, _) async => canonical;
      api.onListSessions = () async => throw StateError('offline');
      expect(
        await container.read(sessionsProvider.notifier).archive('mix'),
        isTrue,
      );
      expect(container.read(sessionsProvider).value!.single, same(canonical));
      expect(api.lastOps, isNull);
    },
  );

  test(
    'overlapping writes for one mix are rejected before a second request',
    () async {
      await container.read(sessionsProvider.future);
      final patch = Completer<DjSession>();
      api.onSetStatus = (_, _) => patch.future;
      final notifier = container.read(sessionsProvider.notifier);
      final archive = notifier.archive('mix');
      expect(await notifier.rename('mix', 'Conflict'), isFalse);
      expect(api.lastRenameCall, isNull);
      patch.complete(session(status: 'archived'));
      expect(await archive, isTrue);
    },
  );

  test(
    'a list read started before rename cannot overwrite its result',
    () async {
      await container.read(sessionsProvider.future);
      final oldList = Completer<List<DjSession>>();
      api.onListSessions = () => oldList.future;
      final notifier = container.read(sessionsProvider.notifier);
      final refresh = notifier.refresh();
      final canonical = session(title: 'After');
      api.onRenameSession = (_, _) async => canonical;
      api.onListSessions = () async => [canonical];
      expect(await notifier.rename('mix', 'After'), isTrue);
      oldList.complete([session()]);
      await refresh;
      expect(container.read(sessionsProvider).value!.single.title, 'After');
    },
  );

  test(
    'late mutation after auth transition cannot change new account list',
    () async {
      await container.read(sessionsProvider.future);
      final patch = Completer<DjSession>();
      api.onSetStatus = (_, _) => patch.future;
      final archive = container.read(sessionsProvider.notifier).archive('mix');
      api.onListSessions = () async => [session(title: 'New account')];
      auth.set(AuthStatus.signedOut);
      await container.read(sessionsProvider.future);
      patch.complete(session(status: 'archived'));
      expect(await archive, isFalse);
      expect(
        container.read(sessionsProvider).value!.single.title,
        'New account',
      );
    },
  );

  test(
    'late refresh after auth transition cannot restore old account list',
    () async {
      await container.read(sessionsProvider.future);
      final oldList = Completer<List<DjSession>>();
      api.onListSessions = () => oldList.future;
      final refresh = container.read(sessionsProvider.notifier).refresh();
      api.onListSessions = () async => [session(title: 'New account')];
      auth.set(AuthStatus.signedOut);
      await container.read(sessionsProvider.future);
      oldList.complete([session()]);
      expect(await refresh, isFalse);
      expect(
        container.read(sessionsProvider).value!.single.title,
        'New account',
      );
    },
  );
  test(
    'restore keeps the PATCH row when the following list is stale',
    () async {
      api.onListSessions = () async => [session(status: 'archived')];
      await container.read(sessionsProvider.future);
      final canonical = session(title: 'Restored', version: 12);
      api.onSetStatus = (_, _) async => canonical;
      expect(
        await container.read(sessionsProvider.notifier).unarchive('mix'),
        isTrue,
      );
      expect(container.read(sessionsProvider).value!.single, same(canonical));
      expect(api.lastStatusCall, (id: 'mix', status: 'active'));
      expect(api.lastOps, isNull);
    },
  );

  test('late mutation after provider disposal is ignored', () async {
    await container.read(sessionsProvider.future);
    final patch = Completer<DjSession>();
    api.onSetStatus = (_, _) => patch.future;
    final archive = container.read(sessionsProvider.notifier).archive('mix');
    container.invalidate(sessionsProvider);
    patch.complete(session(status: 'archived'));
    expect(await archive, isFalse);
    expect(api.listSessionsCallCount, 1);
  });
  test(
    'PATCH completion releases the write before its secondary read',
    () async {
      await container.read(sessionsProvider.future);
      final oldRead = Completer<List<DjSession>>();
      api.onListSessions = () => oldRead.future;
      api.onSetStatus = (_, _) async => session(status: 'archived');
      final notifier = container.read(sessionsProvider.notifier);
      bool? archived;
      final archive = notifier.archive('mix').then((value) => archived = value);
      await Future<void>.delayed(Duration.zero);
      final returnedBeforeRead = archived;
      api.onListSessions = () async => [
        session(title: 'Renamed', status: 'archived'),
      ];
      api.onRenameSession = (_, _) async =>
          session(title: 'Renamed', status: 'archived');
      final renamed = await notifier.rename('mix', 'Renamed');
      oldRead.complete([session()]);
      await archive;
      await Future<void>.delayed(Duration.zero);
      expect(returnedBeforeRead, isTrue);
      expect(renamed, isTrue);
      expect(container.read(sessionsProvider).value!.single.title, 'Renamed');
      expect(container.read(sessionsProvider).value!.single.status, 'archived');
    },
  );
  test(
    'initial list read cannot overwrite metadata saved during build',
    () async {
      final initial = Completer<List<DjSession>>();
      api.onListSessions = () => initial.future;
      container.listen(sessionsProvider, (_, _) {});
      final notifier = container.read(sessionsProvider.notifier);
      final canonical = session(title: 'Saved while loading');
      api.onRenameSession = (_, _) async => canonical;
      api.onListSessions = () async => [canonical];
      expect(await notifier.rename('mix', canonical.title), isTrue);
      initial.complete([session()]);
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(sessionsProvider).value!.single.title,
        canonical.title,
      );
    },
  );

  test('a titled DJ response cannot cancel a pending archive PATCH', () async {
    await container.read(sessionsProvider.future);
    container.listen(sessionsProvider, (_, _) {});
    api.onGetSession = (_) async =>
        SessionDetail(session: session(), messages: [], queue: []);
    container.listen(chatProvider('mix'), (_, _) {});
    await container.read(chatProvider('mix').future);
    final turn = Completer<TurnResult>();
    final patch = Completer<DjSession>();
    api.onSendMessage = (_, _) => turn.future;
    api.onSetStatus = (_, _) => patch.future;
    final send = container
        .read(chatProvider('mix').notifier)
        .send('A gentle mix');
    final archive = container.read(sessionsProvider.notifier).archive('mix');
    turn.complete(
      TurnResult(
        djMessage: DjMessage(
          id: 'dj',
          role: 'dj',
          content: 'Ready',
          createdAt: DateTime(2026),
        ),
        queue: [],
        queueVersion: 5,
        sessionTitle: 'DJ title',
      ),
    );
    await send;
    patch.complete(session(status: 'archived', title: 'DJ title'));
    expect(await archive, isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(sessionsProvider).value!.single.status, 'archived');
  });

  test('failed initial read cannot discard a successful PATCH', () async {
    final initial = Completer<List<DjSession>>();
    api.onListSessions = () => initial.future;
    container.listen(sessionsProvider, (_, _) {});
    final notifier = container.read(sessionsProvider.notifier);
    final canonical = session(title: 'Saved while loading');
    api.onRenameSession = (_, _) async => canonical;
    api.onListSessions = () async => [canonical];
    expect(await notifier.rename('mix', canonical.title), isTrue);
    initial.completeError(StateError('initial read failed'));
    await Future<void>.delayed(Duration.zero);
    expect(
      container.read(sessionsProvider).value!.single.title,
      canonical.title,
    );
    expect(container.read(sessionsProvider).hasError, isFalse);
  });
}
