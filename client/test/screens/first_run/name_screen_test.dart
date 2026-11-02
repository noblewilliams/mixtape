// "What should we call you?" (2026-11-02 profile name, board frames N1 to
// N8; approval `docs/mockups/approved/2026-11-02-profile-name.md`).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/account_api.dart';
import 'package:mixtape/data/auth/name_page_store.dart';
import 'package:mixtape/presentation/providers/account_provider.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/capabilities_provider.dart';
import 'package:mixtape/presentation/providers/name_page_provider.dart';
import 'package:mixtape/presentation/screens/first_run/name_screen.dart';
import 'package:mixtape/presentation/screens/first_run/step_scaffold.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';

import 'first_run_harness.dart' show enabled, phone, reduceMotion;

class _Auth extends AuthNotifier {
  @override
  AuthStatus build() => AuthStatus.session;
  @override
  bool get isAnonymous => false;

  void become(AuthStatus next) => state = next;
}

class _Api implements AccountApi {
  bool fail = false;
  Completer<void>? gate;
  final writes = <String?>[];

  @override
  Future<void> updateUser({String? name}) async {
    writes.add(name);
    final hold = gate;
    if (hold != null) await hold.future;
    if (fail) throw AccountApiException(500, '', null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _shell = Key('shell');

class _Page {
  _Page({Me? first, this.store}) : _first = first ?? _ask;
  static const _ask = Me(id: 'u1', isAnonymous: false, askName: true);

  final Me _first;
  final api = _Api();
  final InMemoryNamePageStore? store;
  int reads = 0;
  Completer<Me?>? meGate;

  late final ProviderContainer container = () {
    final c = ProviderContainer(
      overrides: [
        authProvider.overrideWith(_Auth.new),
        accountApiProvider.overrideWithValue(api),
        namePageStoreProvider.overrideWithValue(
          store ?? InMemoryNamePageStore(),
        ),
        meProvider.overrideWith((ref) async {
          ref.watch(authProvider);
          final hold = meGate;
          if (hold != null) return hold.future;
          return ++reads == 1
              ? _first
              : const Me(id: 'u1', isAnonymous: false, name: 'Ada');
        }),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }();

  Future<void> pump(WidgetTester tester, {double scale = 1}) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: MixtapeTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: const NameGateView(child: Text('Shell', key: _shell)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}

Finder get _field => find.byKey(NameScreen.fieldKey);

TextField _textField(WidgetTester tester) => tester.widget<TextField>(_field);

TransportGlyph _glyph(WidgetTester tester) => tester.widget<TransportGlyph>(
  find.descendant(
    of: find.byKey(NameScreen.continueKey),
    matching: find.byType(TransportGlyph),
  ),
);

void main() {
  reduceMotion();

  testWidgets('N1: copy, no back, no autofocus, a dimmed Continue and Skip', (
    tester,
  ) async {
    phone(tester);
    final semantics = tester.ensureSemantics();
    await _Page().pump(tester);

    expect(find.text('What should we call you?'), findsOneWidget);
    expect(
      find.text('It shows in Account, and the DJ may use it now and then.'),
      findsOneWidget,
    );
    expect(find.text('Your name'), findsOneWidget);
    expect(find.byKey(TapeBackButton.defaultKey), findsNothing);
    expect(find.byKey(_shell), findsNothing);

    final background = tester.widget<Image>(
      find.byKey(StepScaffold.backgroundKey),
    );
    expect(
      (background.image as AssetImage).assetName,
      FirstRunBackground.signIn.asset,
    );

    final field = _textField(tester);
    expect(field.focusNode!.hasFocus, isFalse);
    expect(field.autofocus, isFalse);
    expect(field.keyboardAppearance, Brightness.dark);
    expect(field.textCapitalization, TextCapitalization.words);
    expect(field.autocorrect, isFalse);
    expect(field.autofillHints, contains(AutofillHints.name));
    expect(field.textInputAction, TextInputAction.done);

    expect(enabled(tester, NameScreen.continueKey), isFalse);
    expect(_glyph(tester).filled, isFalse);
    expect(
      tester.getSemantics(find.byKey(NameScreen.continueKey)),
      matchesSemantics(
        label: 'Continue',
        hint: 'Type a name.',
        isButton: true,
        hasEnabledState: true,
      ),
    );
    expect(find.text('Skip'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('N2: whitespace keeps Continue dimmed; a name turns it solid', (
    tester,
  ) async {
    phone(tester);
    await _Page().pump(tester);
    await tester.enterText(_field, '   ');
    await tester.pump();
    expect(enabled(tester, NameScreen.continueKey), isFalse);

    await tester.enterText(_field, 'Ada');
    await tester.pump();
    expect(enabled(tester, NameScreen.continueKey), isTrue);
    expect(_glyph(tester).filled, isTrue);
  });

  testWidgets('N3: Continue saves the normalised name, shows Saving, then '
      'the shell; the device is settled', (tester) async {
    phone(tester);
    final store = InMemoryNamePageStore();
    final page = _Page(store: store)..api.gate = Completer<void>();
    await page.pump(tester);
    tester.takeAnnouncements();

    await tester.enterText(_field, '  Ada   Okafor ');
    await tester.pump();
    await tester.tap(find.byKey(NameScreen.continueKey));
    await tester.pump();

    expect(find.text('Saving'), findsOneWidget);
    expect(_textField(tester).readOnly, isTrue);
    expect(find.text('Skip'), findsOneWidget);
    expect(tester.takeAnnouncements().map((a) => a.message), ['Saving']);

    page.api.gate!.complete();
    await tester.pumpAndSettle();
    expect(page.api.writes, ['Ada Okafor']);
    expect(page.reads, 2);
    expect(find.byKey(_shell), findsOneWidget);
    expect(await store.read(), isTrue);
  });

  testWidgets('Done on the keyboard acts as Continue', (tester) async {
    phone(tester);
    final page = _Page();
    await page.pump(tester);
    await tester.enterText(_field, 'Ada');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(page.api.writes, ['Ada']);
    expect(find.byKey(_shell), findsOneWidget);
  });

  testWidgets('Done with a blank field does nothing', (tester) async {
    phone(tester);
    final page = _Page();
    await page.pump(tester);
    await tester.enterText(_field, '  ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(page.api.writes, isEmpty);
    expect(find.byKey(_shell), findsNothing);
  });

  testWidgets('N4: a failed save keeps the text, says so and offers Retry', (
    tester,
  ) async {
    phone(tester);
    final page = _Page()..api.fail = true;
    await page.pump(tester);
    tester.takeAnnouncements();
    await tester.enterText(_field, 'Ada Okafor');
    await tester.pump();
    await tester.tap(find.byKey(NameScreen.continueKey));
    await tester.pumpAndSettle();

    expect(_textField(tester).controller!.text, 'Ada Okafor');
    expect(_textField(tester).readOnly, isFalse);
    expect(find.text('Couldn’t save your name.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Continue'), findsNothing);
    expect(
      tester.takeAnnouncements().map((a) => a.message),
      containsAllInOrder(['Saving', 'Couldn’t save your name.']),
    );
    expect(find.byKey(_shell), findsNothing);

    page.api.fail = false;
    await tester.tap(find.byKey(NameScreen.continueKey));
    await tester.pumpAndSettle();
    expect(page.api.writes, ['Ada Okafor', 'Ada Okafor']);
    expect(find.byKey(_shell), findsOneWidget);
  });

  testWidgets('typing after a failure clears the error', (tester) async {
    phone(tester);
    final page = _Page()..api.fail = true;
    await page.pump(tester);
    await tester.enterText(_field, 'Ada');
    await tester.pump();
    await tester.tap(find.byKey(NameScreen.continueKey));
    await tester.pumpAndSettle();
    expect(find.text('Couldn’t save your name.'), findsOneWidget);
    await tester.enterText(_field, 'Adaeze');
    await tester.pump();
    expect(find.text('Couldn’t save your name.'), findsNothing);
    expect(find.text('Continue'), findsOneWidget);
  });

  testWidgets('Skip records the flag and moves on, even when it fails', (
    tester,
  ) async {
    phone(tester);
    final page = _Page()..api.fail = true;
    await page.pump(tester);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(page.api.writes, [null]);
    expect(find.byKey(_shell), findsOneWidget);
  });

  testWidgets('Skip is off while a save is in flight', (tester) async {
    phone(tester);
    final page = _Page()..api.gate = Completer<void>();
    await page.pump(tester);
    await tester.enterText(_field, 'Ada');
    await tester.pump();
    await tester.tap(find.byKey(NameScreen.continueKey));
    await tester.pump();
    final skip = tester.widget<TextButton>(
      find.ancestor(of: find.text('Skip'), matching: find.byType(TextButton)),
    );
    expect(skip.onPressed, isNull);
    page.api.gate!.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('N5: a longer paste is cut at 40 with the line and the count, '
      'announced once', (tester) async {
    phone(tester);
    await _Page().pump(tester);
    tester.takeAnnouncements();
    await tester.enterText(_field, 'Oluwaseun Adaeze Okafor-Whitfield Balogun');
    await tester.pump();
    expect(
      _textField(tester).controller!.text,
      'Oluwaseun Adaeze Okafor-Whitfield Balogu',
    );
    expect(find.text('40 of 40'), findsOneWidget);
    expect(find.text('Names stop at 40 characters.'), findsOneWidget);
    await tester.enterText(_field, '${_textField(tester).controller!.text}x');
    await tester.pump();
    expect(tester.takeAnnouncements().map((a) => a.message), [
      'Names stop at 40 characters.',
    ]);
  });

  testWidgets('the count appears from 30 characters', (tester) async {
    phone(tester);
    await _Page().pump(tester);
    await tester.enterText(_field, 'a' * 29);
    await tester.pump();
    expect(find.text('29 of 40'), findsNothing);
    await tester.enterText(_field, 'a' * 30);
    await tester.pump();
    expect(find.text('30 of 40'), findsOneWidget);
  });

  testWidgets('N6: 200% text at 320 pt scrolls, with Skip after the pill', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final page = _Page()..api.fail = true;
    await page.pump(tester, scale: 2);
    expect(tester.takeException(), isNull);

    await tester.enterText(_field, 'Oluwaseun Adaeze Okafor-Whitfield Balogun');
    await tester.pump();
    await tester.ensureVisible(find.byKey(NameScreen.continueKey));
    await tester.tap(find.byKey(NameScreen.continueKey));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Couldn’t save your name.'), findsOneWidget);

    await tester.ensureVisible(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('Skip')).dy,
      greaterThan(tester.getBottomLeft(find.byKey(NameScreen.continueKey)).dy),
    );
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(find.byKey(_shell), findsOneWidget);
  });

  group('NameGateView', () {
    testWidgets('a hung /me holds the image for 3.5 s, then the shell; a '
        'late ask still opens the page', (tester) async {
      phone(tester);
      final page = _Page()..meGate = Completer<Me?>();
      await page.pump(tester);
      expect(find.byKey(NamePageHold.holdKey), findsOneWidget);
      // The launch settle above already spent part of the 3.5 s.
      await tester.pump(const Duration(milliseconds: 2500));
      expect(find.byKey(NamePageHold.holdKey), findsOneWidget);
      expect(find.byKey(_shell), findsNothing);
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pumpAndSettle();
      expect(find.byKey(_shell), findsOneWidget);
      expect(find.byKey(NamePageHold.holdKey), findsNothing);

      page.meGate!.complete(_Page._ask);
      await tester.pumpAndSettle();
      expect(find.text('What should we call you?'), findsOneWidget);
    });

    testWidgets('a stale answer carried across an auth change never settles '
        'the device for the next account', (tester) async {
      phone(tester);
      final store = InMemoryNamePageStore();
      final page = _Page(
        first: const Me(id: 'u1', isAnonymous: false, name: 'Ada'),
        store: store,
      );
      await page.pump(tester);
      expect(await store.read(), isTrue);

      // The next account: the sign-in resets the flag, /me is slow.
      final auth = page.container.read(authProvider.notifier) as _Auth;
      auth.become(AuthStatus.noSession);
      await tester.pump();
      page.container.read(namePageSettledProvider.notifier).reset();
      page.meGate = Completer<Me?>();
      auth.become(AuthStatus.session);
      await tester.pump();
      // Past the cross-fade from the signed-out frame (in the app that root
      // is the first-run flow, not this gate).
      await tester.pump(const Duration(milliseconds: 300));
      expect(page.container.read(namePageSettledProvider), isFalse);
      expect(await store.read(), isFalse);
      expect(find.byKey(NamePageHold.holdKey), findsOneWidget);
      expect(find.byKey(_shell), findsNothing);
      page.meGate!.complete(_Page._ask);
      await tester.pumpAndSettle();
    });

    testWidgets('holds on the sign-in image while /me answers, then asks', (
      tester,
    ) async {
      phone(tester);
      final page = _Page()..meGate = Completer<Me?>();
      await page.pump(tester);
      expect(find.byKey(NamePageHold.holdKey), findsOneWidget);
      expect(find.text('What should we call you?'), findsNothing);
      expect(find.byKey(_shell), findsNothing);

      page.meGate!.complete(_Page._ask);
      await tester.pumpAndSettle();
      expect(find.text('What should we call you?'), findsOneWidget);
    });

    testWidgets('a named account goes to the shell and settles the device', (
      tester,
    ) async {
      phone(tester);
      final store = InMemoryNamePageStore();
      await _Page(
        first: const Me(id: 'u1', isAnonymous: false, name: 'Ada'),
        store: store,
      ).pump(tester);
      expect(find.byKey(_shell), findsOneWidget);
      expect(find.text('What should we call you?'), findsNothing);
      expect(await store.read(), isTrue);
    });

    testWidgets('a settled device shows the shell while /me answers', (
      tester,
    ) async {
      phone(tester);
      final page = _Page(store: InMemoryNamePageStore(settled: true))
        ..meGate = Completer<Me?>();
      await page.pump(tester);
      expect(find.byKey(_shell), findsOneWidget);
      expect(find.byKey(NamePageHold.holdKey), findsNothing);
    });
  });
}
