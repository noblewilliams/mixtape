import 'package:mixtape/data/playlists/playlist_context_models.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/library/library_sync_service.dart';
import 'package:mixtape/main.dart';
import 'package:mixtape/data/onboarding/funnel_once_store.dart';
import 'package:mixtape/data/onboarding/service_preference_store.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/device_providers.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';
import 'package:mixtape/presentation/screens/home_screen.dart';
import 'package:mixtape/presentation/screens/shell/shell_screen.dart';
import 'package:mixtape/presentation/screens/sign_in_screen.dart';
import '../helpers/fake_bridge.dart'
    show FakeBridge, song, apiWith, emptyPlaylistSyncResponse;
import '../helpers/fake_listening_api.dart';

/// Home now watches sessionsProvider on every build (sessions-first Home,
/// Task 6) — a bare FakeDjApi with an empty session list keeps these
/// sign-in/sign-out/sync gate tests from making a real network call.
class _FakeDjApi implements DjApi {
  @override
  Future<void> recordPlaylistCreation(
    String sessionId,
    String appleLibraryId,
  ) async {}

  @override
  Duration get timeout => const Duration(seconds: 120);

  @override
  Future<List<DjSession>> listSessions() async => [];

  @override
  Future<SessionDetail> createSession(String prompt, {InitialPlaylistSeed? playlistSeed}) =>
      throw UnimplementedError();

  @override
  Future<SessionDetail> getSession(String id) => throw UnimplementedError();

  @override
  Future<TurnResult> sendMessage(String id, String text) =>
      throw UnimplementedError();

  @override
  Future<QueueOpsResult> applyQueueOps(
    String id,
    List<QueueOp> ops,
    int? expectedVersion,
  ) => throw UnimplementedError();

  @override
  Future<DjSession> setStatus(String id, String status) =>
      throw UnimplementedError();

  @override
  Future<DjSession> renameSession(String id, String title) =>
      throw UnimplementedError();

  @override
  Future<void> postSessionEvent(String sessionId, String type) =>
      throw UnimplementedError();

  @override
  Future<List<DjMemory>> listMemories() => throw UnimplementedError();

  @override
  Future<void> deleteMemory(String id) => throw UnimplementedError();

  @override
  void close() {}
}

/// An ApiClient whose postJson calls block on [gate] until it's completed —
/// lets a test freeze a sync mid-POST to control exactly when a cancellation lands.
Future<ApiClient> _pausableApi(Completer<void> gate) async {
  final store = InMemoryTokenStore();
  await store.write('t');
  return ApiClient(
    baseUrl: 'http://x',
    tokenStore: store,
    inner: MockClient((_) async {
      await gate.future;
      return http.Response('{"ingested": 0}', 200);
    }),
  );
}

/// Home has no overflow menu since task 2.2 — sign-out is the You tab's and
/// library sync the Library tab's. These cases are about what an auth
/// transition does to a shared service, so they speak to the providers
/// directly and read the sync state back rather than through a sheet.
ProviderContainer _containerOf(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(MixtapeApp)));

Future<void> _signOut(WidgetTester tester) async {
  _containerOf(tester).read(authProvider.notifier).signOut();
  await tester.pumpAndSettle();
}

Future<void> _sync(WidgetTester tester) async {
  await _containerOf(tester).read(librarySyncProvider.notifier).sync();
  await tester.pumpAndSettle();
}

SyncState _syncState(WidgetTester tester) =>
    _containerOf(tester).read(librarySyncProvider);

void _expectSyncedThreeSongs(WidgetTester tester) {
  final state = _syncState(tester);
  expect(state, isA<SyncDone>());
  expect((state as SyncDone).summary.songs, 3);
}

void main() {
  // Sign-in's cassette turns for as long as the screen is on show, so a
  // settle would never finish; reduced motion holds its hubs still.
  setUp(
    () =>
        TestWidgetsFlutterBinding.ensureInitialized()
            .platformDispatcher
            .accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
          disableAnimations: true,
        ),
  );
  tearDown(
    () => TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .clearAccessibilityFeaturesTestValue(),
  );

  testWidgets('shows sign-in when signed out', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [tokenStoreProvider.overrideWithValue(InMemoryTokenStore())],
        child: const MixtapeApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SignInScreen), findsOneWidget);
  });

  testWidgets('shows home when a token exists', (tester) async {
    final store = InMemoryTokenStore();
    await store.write('tok');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          djApiProvider.overrideWithValue(_FakeDjApi()),
          // An Apple listener: the service gate resolves straight to Home.
          listeningApiProvider.overrideWithValue(FakeListeningApi()),
          reminderSchedulerProvider.overrideWithValue(FakeReminderScheduler()),
          servicePreferenceStoreProvider.overrideWithValue(
            InMemoryServicePreferenceStore(),
          ),
          funnelOnceStoreProvider.overrideWithValue(InMemoryFunnelOnceStore()),
        ],
        child: const MixtapeApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ShellScreen), findsOneWidget);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('sign-out returns to sign-in', (tester) async {
    final store = InMemoryTokenStore();
    await store.write('tok');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tokenStoreProvider.overrideWithValue(store),
          djApiProvider.overrideWithValue(_FakeDjApi()),
          // An Apple listener: the service gate resolves straight to Home.
          listeningApiProvider.overrideWithValue(FakeListeningApi()),
          reminderSchedulerProvider.overrideWithValue(FakeReminderScheduler()),
          servicePreferenceStoreProvider.overrideWithValue(
            InMemoryServicePreferenceStore(),
          ),
          funnelOnceStoreProvider.overrideWithValue(InMemoryFunnelOnceStore()),
        ],
        child: const MixtapeApp(),
      ),
    );
    await tester.pumpAndSettle();
    await _signOut(tester);
    expect(find.byType(SignInScreen), findsOneWidget);
    expect(await store.read(), isNull);
  });

  testWidgets(
    "signing back in as a new user doesn't show the previous user's stale sync result",
    (tester) async {
      final store = InMemoryTokenStore();
      await store.write('tok-a');
      final service = LibrarySyncService(
        bridge: FakeBridge([song(1), song(2), song(3)]),
        api: await apiWith(
          MockClient((request) async => emptyPlaylistSyncResponse(request)),
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tokenStoreProvider.overrideWithValue(store),
            djApiProvider.overrideWithValue(_FakeDjApi()),
            // An Apple listener: the service gate resolves straight to Home.
            listeningApiProvider.overrideWithValue(FakeListeningApi()),
            reminderSchedulerProvider.overrideWithValue(
              FakeReminderScheduler(),
            ),
            servicePreferenceStoreProvider.overrideWithValue(
              InMemoryServicePreferenceStore(),
            ),
            funnelOnceStoreProvider.overrideWithValue(
              InMemoryFunnelOnceStore(),
            ),
            librarySyncServiceProvider.overrideWithValue(service),
          ],
          child: const MixtapeApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ShellScreen), findsOneWidget);

      await _sync(tester);
      _expectSyncedThreeSongs(tester);

      await _signOut(tester);
      expect(find.byType(SignInScreen), findsOneWidget);

      // A new user signs in on the same device.
      await store.write('tok-b');
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MixtapeApp)),
      );
      container.invalidate(authProvider);
      await tester.pumpAndSettle();

      expect(find.byType(ShellScreen), findsOneWidget);
      expect(
        _syncState(tester),
        isA<SyncIdle>(),
        reason: "the next user starts from idle, not the previous one's result",
      );
    },
  );

  testWidgets(
    "an idle sign-out doesn't latch a cancellation that blocks the next user's sync",
    (tester) async {
      final store = InMemoryTokenStore();
      await store.write('tok-a');
      final service = LibrarySyncService(
        bridge: FakeBridge([song(1), song(2), song(3)]),
        api: await apiWith(
          MockClient((request) async => emptyPlaylistSyncResponse(request)),
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tokenStoreProvider.overrideWithValue(store),
            djApiProvider.overrideWithValue(_FakeDjApi()),
            // An Apple listener: the service gate resolves straight to Home.
            listeningApiProvider.overrideWithValue(FakeListeningApi()),
            reminderSchedulerProvider.overrideWithValue(
              FakeReminderScheduler(),
            ),
            servicePreferenceStoreProvider.overrideWithValue(
              InMemoryServicePreferenceStore(),
            ),
            funnelOnceStoreProvider.overrideWithValue(
              InMemoryFunnelOnceStore(),
            ),
            librarySyncServiceProvider.overrideWithValue(service),
          ],
          child: const MixtapeApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ShellScreen), findsOneWidget);

      // User A syncs to completion.
      await _sync(tester);
      _expectSyncedThreeSongs(tester);

      // Sign out with nothing running — this still disposes the notifier and
      // fires cancel() on the (idle) shared service.
      await _signOut(tester);
      expect(find.byType(SignInScreen), findsOneWidget);

      // User B signs in on the same device.
      await store.write('tok-b');
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MixtapeApp)),
      );
      container.invalidate(authProvider);
      await tester.pumpAndSettle();
      expect(find.byType(ShellScreen), findsOneWidget);
      expect(_syncState(tester), isA<SyncIdle>());

      // User B's first sync must actually run, not silently no-op back to idle.
      await _sync(tester);
      _expectSyncedThreeSongs(tester);
    },
  );

  testWidgets(
    'sign-out mid-POST on a NON-final page cancels cleanly for the next user',
    (tester) async {
      final gate = Completer<void>();
      final store = InMemoryTokenStore();
      await store.write('tok-a');
      // 6 songs over 3-song chunks: the first postJson (gated) is not the last one.
      final service = LibrarySyncService(
        bridge: FakeBridge(List.generate(6, song)),
        api: await _pausableApi(gate),
        chunkSize: 3,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tokenStoreProvider.overrideWithValue(store),
            djApiProvider.overrideWithValue(_FakeDjApi()),
            // An Apple listener: the service gate resolves straight to Home.
            listeningApiProvider.overrideWithValue(FakeListeningApi()),
            reminderSchedulerProvider.overrideWithValue(
              FakeReminderScheduler(),
            ),
            servicePreferenceStoreProvider.overrideWithValue(
              InMemoryServicePreferenceStore(),
            ),
            funnelOnceStoreProvider.overrideWithValue(
              InMemoryFunnelOnceStore(),
            ),
            librarySyncServiceProvider.overrideWithValue(service),
          ],
          child: const MixtapeApp(),
        ),
      );
      await tester.pumpAndSettle();

      // The sync lives in the provider, so nothing has to stay on screen for
      // it to keep running. Not pumpAndSettle: it is gated mid-POST.
      unawaited(_containerOf(tester).read(librarySyncProvider.notifier).sync());
      await tester.pump();
      await tester.pump();

      // Sign out while the first chunk's POST is still in flight.
      _containerOf(tester).read(authProvider.notifier).signOut();
      await tester.pump();
      await tester.pump();
      expect(find.byType(SignInScreen), findsOneWidget);

      // Let the gated POST resolve; the loop should observe the cancellation
      // immediately after and throw instead of continuing to the next chunk.
      gate.complete();
      await tester.pumpAndSettle();

      // A new user signs in on the same device.
      await store.write('tok-b');
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MixtapeApp)),
      );
      container.invalidate(authProvider);
      await tester.pumpAndSettle();

      expect(find.byType(ShellScreen), findsOneWidget);
      expect(
        _syncState(tester),
        isA<SyncIdle>(),
        reason: 'the cancellation never reaches the next user',
      );
    },
  );

  testWidgets(
    'sign-out mid-POST on the FINAL page cancels cleanly for the next user',
    (tester) async {
      final gate = Completer<void>();
      final store = InMemoryTokenStore();
      await store.write('tok-a');
      // 2 songs, default chunk size: the single gated postJson IS the last chunk.
      final service = LibrarySyncService(
        bridge: FakeBridge([song(1), song(2)]),
        api: await _pausableApi(gate),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            tokenStoreProvider.overrideWithValue(store),
            djApiProvider.overrideWithValue(_FakeDjApi()),
            // An Apple listener: the service gate resolves straight to Home.
            listeningApiProvider.overrideWithValue(FakeListeningApi()),
            reminderSchedulerProvider.overrideWithValue(
              FakeReminderScheduler(),
            ),
            servicePreferenceStoreProvider.overrideWithValue(
              InMemoryServicePreferenceStore(),
            ),
            funnelOnceStoreProvider.overrideWithValue(
              InMemoryFunnelOnceStore(),
            ),
            librarySyncServiceProvider.overrideWithValue(service),
          ],
          child: const MixtapeApp(),
        ),
      );
      await tester.pumpAndSettle();

      // Same as the NON-final case: the gated POST is in flight and nothing
      // has to be on screen for it.
      unawaited(_containerOf(tester).read(librarySyncProvider.notifier).sync());
      await tester.pump();
      await tester.pump();

      // Sign out while the only (and final) chunk's POST is still in flight.
      _containerOf(tester).read(authProvider.notifier).signOut();
      await tester.pump();
      await tester.pump();
      expect(find.byType(SignInScreen), findsOneWidget);

      // Let the gated POST resolve; the loop should observe the cancellation
      // immediately after and throw instead of completing with SyncDone.
      gate.complete();
      await tester.pumpAndSettle();

      // A new user signs in on the same device.
      await store.write('tok-b');
      final container = ProviderScope.containerOf(
        tester.element(find.byType(MixtapeApp)),
      );
      container.invalidate(authProvider);
      await tester.pumpAndSettle();

      expect(find.byType(ShellScreen), findsOneWidget);
      expect(
        _syncState(tester),
        isA<SyncIdle>(),
        reason: 'the cancellation never reaches the next user',
      );
    },
  );
}
