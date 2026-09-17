import 'dart:async';
import '../helpers/auth_ui_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/apple_auth_gateway.dart';
import 'package:mixtape/data/auth/account_api.dart';
import 'package:mixtape/data/auth/google_auth_gateway.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/screens/sign_in_screen.dart';

class _CancellingGateway implements AppleAuthGateway {
  @override
  Future<String> getIdentityToken() async => throw AppleSignInCancelled();
}

class _BrokenGateway implements AppleAuthGateway {
  @override
  Future<String> getIdentityToken() async =>
      throw StateError('native bridge unavailable');
}

class _GoogleGateway implements GoogleAuthGateway {
  _GoogleGateway({this.isAvailable = true, this.onToken});
  @override
  final bool isAvailable;
  final Future<String> Function()? onToken;
  @override
  Future<String> getIdentityToken() async =>
      onToken == null ? throw const GoogleSignInCancelled() : onToken!();
}

Future<void> _pump(
  WidgetTester tester,
  AppleAuthGateway gateway, {
  GoogleAuthGateway? google,
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
        appleAuthGatewayProvider.overrideWithValue(gateway),
        if (google != null) googleAuthGatewayProvider.overrideWithValue(google),
        lastSignInProvider.overrideWith((_) async => AccountProvider.apple),
      ],
      child: MaterialApp(
        theme: authSnapshotTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const RepaintBoundary(
          key: authSnapshotKey,
          child: SignInScreen(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Google cancellation is quiet and both buttons recover after a pending sheet',
    (tester) async {
      final token = Completer<String>();
      await _pump(
        tester,
        _CancellingGateway(),
        google: _GoogleGateway(onToken: () => token.future),
      );
      expect(find.text('Last used'), findsOneWidget);
      await tester.tap(find.byKey(const Key('google-sign-in')));
      await tester.pump();
      for (final key in ['apple-sign-in', 'google-sign-in']) {
        expect(
          tester.widget<OutlinedButton>(find.byKey(Key(key))).onPressed,
          isNull,
        );
      }
      token.completeError(const GoogleSignInCancelled());
      await tester.pumpAndSettle();
      expect(find.text('Sign-in failed. Try again.'), findsNothing);
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('google-sign-in')))
            .onPressed,
        isNotNull,
      );
    },
  );
  testWidgets('Google unavailable is truthful without disabling Apple', (
    tester,
  ) async {
    await _pump(
      tester,
      _CancellingGateway(),
      google: _GoogleGateway(isAvailable: false),
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('google-sign-in')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('apple-sign-in')))
          .onPressed,
      isNotNull,
    );
    expect(
      find.text('Google sign-in is not available in this build.'),
      findsOneWidget,
    );
  });
  for (final brightness in Brightness.values) {
    testWidgets('native signin snapshot in ${brightness.name}', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await loadAuthSnapshotFonts(tester);
      await _pump(
        tester,
        _CancellingGateway(),
        google: _GoogleGateway(),
        brightness: brightness,
      );
      expect(tester.takeException(), isNull);
      await captureAuthSnapshot(tester, 'native-signin-${brightness.name}');
    });
  }
  for (final brightness in Brightness.values) {
    testWidgets('sign-in fits narrow 200% text in ${brightness.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pump(
        tester,
        _CancellingGateway(),
        google: _GoogleGateway(),
        scale: 2,
        brightness: brightness,
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const Key('google-sign-in')));
      expect(
        find.byKey(const Key('google-sign-in')).hitTestable(),
        findsOneWidget,
      );
    });
  }

  testWidgets(
    'a cancelled Apple sheet shows no snackbar and stays on sign-in',
    (tester) async {
      await _pump(tester, _CancellingGateway());

      await tester.tap(find.byKey(const Key('apple-sign-in')));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
      expect(find.byType(SignInScreen), findsOneWidget);
    },
  );

  testWidgets(
    'a broken gateway shows a safe inline error and leaves retry available',
    (tester) async {
      await _pump(tester, _BrokenGateway());

      await tester.tap(find.byKey(const Key('apple-sign-in')));
      await tester.pumpAndSettle();

      expect(find.text('Sign-in failed. Try again.'), findsOneWidget);
    },
  );
}
