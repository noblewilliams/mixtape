import 'dart:async';
import '../helpers/auth_ui_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/apple_auth_gateway.dart';
import 'package:mixtape/data/auth/auth_repository.dart';
import 'package:mixtape/data/auth/account_api.dart';
import 'package:mixtape/data/auth/google_auth_gateway.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/screens/sign_in_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';

class _CancellingGateway implements AppleAuthGateway {
  @override
  Future<String> getIdentityToken() async => throw AppleSignInCancelled();
}

class _BrokenGateway implements AppleAuthGateway {
  @override
  Future<String> getIdentityToken() async =>
      throw StateError('native bridge unavailable');
}

class _PendingGateway implements AppleAuthGateway {
  final Completer<String> token = Completer<String>();
  @override
  Future<String> getIdentityToken() => token.future;
}

/// Refuses every method the way the server does for an unknown identity.
class _UnlinkedAuth extends AuthNotifier {
  @override
  AuthStatus build() => AuthStatus.signedOut;
  @override
  Future<void> signIn({
    AccountProvider provider = AccountProvider.apple,
  }) async {
    throw AuthSignInException(
      403,
      '{"code":"ACCOUNT_NOT_LINKED"}',
      'ACCOUNT_NOT_LINKED',
    );
  }
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

ProviderSignInButton _button(WidgetTester tester, String key) =>
    tester.widget<ProviderSignInButton>(find.byKey(Key(key)));

Future<void> _pump(
  WidgetTester tester,
  AppleAuthGateway gateway, {
  GoogleAuthGateway? google,
  AccountProvider? lastUsed = AccountProvider.apple,
  AuthNotifier Function()? auth,
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
        appleAuthGatewayProvider.overrideWithValue(gateway),
        if (google != null) googleAuthGatewayProvider.overrideWithValue(google),
        lastSignInProvider.overrideWith((_) async => lastUsed),
        if (auth != null) authProvider.overrideWith(auth),
      ],
      child: MaterialApp(
        theme: brightness == Brightness.dark
            ? MixtapeTheme.dark()
            : MixtapeTheme.light(),
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
  testWidgets('the resting screen carries the wordmark, promise and footer', (
    tester,
  ) async {
    await _pump(tester, _CancellingGateway(), google: _GoogleGateway());

    expect(find.text('mixtape'), findsOneWidget);
    expect(find.text('Your music.\nYour moment.'), findsOneWidget);
    expect(
      find.text('Sign in to keep your mixes and preferences.'),
      findsOneWidget,
    );
    expect(find.text('Continue with Apple'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(
      find.text('Apple Music access is requested separately.'),
      findsOneWidget,
    );
    // Both marks are drawn, and neither provider outranks the other.
    expect(find.byType(AppleMark), findsOneWidget);
    expect(find.byType(GoogleMark), findsOneWidget);
    expect(_button(tester, 'apple-sign-in').onPressed, isNotNull);
    expect(_button(tester, 'google-sign-in').onPressed, isNotNull);
    expect(find.byType(AppBar), findsNothing);
    // The note sits at the foot of the screen, not under the buttons.
    expect(
      tester
          .getBottomLeft(
            find.text('Apple Music access is requested separately.'),
          )
          .dy,
      greaterThan(tester.getSize(find.byType(SignInScreen)).height - 60),
    );
    expect(
      tester.getSize(find.byKey(const Key('apple-sign-in'))).height,
      greaterThanOrEqualTo(ProviderSignInButton.height),
    );
  });

  testWidgets('the last-used method is marked, and only that one', (
    tester,
  ) async {
    await _pump(
      tester,
      _CancellingGateway(),
      google: _GoogleGateway(),
      lastUsed: AccountProvider.google,
    );

    expect(find.text('Last used'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Last used')).dy,
      greaterThan(
        tester.getTopLeft(find.byKey(const Key('google-sign-in'))).dy,
      ),
    );
  });

  testWidgets('no remembered method shows no last-used line', (tester) async {
    await _pump(
      tester,
      _CancellingGateway(),
      google: _GoogleGateway(),
      lastUsed: null,
    );

    expect(find.text('Last used'), findsNothing);
  });

  testWidgets('a pending sheet announces waiting and disables both methods', (
    tester,
  ) async {
    final apple = _PendingGateway();
    await _pump(tester, apple, google: _GoogleGateway());

    await tester.tap(find.byKey(const Key('apple-sign-in')));
    await tester.pump();

    expect(find.text('Waiting for Apple…'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('Waiting for Apple…'),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Semantics && widget.properties.liveRegion == true,
        ),
      ),
      findsOneWidget,
    );
    expect(_button(tester, 'apple-sign-in').onPressed, isNull);
    expect(_button(tester, 'google-sign-in').onPressed, isNull);

    apple.token.completeError(AppleSignInCancelled());
    await tester.pumpAndSettle();
    expect(find.text('Waiting for Apple…'), findsNothing);
    expect(_button(tester, 'apple-sign-in').onPressed, isNotNull);
  });

  testWidgets(
    'Google cancellation is quiet and both buttons recover after a pending sheet',
    (tester) async {
      final token = Completer<String>();
      await _pump(
        tester,
        _CancellingGateway(),
        google: _GoogleGateway(onToken: () => token.future),
      );
      await tester.tap(find.byKey(const Key('google-sign-in')));
      await tester.pump();
      expect(find.text('Waiting for Google…'), findsOneWidget);
      for (final key in ['apple-sign-in', 'google-sign-in']) {
        expect(_button(tester, key).onPressed, isNull);
      }
      token.completeError(const GoogleSignInCancelled());
      await tester.pumpAndSettle();
      expect(find.text('Sign-in failed. Try again.'), findsNothing);
      expect(_button(tester, 'google-sign-in').onPressed, isNotNull);
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

    expect(_button(tester, 'google-sign-in').onPressed, isNull);
    expect(_button(tester, 'apple-sign-in').onPressed, isNotNull);
    // The reason sits under the Google button, not in the error line.
    final reason = find.byKey(SignInScreen.googleUnavailableKey);
    expect(reason, findsOneWidget);
    expect(
      find.descendant(
        of: reason,
        matching: find.text('Google sign-in is not available in this build.'),
      ),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(reason).dy,
      greaterThan(
        tester.getTopLeft(find.byKey(const Key('google-sign-in'))).dy,
      ),
    );
  });

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

      expect(
        find.descendant(
          of: find.byKey(SignInScreen.errorKey),
          matching: find.text('Sign-in failed. Try again.'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('native bridge'), findsNothing);
      expect(_button(tester, 'apple-sign-in').onPressed, isNotNull);
    },
  );

  testWidgets('an unlinked account is told which method to use', (
    tester,
  ) async {
    await _pump(
      tester,
      _CancellingGateway(),
      google: _GoogleGateway(onToken: () async => 'identity'),
      auth: _UnlinkedAuth.new,
    );

    await tester.tap(find.byKey(const Key('google-sign-in')));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'That account is not linked yet. Sign in with your usual method, then link it from Account.',
      ),
      findsOneWidget,
    );
    expect(_button(tester, 'google-sign-in').onPressed, isNotNull);
  });

  testWidgets('the error line is reserved, so the buttons never jump', (
    tester,
  ) async {
    await _pump(tester, _BrokenGateway(), google: _GoogleGateway());
    final before = tester.getTopLeft(find.byKey(const Key('apple-sign-in')));

    await tester.tap(find.byKey(const Key('apple-sign-in')));
    await tester.pumpAndSettle();

    expect(find.text('Sign-in failed. Try again.'), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const Key('apple-sign-in'))), before);
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
        google: _GoogleGateway(isAvailable: false),
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
}
