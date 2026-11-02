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
import 'package:mixtape/presentation/providers/capabilities_provider.dart'
    show meProvider;
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

/// The name write only; everything else is unused by these tests.
class _NameApi implements AccountApi {
  _NameApi({this.onWrite});
  final Future<void> Function(String?)? onWrite;
  final writes = <String?>[];
  @override
  Future<void> updateUser({String? name}) async {
    writes.add(name);
    if (onWrite != null) await onWrite!(name);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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
  _NameApi? api,
  String? Function()? liveName,
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
      if (liveName == null)
        accountNameProvider.overrideWith((_) async => name)
      else ...[
        // As the real one: derived from /me, so invalidating /me refreshes it.
        meProvider.overrideWith((_) async => null),
        accountNameProvider.overrideWith((ref) async {
          await ref.watch(meProvider.future);
          return liveName();
        }),
      ],
      if (api != null) accountApiProvider.overrideWithValue(api),
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

  group('name', () {
    Finder field() => find.byKey(AccountScreen.nameFieldKey);
    _Auth auth(ProviderContainer container) =>
        container.read(authProvider.notifier) as _Auth;
    String fieldText(WidgetTester tester) =>
        tester.widget<TextField>(field()).controller!.text;

    testWidgets('unnamed: the row offers Add name and is one button', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _pump(
        tester,
        _Accounts(const AccountState(accounts: [_apple])),
        name: null,
      );
      expect(find.text(AccountScreen.unnamedListener), findsOneWidget);
      expect(find.text(AccountScreen.addName), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsNothing);
      expect(find.bySemanticsLabel('Your account. Add name'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('named: the row says Edit and reads the name', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pump(tester, _Accounts(const AccountState(accounts: [_apple])));
      expect(find.text('Noble'), findsOneWidget);
      expect(find.text(AccountScreen.editName), findsOneWidget);
      expect(find.bySemanticsLabel('Noble, your name. Edit'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(AccountScreen.nameRowKey)).height,
        greaterThanOrEqualTo(44),
      );
      semantics.dispose();
    });

    testWidgets('anonymous listeners get no edit', (tester) async {
      await _pump(
        tester,
        _Accounts(const AccountState(accounts: [_apple])),
        anonymous: true,
        name: null,
      );
      expect(find.text(AccountScreen.addName), findsNothing);
      await tester.tap(find.text(AccountScreen.unnamedListener));
      await tester.pumpAndSettle();
      expect(field(), findsNothing);
    });

    testWidgets('tapping the row edits in place with the hint and actions', (
      tester,
    ) async {
      await _pump(tester, _Accounts(const AccountState(accounts: [_apple])));
      await tester.tap(find.byKey(AccountScreen.nameRowKey));
      await tester.pumpAndSettle();

      expect(field(), findsOneWidget);
      expect(fieldText(tester), 'Noble');
      final editable = tester.widget<EditableText>(find.byType(EditableText));
      expect(editable.focusNode.hasFocus, isTrue);
      expect(editable.controller.selection.baseOffset, 5);
      expect(find.text(AccountScreen.nameHint), findsOneWidget);
      expect(find.byKey(AccountScreen.nameSaveKey), findsOneWidget);
      expect(find.byKey(AccountScreen.nameCancelKey), findsOneWidget);
      expect(find.text(AccountScreen.editName), findsNothing);
      expect(find.byKey(AccountScreen.nameClearKey), findsOneWidget);
      expect(
        tester.getSize(find.byKey(AccountScreen.nameClearKey)),
        const Size(44, 44),
      );
    });

    testWidgets('Cancel restores the name without writing', (tester) async {
      final api = _NameApi();
      await _pump(
        tester,
        _Accounts(const AccountState(accounts: [_apple])),
        api: api,
      );
      await tester.tap(find.byKey(AccountScreen.nameRowKey));
      await tester.pumpAndSettle();
      await tester.enterText(field(), 'Somebody');
      await tester.tap(find.byKey(AccountScreen.nameCancelKey));
      await tester.pumpAndSettle();
      expect(field(), findsNothing);
      expect(find.text('Noble'), findsOneWidget);
      expect(api.writes, isEmpty);
    });

    testWidgets('the count shows from 30 and typing stops at 40', (
      tester,
    ) async {
      await _pump(tester, _Accounts(const AccountState(accounts: [_apple])));
      await tester.tap(find.byKey(AccountScreen.nameRowKey));
      await tester.pumpAndSettle();

      await tester.enterText(field(), 'a' * 29);
      await tester.pump();
      expect(find.textContaining(' of 40'), findsNothing);

      await tester.enterText(field(), 'a' * 34);
      await tester.pump();
      expect(find.text('34 of 40'), findsOneWidget);
      expect(find.text(AccountScreen.nameHint), findsOneWidget);
    });

    testWidgets('a longer paste is cut with the message, announced once', (
      tester,
    ) async {
      await _pump(tester, _Accounts(const AccountState(accounts: [_apple])));
      await tester.tap(find.byKey(AccountScreen.nameRowKey));
      await tester.pumpAndSettle();
      tester.takeAnnouncements();

      await tester.enterText(
        field(),
        'Oluwaseun Adaeze Okafor-Whitfield Balogun',
      );
      await tester.pump();
      expect(fieldText(tester), 'Oluwaseun Adaeze Okafor-Whitfield Balogu');
      expect(find.text('40 of 40'), findsOneWidget);
      expect(find.text(AccountScreen.nameCut), findsOneWidget);
      expect(find.text(AccountScreen.nameHint), findsNothing);

      // More typing does nothing and is not announced again.
      await tester.enterText(field(), '${fieldText(tester)}x');
      await tester.pump();
      expect(fieldText(tester), 'Oluwaseun Adaeze Okafor-Whitfield Balogu');
      expect(tester.takeAnnouncements().map((a) => a.message), [
        AccountScreen.nameCut,
      ]);
    });

    testWidgets('saving writes the normalised name, refreshes /me and '
        'announces it', (tester) async {
      var stored = 'Noble';
      final saving = Completer<void>();
      late _NameApi api;
      api = _NameApi(
        onWrite: (name) async {
          await saving.future;
          stored = name!;
        },
      );
      await _pump(
        tester,
        _Accounts(const AccountState(accounts: [_apple])),
        api: api,
        liveName: () => stored,
      );
      await tester.tap(find.byKey(AccountScreen.nameRowKey));
      await tester.pumpAndSettle();
      tester.takeAnnouncements();
      await tester.enterText(field(), '  Ada   Okafor ');
      await tester.tap(find.byKey(AccountScreen.nameSaveKey));
      await tester.pump();

      // Saving: read-only field, both actions off, no hint.
      expect(find.text(AccountScreen.nameSaving), findsOneWidget);
      expect(tester.widget<TextField>(field()).readOnly, isTrue);
      expect(
        _action(tester, AccountScreen.nameCancelKey.value).onPressed,
        isNull,
      );
      expect(find.text(AccountScreen.nameHint), findsNothing);

      saving.complete();
      await tester.pumpAndSettle();
      expect(api.writes, ['Ada Okafor']);
      expect(field(), findsNothing);
      expect(find.text('Ada Okafor'), findsOneWidget);
      expect(find.text(AccountScreen.editName), findsOneWidget);
      expect(
        tester.takeAnnouncements().map((a) => a.message),
        contains(AccountScreen.nameSaved),
      );
    });

    testWidgets('Done on the keyboard saves', (tester) async {
      final api = _NameApi();
      await _pump(
        tester,
        _Accounts(const AccountState(accounts: [_apple])),
        api: api,
      );
      await tester.tap(find.byKey(AccountScreen.nameRowKey));
      await tester.pumpAndSettle();
      await tester.enterText(field(), 'Ada');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(api.writes, ['Ada']);
    });

    testWidgets('blank saves remove the name', (tester) async {
      String? stored = 'Noble';
      final api = _NameApi(onWrite: (name) async => stored = name);
      await _pump(
        tester,
        _Accounts(const AccountState(accounts: [_apple])),
        api: api,
        liveName: () => (stored?.isEmpty ?? true) ? null : stored,
      );
      await tester.tap(find.byKey(AccountScreen.nameRowKey));
      await tester.pumpAndSettle();
      tester.takeAnnouncements();
      await tester.tap(find.byKey(AccountScreen.nameClearKey));
      await tester.pump();
      expect(fieldText(tester), isEmpty);
      await tester.enterText(field(), '   ');
      await tester.tap(find.byKey(AccountScreen.nameSaveKey));
      await tester.pumpAndSettle();

      expect(api.writes, ['']);
      expect(find.text(AccountScreen.unnamedListener), findsOneWidget);
      expect(find.text(AccountScreen.addName), findsOneWidget);
      expect(
        tester.takeAnnouncements().map((a) => a.message),
        contains(AccountScreen.nameRemoved),
      );
    });

    testWidgets('a failure keeps the text, offers Retry, and typing clears '
        'the error', (tester) async {
      var fail = true;
      final api = _NameApi(
        onWrite: (_) async {
          if (fail) throw AccountApiException(500, 'private', null);
        },
      );
      await _pump(
        tester,
        _Accounts(const AccountState(accounts: [_apple])),
        api: api,
      );
      await tester.tap(find.byKey(AccountScreen.nameRowKey));
      await tester.pumpAndSettle();
      tester.takeAnnouncements();
      await tester.enterText(field(), 'Ada');
      await tester.tap(find.byKey(AccountScreen.nameSaveKey));
      await tester.pumpAndSettle();

      expect(fieldText(tester), 'Ada');
      expect(find.text(AccountScreen.nameFailed), findsOneWidget);
      expect(find.text(AccountScreen.nameHint), findsNothing);
      expect(_action(tester, AccountScreen.nameSaveKey.value).label, 'Retry');
      expect(
        tester.takeAnnouncements().map((a) => a.message),
        contains(AccountScreen.nameFailed),
      );
      expect(find.textContaining('private'), findsNothing);

      await tester.enterText(field(), 'Adaa');
      await tester.pump();
      expect(find.text(AccountScreen.nameFailed), findsNothing);
      expect(find.text(AccountScreen.nameHint), findsOneWidget);
      expect(_action(tester, AccountScreen.nameSaveKey.value).label, 'Save');

      fail = false;
      await tester.tap(find.byKey(AccountScreen.nameSaveKey));
      await tester.pumpAndSettle();
      expect(api.writes, ['Ada', 'Adaa']);
      expect(field(), findsNothing);
    });

    testWidgets('large text on a narrow screen wraps instead of overflowing', (
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
        name: null,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(AccountScreen.nameRowKey));
      await tester.pumpAndSettle();
      await tester.enterText(field(), 'a' * 34);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(AccountScreen.nameSaveKey));
      await tester.pumpAndSettle();
      expect(
        find.byKey(AccountScreen.nameSaveKey).hitTestable(),
        findsOneWidget,
      );
    });

    testWidgets('the count is read by VoiceOver', (tester) async {
      final semantics = tester.ensureSemantics();
      await _pump(tester, _Accounts(const AccountState(accounts: [_apple])));
      await tester.tap(find.byKey(AccountScreen.nameRowKey));
      await tester.pumpAndSettle();
      await tester.enterText(field(), 'a' * 34);
      await tester.pump();
      expect(find.bySemanticsLabel('34 of 40'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('marked (composing) text is not counted or capped', (
      tester,
    ) async {
      await _pump(tester, _Accounts(const AccountState(accounts: [_apple])));
      await tester.tap(find.byKey(AccountScreen.nameRowKey));
      await tester.pumpAndSettle();
      await tester.enterText(field(), 'a' * 39);
      await tester.pump();
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: '${'a' * 39}にほん',
          selection: const TextSelection.collapsed(offset: 42),
          composing: const TextRange(start: 39, end: 42),
        ),
      );
      await tester.pump();
      expect(find.text('39 of 40'), findsOneWidget);
      expect(find.text(AccountScreen.nameHint), findsOneWidget);
      expect(find.text(AccountScreen.nameCut), findsNothing);
    });

    testWidgets('a 401 on save takes the session-expired path, not Retry', (
      tester,
    ) async {
      final api = _NameApi(
        onWrite: (_) async => throw AccountApiException(401, 'private', null),
      );
      final container = await _pump(
        tester,
        _Accounts(const AccountState(accounts: [_apple])),
        api: api,
      );
      await tester.tap(find.byKey(AccountScreen.nameRowKey));
      await tester.pumpAndSettle();
      await tester.enterText(field(), 'Ada');
      await tester.tap(find.byKey(AccountScreen.nameSaveKey));
      await tester.pumpAndSettle();

      expect(auth(container).signsOut, 1);
      expect(find.text(AccountScreen.nameFailed), findsNothing);
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('a 401 whose sign-out fails says the session expired and '
        'offers Sign in again', (tester) async {
      final api = _NameApi(
        onWrite: (_) async => throw AccountApiException(401, 'private', null),
      );
      final container = await _pump(
        tester,
        _Accounts(const AccountState(accounts: [_apple])),
        api: api,
      );
      auth(container).failSignOut = true;
      await tester.tap(find.byKey(AccountScreen.nameRowKey));
      await tester.pumpAndSettle();
      await tester.enterText(field(), 'Ada');
      await tester.tap(find.byKey(AccountScreen.nameSaveKey));
      await tester.pumpAndSettle();

      expect(find.text(AccountScreen.nameExpired), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(find.byKey(const Key('account-sign-out')), findsOneWidget);
    });

    testWidgets('leaving mid-save still refreshes /me for You and chat', (
      tester,
    ) async {
      var stored = 'Noble';
      final saving = Completer<void>();
      final api = _NameApi(
        onWrite: (name) async {
          await saving.future;
          stored = name!;
        },
      );
      final container = await _pump(
        tester,
        _Accounts(const AccountState(accounts: [_apple])),
        api: api,
        liveName: () => stored,
      );
      container.listen(accountNameProvider, (_, _) {});
      await tester.tap(find.byKey(AccountScreen.nameRowKey));
      await tester.pumpAndSettle();
      await tester.enterText(field(), 'Ada');
      await tester.tap(find.byKey(AccountScreen.nameSaveKey));
      await tester.pump();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: SizedBox()),
        ),
      );
      saving.complete();
      await tester.pumpAndSettle();
      expect(await container.read(accountNameProvider.future), 'Ada');
    });

    testWidgets('an unchanged name closes without a write', (tester) async {
      final api = _NameApi();
      await _pump(
        tester,
        _Accounts(const AccountState(accounts: [_apple])),
        api: api,
      );
      await tester.tap(find.byKey(AccountScreen.nameRowKey));
      await tester.pumpAndSettle();
      await tester.enterText(field(), ' Noble ');
      await tester.tap(find.byKey(AccountScreen.nameSaveKey));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
      expect(field(), findsNothing);
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
