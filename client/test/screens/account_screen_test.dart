import 'dart:async';
import '../helpers/auth_ui_snapshot.dart';
import 'package:flutter/cupertino.dart'
    show CupertinoAlertDialog, CupertinoDialogAction, CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/account_api.dart';
import 'package:mixtape/data/auth/apple_auth_gateway.dart';
import 'package:mixtape/data/auth/identity_token.dart';
import 'package:mixtape/data/auth/google_auth_gateway.dart';
import 'package:mixtape/presentation/providers/account_provider.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart'
    show accountNameProvider;
import 'package:mixtape/presentation/screens/account_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/inset_group.dart';
import 'package:mixtape/presentation/widgets/foundation/status_word.dart';
import 'package:mixtape/presentation/widgets/foundation/text_action.dart';

class _Auth extends AuthNotifier {
  _Auth({this.anonymous = false});
  final bool anonymous;
  int signsOut = 0;
  bool failSignOut = false;
  final deletions = <String?>[];
  bool failDelete = false;
  Completer<void>? deleting;
  @override
  bool get isAnonymous => anonymous;
  @override
  AuthStatus build() => AuthStatus.session;
  @override
  Future<void> signOut() async {
    signsOut++;
    if (failSignOut) throw StateError('keychain unavailable');
    state = AuthStatus.noSession;
  }

  @override
  Future<void> deleteAccount({String? appleAuthorizationCode}) async {
    deletions.add(appleAuthorizationCode);
    if (deleting != null) await deleting!.future;
    if (failDelete) throw AccountApiException(500, 'private-sentinel', null);
    state = AuthStatus.noSession;
  }
}

class _Apple implements AppleAuthGateway {
  _Apple({this.onCode});
  final Future<String> Function()? onCode;
  int codes = 0;
  @override
  Future<IdentityToken> getIdentityToken() async =>
      const IdentityToken('identity');
  @override
  Future<String> getAuthorizationCode() async {
    codes++;
    return onCode == null ? 'apple-code' : onCode!();
  }
}

class _Google implements GoogleAuthGateway {
  _Google({this.isAvailable = true});
  @override
  final bool isAvailable;
  @override
  Future<String> getIdentityToken() async => 'identity';
  @override
  Future<void> disconnect() async {}
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

InsetRow _deleteRow(WidgetTester tester) =>
    tester.widget<InsetRow>(find.byKey(const Key('account-delete')));

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _Accounts accounts, {
  bool googleAvailable = true,
  String? name = 'Noble',
  double scale = 1,
  Brightness brightness = Brightness.light,
  bool anonymous = false,
  _Apple? apple,
}) async {
  final container = ProviderContainer(
    overrides: [
      accountProvider.overrideWith(() => accounts),
      authProvider.overrideWith(() => _Auth(anonymous: anonymous)),
      appleAuthGatewayProvider.overrideWithValue(apple ?? _Apple()),
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

  group('Delete account', () {
    Future<void> confirm(WidgetTester tester) async {
      await tester.ensureVisible(find.byKey(const Key('account-delete')));
      await tester.tap(find.byKey(const Key('account-delete')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CupertinoDialogAction, AccountScreen.deleteLabel),
      );
      await tester.pumpAndSettle();
    }

    _Auth auth(ProviderContainer container) =>
        container.read(authProvider.notifier) as _Auth;

    testWidgets('is offered to accounts, never to anonymous listeners', (
      tester,
    ) async {
      await _pump(tester, _Accounts(const AccountState(accounts: [_apple])));
      expect(_deleteRow(tester).title, 'Delete account');
      expect(
        find.descendant(
          of: find.byKey(const Key('account-delete')),
          matching: find.byIcon(CupertinoIcons.trash),
        ),
        findsOneWidget,
      );
      expect(_deleteRow(tester).destructive, isTrue);
      expect(_deleteRow(tester).onTap, isNotNull);

      await _pump(
        tester,
        _Accounts(const AccountState(accounts: [_apple])),
        anonymous: true,
      );
      expect(find.byKey(const Key('account-delete')), findsNothing);
    });

    testWidgets('asks first in a native alert; Cancel deletes nothing', (
      tester,
    ) async {
      final apple = _Apple();
      final container = await _pump(
        tester,
        _Accounts(const AccountState(accounts: [_apple])),
        apple: apple,
      );
      await tester.ensureVisible(find.byKey(const Key('account-delete')));
      await tester.tap(find.byKey(const Key('account-delete')));
      await tester.pumpAndSettle();

      expect(find.byType(CupertinoAlertDialog), findsOneWidget);
      expect(find.text(AccountScreen.deleteTitle), findsOneWidget);
      expect(find.text(AccountScreen.deleteBody), findsOneWidget);
      final destructive = tester.widget<CupertinoDialogAction>(
        find.widgetWithText(CupertinoDialogAction, AccountScreen.deleteLabel),
      );
      expect(destructive.isDestructiveAction, isTrue);

      await tester.tap(find.widgetWithText(CupertinoDialogAction, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoAlertDialog), findsNothing);
      expect(auth(container).deletions, isEmpty);
      expect(apple.codes, 0);
    });

    testWidgets('an Apple login reconfirms with Apple and sends its code', (
      tester,
    ) async {
      final apple = _Apple();
      final container = await _pump(
        tester,
        _Accounts(const AccountState(accounts: [_apple, _google])),
        apple: apple,
      );
      await confirm(tester);

      expect(apple.codes, 1);
      expect(auth(container).deletions, ['apple-code']);
      expect(container.read(authProvider), AuthStatus.noSession);
    });

    testWidgets('a Google-only account deletes without the Apple sheet', (
      tester,
    ) async {
      final apple = _Apple();
      final container = await _pump(
        tester,
        _Accounts(const AccountState(accounts: [_google])),
        apple: apple,
      );
      await confirm(tester);

      expect(apple.codes, 0);
      expect(auth(container).deletions, [null]);
    });

    testWidgets('dismissing the Apple sheet quietly deletes nothing', (
      tester,
    ) async {
      final container = await _pump(
        tester,
        _Accounts(const AccountState(accounts: [_apple])),
        apple: _Apple(onCode: () async => throw AppleSignInCancelled()),
      );
      await confirm(tester);

      expect(auth(container).deletions, isEmpty);
      expect(find.text(AccountScreen.deleteFailed), findsNothing);
      expect(_deleteRow(tester).onTap, isNotNull);
    });

    testWidgets('a failure says so without diagnostics and can be retried', (
      tester,
    ) async {
      final accounts = _Accounts(const AccountState(accounts: [_apple]));
      final container = await _pump(tester, accounts);
      auth(container).failDelete = true;
      await confirm(tester);

      expect(find.text(AccountScreen.deleteFailed), findsOneWidget);
      expect(find.textContaining('private-sentinel'), findsNothing);
      expect(container.read(authProvider), AuthStatus.session);

      auth(container).failDelete = false;
      await confirm(tester);
      expect(auth(container).deletions, hasLength(2));
      expect(container.read(authProvider), AuthStatus.noSession);
    });

    testWidgets('an Apple sheet that fails (not cancelled) still deletes, '
        'without a code', (tester) async {
      final container = await _pump(
        tester,
        _Accounts(const AccountState(accounts: [_apple])),
        apple: _Apple(onCode: () async => throw StateError('private-sentinel')),
      );
      await confirm(tester);

      expect(auth(container).deletions, [null]);
      expect(find.text(AccountScreen.deleteFailed), findsNothing);
      expect(container.read(authProvider), AuthStatus.noSession);
    });

    testWidgets('unverified methods keep it disabled until a refresh', (
      tester,
    ) async {
      final accounts = _Accounts(
        AccountState(error: AccountApiException(503, 'private', null)),
      );
      await _pump(tester, accounts);
      expect(_deleteRow(tester).onTap, isNull);

      await tester.tap(find.byKey(const Key('refresh-methods')));
      await tester.pumpAndSettle();
      expect(_deleteRow(tester).onTap, isNotNull);
    });

    testWidgets('is disabled while deleting and while methods load', (
      tester,
    ) async {
      final container = await _pump(
        tester,
        _Accounts(const AccountState(accounts: [_google])),
      );
      final pending = Completer<void>();
      auth(container).deleting = pending;
      await tester.ensureVisible(find.byKey(const Key('account-delete')));
      await tester.tap(find.byKey(const Key('account-delete')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(CupertinoDialogAction, AccountScreen.deleteLabel),
      );
      await tester.pump();
      await tester.pump();
      expect(_deleteRow(tester).onTap, isNull);
      expect(_action(tester, 'link-apple').onPressed, isNull);
      pending.complete();
      await tester.pumpAndSettle();

      await _pump(tester, _Accounts(const AccountState(loading: true)));
      expect(_deleteRow(tester).onTap, isNull);
    });
  });

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
