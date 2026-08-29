import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/main.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/screens/home_screen.dart';
import 'package:mixtape/presentation/screens/sign_in_screen.dart';

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
}
