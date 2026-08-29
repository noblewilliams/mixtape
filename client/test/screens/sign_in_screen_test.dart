import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/apple_auth_gateway.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/screens/sign_in_screen.dart';

class _CancellingGateway implements AppleAuthGateway {
  @override
  Future<String> getIdentityToken() async => throw AppleSignInCancelled();
}

class _BrokenGateway implements AppleAuthGateway {
  @override
  Future<String> getIdentityToken() async => throw StateError('native bridge unavailable');
}

Future<void> _pump(WidgetTester tester, AppleAuthGateway gateway) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      appleAuthGatewayProvider.overrideWithValue(gateway),
    ],
    child: const MaterialApp(home: SignInScreen()),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a cancelled Apple sheet shows no snackbar and stays on sign-in',
      (tester) async {
    await _pump(tester, _CancellingGateway());

    await tester.tap(find.byKey(const Key('apple-sign-in')));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(SignInScreen), findsOneWidget);
  });

  testWidgets('a broken gateway shows the friendly sign-in-failed snackbar',
      (tester) async {
    await _pump(tester, _BrokenGateway());

    await tester.tap(find.byKey(const Key('apple-sign-in')));
    await tester.pumpAndSettle();

    expect(find.text('Sign-in failed. Try again.'), findsOneWidget);
  });
}
