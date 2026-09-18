import 'dart:async';
import '../helpers/auth_ui_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/account_api.dart';
import 'package:mixtape/data/auth/google_auth_gateway.dart';
import 'package:mixtape/presentation/providers/account_provider.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart'
    show accountNameProvider;
import 'package:mixtape/presentation/screens/account_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/status_word.dart';
import 'package:mixtape/presentation/widgets/foundation/text_action.dart';

class _Auth extends AuthNotifier {
  int signsOut = 0;
  bool failSignOut = false;
  @override
  AuthStatus build() => AuthStatus.signedIn;
  @override
  Future<void> signOut() async {
    signsOut++;
    if (failSignOut) throw StateError('keychain unavailable');
    state = AuthStatus.signedOut;
  }
}

class _Google implements GoogleAuthGateway {
  _Google({this.isAvailable = true});
  @override
  final bool isAvailable;
  @override
  Future<String> getIdentityToken() async => 'identity';
}

class _Accounts extends AccountNotifier {
  _Accounts(this.initial);
  final AccountState initial;
  int links = 0;
  int removals = 0;
  int reads = 0;
  Completer<bool>? linking;
  @override
  AccountState build() => initial;
  @override
  Future<bool> link(AccountProvider provider) async {
    links++;
    state = AccountState(accounts: state.accounts, writing: true);
    if (linking != null) return linking!.future;
    state = const AccountState(accounts: [_apple, _google]);
    return true;
  }

  @override
  Future<bool> unlink(String id) async {
    removals++;
    state = AccountState(
      accounts: state.accounts!.where((a) => a.id != id).toList(),
    );
    return true;
  }

  @override
  Future<bool> refresh() async {
    reads++;
    state = const AccountState(accounts: [_apple]);
    return true;
  }

  void emit(AccountState next) => state = next;
}

const _apple = LinkedAccount(
  id: 'a',
  accountId: 'apple-sub',
  providerId: 'apple',
);
const _google = LinkedAccount(
  id: 'g',
  accountId: 'google-sub',
  providerId: 'google',
);

TextAction _action(WidgetTester tester, String key) =>
    tester.widget<TextAction>(find.byKey(Key(key)));

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Accounts accounts, {
  bool googleAvailable = true,
  String? name = 'Noble',
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  final container = ProviderContainer(
    overrides: [
      accountProvider.overrideWith(() => accounts),
      authProvider.overrideWith(_Auth.new),
      googleAuthGatewayProvider.overrideWithValue(
        _Google(isAvailable: googleAvailable),
      ),
      lastSignInProvider.overrideWith((_) async => AccountProvider.apple),
      accountNameProvider.overrideWith((_) async => name),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
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
          child: AccountScreen(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('the identity block names the listener and the title is large', (
    tester,
  ) async {
    await _pump(tester, _Accounts(const AccountState(accounts: [_apple])));

    expect(find.text('Account'), findsWidgets);
    expect(find.byKey(const Key('account-back')), findsOneWidget);
    expect(find.text('Noble'), findsOneWidget);
    expect(find.byKey(AccountScreen.avatarKey), findsOneWidget);
    expect(find.text('Login methods'), findsOneWidget);
  });

  testWidgets(
    'each method shows its mark, status and action; the last one cannot be unlinked',
    (tester) async {
      final accounts = _Accounts(const AccountState(accounts: [_apple]));
      await _pump(tester, accounts);

      expect(find.text('Apple'), findsOneWidget);
      expect(find.text('Google'), findsOneWidget);
      final statuses = tester
          .widgetList<StatusWord>(find.byType(StatusWord))
          .toList();
      expect(statuses.map((word) => word.label), ['Linked', 'Not linked']);
      expect(statuses.map((word) => word.kind), [
        StatusKind.ok,
        StatusKind.muted,
      ]);
      expect(find.text('Last used'), findsOneWidget);

      // Apple is the only method: unlinking is refused, with the reason.
      expect(_action(tester, 'remove-apple').onPressed, isNull);
      expect(find.text('Add another method first'), findsOneWidget);
      expect(_action(tester, 'link-google').label, 'Link');
      expect(_action(tester, 'remove-apple').label, 'Unlink');

      await tester.tap(find.byKey(const Key('link-google')));
      await tester.pumpAndSettle();
      expect(accounts.links, 1);
      expect(find.text('Add another method first'), findsNothing);

      await tester.tap(find.byKey(const Key('remove-google')));
      await tester.pumpAndSettle();
      expect(accounts.removals, 1);
      expect(find.byKey(const Key('link-google')), findsOneWidget);
    },
  );

  testWidgets('methods being verified say so and refuse mutations', (
    tester,
  ) async {
    final accounts = _Accounts(const AccountState(loading: true));
    await _pump(tester, accounts);

    expect(find.text('Verifying your login methods…'), findsOneWidget);
    expect(_action(tester, 'link-apple').onPressed, isNull);
    expect(_action(tester, 'link-google').onPressed, isNull);
  });

  testWidgets('missing Google configuration remains visible and disabled', (
    tester,
  ) async {
    await _pump(
      tester,
      _Accounts(const AccountState(accounts: [_apple])),
      googleAvailable: false,
    );

    expect(_action(tester, 'link-google').onPressed, isNull);
    expect(
      find.text('Google sign-in is not available in this build.'),
      findsOneWidget,
    );
  });

  testWidgets('unknown methods require reload before another mutation', (
    tester,
  ) async {
    final accounts = _Accounts(
      AccountState(error: AccountApiException(503, 'private', null)),
    );
    await _pump(tester, accounts);

    expect(_action(tester, 'link-apple').onPressed, isNull);
    expect(find.text('Not yet verified'), findsWidgets);

    await tester.tap(find.byKey(const Key('refresh-methods')));
    await tester.pumpAndSettle();

    expect(accounts.reads, 1);
    expect(find.byKey(const Key('remove-apple')), findsOneWidget);
    expect(find.textContaining('private'), findsNothing);
  });

  testWidgets('linking blocks duplicate link and removal requests', (
    tester,
  ) async {
    final accounts = _Accounts(const AccountState(accounts: [_apple]))
      ..linking = Completer<bool>();
    await _pump(tester, accounts);

    await tester.tap(find.byKey(const Key('link-google')));
    await tester.pump();
    expect(_action(tester, 'link-google').onPressed, isNull);
    await tester.tap(find.byKey(const Key('link-google')));
    expect(accounts.links, 1);

    accounts.emit(const AccountState(accounts: [_apple]));
    accounts.linking!.complete(false);
    await tester.pumpAndSettle();
  });

  testWidgets(
    'current 401 expires auth but a replaced error cannot sign out a later account',
    (tester) async {
      final accounts = _Accounts(const AccountState(accounts: [_apple]));
      final container = await _pump(tester, accounts);

      accounts.emit(
        AccountState(error: AccountApiException(401, 'private', null)),
      );
      accounts.emit(const AccountState(accounts: [_apple]));
      await tester.pumpAndSettle();
      expect((container.read(authProvider.notifier) as _Auth).signsOut, 0);

      accounts.emit(
        AccountState(error: AccountApiException(401, 'private', null)),
      );
      await tester.pumpAndSettle();
      expect((container.read(authProvider.notifier) as _Auth).signsOut, 1);
    },
  );

  testWidgets(
    'fresh-session rejection offers deliberate sign-in without automatic logout',
    (tester) async {
      final accounts = _Accounts(
        AccountState(
          accounts: [_apple, _google],
          error: AccountApiException(
            403,
            'private-sentinel',
            'SESSION_NOT_FRESH',
          ),
        ),
      );
      final container = await _pump(tester, accounts);

      expect(
        find.text('Sign in again before removing a login method.'),
        findsOneWidget,
      );
      expect(_action(tester, 'account-sign-out').label, 'Sign in again');
      expect((container.read(authProvider.notifier) as _Auth).signsOut, 0);
      expect(find.textContaining('private-sentinel'), findsNothing);
    },
  );

  testWidgets(
    'already-linked conflict explains unchanged account without exposing diagnostics',
    (tester) async {
      await _pump(
        tester,
        _Accounts(
          AccountState(
            accounts: [_apple],
            error: AccountApiException(
              409,
              'private-sentinel',
              'SOCIAL_ACCOUNT_ALREADY_LINKED',
            ),
          ),
        ),
      );

      expect(
        find.text(
          'That login method belongs to another account. Your current account is unchanged.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('link-google')), findsOneWidget);
      expect(find.textContaining('private-sentinel'), findsNothing);
    },
  );

  testWidgets(
    'sign out lives on You: Account offers it only after a failed expiry',
    (tester) async {
      final accounts = _Accounts(const AccountState(accounts: [_apple]));
      final container = await _pump(tester, accounts);
      expect(find.byKey(const Key('account-sign-out')), findsNothing);

      final auth = container.read(authProvider.notifier) as _Auth;
      auth.failSignOut = true;
      accounts.emit(
        AccountState(error: AccountApiException(401, 'private', null)),
      );
      await tester.pumpAndSettle();
      expect(auth.signsOut, 1);
      expect(find.text('Couldn’t sign out. Try again.'), findsOneWidget);

      auth.failSignOut = false;
      await tester.tap(find.byKey(const Key('account-sign-out')));
      await tester.pumpAndSettle();
      expect(auth.signsOut, 2);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets('native account snapshot in ${brightness.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await loadAuthSnapshotFonts(tester);
      await _pump(
        tester,
        _Accounts(const AccountState(accounts: [_apple, _google])),
        brightness: brightness,
      );
      expect(tester.takeException(), isNull);
      await captureAuthSnapshot(tester, 'native-account-${brightness.name}');
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets('Account fits narrow large text in ${brightness.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pump(
        tester,
        _Accounts(const AccountState(accounts: [_apple])),
        scale: 2,
        brightness: brightness,
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const Key('refresh-methods')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('refresh-methods')).hitTestable(),
        findsOneWidget,
      );
    });
  }
}
