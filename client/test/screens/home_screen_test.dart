import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/library/library_sync_service.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/screens/home_screen.dart';
import '../helpers/fake_bridge.dart';

Future<void> _pump(
  WidgetTester tester, {
  required LibrarySyncService service,
}) async {
  final store = InMemoryTokenStore();
  await store.write('tok');
  await tester.pumpWidget(ProviderScope(
    overrides: [
      tokenStoreProvider.overrideWithValue(store),
      librarySyncServiceProvider.overrideWithValue(service),
    ],
    child: const MaterialApp(home: HomeScreen()),
  ));
  await tester.pumpAndSettle();
}

bool _textContains(Widget widget, String substring) =>
    widget is Text && (widget.data?.contains(substring) ?? false);

void main() {
  testWidgets('idle state shows the sync button', (tester) async {
    final service = LibrarySyncService(
      bridge: FakeBridge([]),
      api: await apiWith(MockClient((_) async => http.Response('{}', 200))),
    );
    await _pump(tester, service: service);

    expect(find.byKey(const Key('sync-library')), findsOneWidget);
  });

  testWidgets('tapping sync with a 3-song library ends on the synced message',
      (tester) async {
    final service = LibrarySyncService(
      bridge: FakeBridge([song(1), song(2), song(3)]),
      api: await apiWith(MockClient((_) async => http.Response('{"ingested": 0}', 200))),
    );
    await _pump(tester, service: service);

    await tester.tap(find.byKey(const Key('sync-library')));
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate((w) => _textContains(w, 'Synced 3 songs')),
      findsOneWidget,
    );
  });

  testWidgets('a denied bridge shows the denied message and a retry button',
      (tester) async {
    final service = LibrarySyncService(
      bridge: DeniedBridge(),
      api: await apiWith(MockClient((_) async => http.Response('{}', 200))),
    );
    await _pump(tester, service: service);

    await tester.tap(find.byKey(const Key('sync-library')));
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate((w) => _textContains(w, 'Music library access was denied')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('sync-retry')), findsOneWidget);
  });
}
