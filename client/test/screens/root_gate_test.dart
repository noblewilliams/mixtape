import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/library/library_sync_service.dart';
import 'package:mixtape/main.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/screens/home_screen.dart';
import 'package:mixtape/presentation/screens/sign_in_screen.dart';
import '../helpers/fake_bridge.dart' show FakeBridge, song, apiWith;

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

bool _containsText(Widget w, String substring) =>
    w is Text && (w.data?.contains(substring) ?? false);

void main() {
  testWidgets('shows sign-in when signed out', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [tokenStoreProvider.overrideWithValue(InMemoryTokenStore())],
      child: const MixtapeApp(),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(SignInScreen), findsOneWidget);
  });

  testWidgets('shows home when a token exists', (tester) async {
    final store = InMemoryTokenStore();
    await store.write('tok');
    await tester.pumpWidget(ProviderScope(
      overrides: [tokenStoreProvider.overrideWithValue(store)],
      child: const MixtapeApp(),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('sign-out returns to sign-in', (tester) async {
    final store = InMemoryTokenStore();
    await store.write('tok');
    await tester.pumpWidget(ProviderScope(
      overrides: [tokenStoreProvider.overrideWithValue(store)],
      child: const MixtapeApp(),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.logout));
    await tester.pumpAndSettle();
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
      api: await apiWith(MockClient((_) async => http.Response('{"ingested": 0}', 200))),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        tokenStoreProvider.overrideWithValue(store),
        librarySyncServiceProvider.overrideWithValue(service),
      ],
      child: const MixtapeApp(),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);

    await tester.tap(find.byKey(const Key('sync-library')));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
          (w) => w is Text && (w.data?.contains('Synced 3 songs') ?? false)),
      findsOneWidget,
    );

    await tester.tap(find.byIcon(Icons.logout));
    await tester.pumpAndSettle();
    expect(find.byType(SignInScreen), findsOneWidget);

    // A new user signs in on the same device.
    await store.write('tok-b');
    final container = ProviderScope.containerOf(tester.element(find.byType(MixtapeApp)));
    container.invalidate(authProvider);
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byKey(const Key('sync-library')), findsOneWidget);
    expect(
      find.byWidgetPredicate(
          (w) => w is Text && (w.data?.contains('Synced 3 songs') ?? false)),
      findsNothing,
    );
  });

  testWidgets(
      "an idle sign-out doesn't latch a cancellation that blocks the next user's sync",
      (tester) async {
    final store = InMemoryTokenStore();
    await store.write('tok-a');
    final service = LibrarySyncService(
      bridge: FakeBridge([song(1), song(2), song(3)]),
      api: await apiWith(MockClient((_) async => http.Response('{"ingested": 0}', 200))),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        tokenStoreProvider.overrideWithValue(store),
        librarySyncServiceProvider.overrideWithValue(service),
      ],
      child: const MixtapeApp(),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);

    // User A syncs to completion.
    await tester.tap(find.byKey(const Key('sync-library')));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
          (w) => w is Text && (w.data?.contains('Synced 3 songs') ?? false)),
      findsOneWidget,
    );

    // Sign out with nothing running — this still disposes the notifier and
    // fires cancel() on the (idle) shared service.
    await tester.tap(find.byIcon(Icons.logout));
    await tester.pumpAndSettle();
    expect(find.byType(SignInScreen), findsOneWidget);

    // User B signs in on the same device.
    await store.write('tok-b');
    final container = ProviderScope.containerOf(tester.element(find.byType(MixtapeApp)));
    container.invalidate(authProvider);
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byKey(const Key('sync-library')), findsOneWidget);

    // User B's first sync must actually run, not silently no-op back to idle.
    await tester.tap(find.byKey(const Key('sync-library')));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
          (w) => w is Text && (w.data?.contains('Synced 3 songs') ?? false)),
      findsOneWidget,
    );
  });

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
    await tester.pumpWidget(ProviderScope(
      overrides: [
        tokenStoreProvider.overrideWithValue(store),
        librarySyncServiceProvider.overrideWithValue(service),
      ],
      child: const MixtapeApp(),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('sync-library')));
    await tester.pump();
    await tester.pump();

    // Sign out while the first chunk's POST is still in flight.
    await tester.tap(find.byIcon(Icons.logout));
    await tester.pump();
    await tester.pump();
    expect(find.byType(SignInScreen), findsOneWidget);

    // Let the gated POST resolve; the loop should observe the cancellation
    // immediately after and throw instead of continuing to the next chunk.
    gate.complete();
    await tester.pumpAndSettle();

    // A new user signs in on the same device.
    await store.write('tok-b');
    final container = ProviderScope.containerOf(tester.element(find.byType(MixtapeApp)));
    container.invalidate(authProvider);
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byKey(const Key('sync-library')), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byWidgetPredicate((w) => _containsText(w, 'Synced')), findsNothing);
  });

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
    await tester.pumpWidget(ProviderScope(
      overrides: [
        tokenStoreProvider.overrideWithValue(store),
        librarySyncServiceProvider.overrideWithValue(service),
      ],
      child: const MixtapeApp(),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('sync-library')));
    await tester.pump();
    await tester.pump();

    // Sign out while the only (and final) chunk's POST is still in flight.
    await tester.tap(find.byIcon(Icons.logout));
    await tester.pump();
    await tester.pump();
    expect(find.byType(SignInScreen), findsOneWidget);

    // Let the gated POST resolve; the loop should observe the cancellation
    // immediately after and throw instead of completing with SyncDone.
    gate.complete();
    await tester.pumpAndSettle();

    // A new user signs in on the same device.
    await store.write('tok-b');
    final container = ProviderScope.containerOf(tester.element(find.byType(MixtapeApp)));
    container.invalidate(authProvider);
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byKey(const Key('sync-library')), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byWidgetPredicate((w) => _containsText(w, 'Synced')), findsNothing);
  });
}
