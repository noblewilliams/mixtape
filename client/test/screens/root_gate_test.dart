import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/library/library_sync_service.dart';
import 'package:mixtape/main.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/screens/home_screen.dart';
import 'package:mixtape/presentation/screens/sign_in_screen.dart';
import '../helpers/fake_bridge.dart' show FakeBridge, song, apiWith;

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
}
