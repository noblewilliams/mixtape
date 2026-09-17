// The You tab skeleton (plan `docs/superpowers/plans/2026-09-17-native-design-
// implementation.md` task 2.4): the identity block plus the inset-grouped rows
// that reach everything Home's menu offered about the listener — what the DJ
// knows, listening, suggestions, account and sign out.
//
// The hosted screens stay as they are; Phase 8 restyles them and adds the
// board's toggles.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/account_api.dart';
import 'package:mixtape/data/auth/google_auth_gateway.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/playback/playback_controller.dart';
import 'package:mixtape/data/playlists/playlist_context_models.dart';
import 'package:mixtape/data/suggestions/suggestions_api.dart';
import 'package:mixtape/presentation/providers/account_provider.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/playback_provider.dart';
import 'package:mixtape/presentation/providers/suggestions_provider.dart';
import 'package:mixtape/presentation/screens/account_screen.dart';
import 'package:mixtape/presentation/screens/memory_screen.dart';
import 'package:mixtape/presentation/screens/playback_screen.dart';
import 'package:mixtape/presentation/screens/tabs/you_tab.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/frosted_dock.dart'
    show kFrostedDockHeight;
import 'package:mixtape/presentation/widgets/foundation/inset_group.dart';

import '../data/playback/playback_controller_test.dart'
    show FakeApi, FakeBridge;

/// Records sign-outs and can fail one, the way account_screen_test's does.
class _Auth extends AuthNotifier {
  int signsOut = 0;
  bool failSignOut = false;

  /// Holds the sign-out open, so a second tap can be tried mid-flight.
  Completer<void>? gate;

  @override
  AuthStatus build() => AuthStatus.signedIn;

  @override
  Future<void> signOut() async {
    signsOut++;
    if (gate != null) await gate!.future;
    if (failSignOut) throw StateError('keychain unavailable');
    state = AuthStatus.signedOut;
  }
}

class _Accounts extends AccountNotifier {
  _Accounts(this.initial);
  final AccountState initial;

  @override
  AccountState build() => initial;
}

class _Google implements GoogleAuthGateway {
  @override
  bool get isAvailable => true;
  @override
  Future<String> getIdentityToken() async => 'identity';
}

/// The DJ's memory list only; every other call fails loudly.
class _DjApi implements DjApi {
  @override
  Duration get timeout => const Duration(seconds: 120);

  @override
  Future<List<DjMemory>> listMemories() async => const [];

  @override
  Future<void> deleteMemory(String id) async {}

  @override
  Future<void> recordPlaylistCreation(String sessionId, String appleId) async {}

  @override
  Future<List<DjSession>> listSessions() async => const [];

  @override
  Future<SessionDetail> createSession(
    String prompt, {
    InitialPlaylistSeed? playlistSeed,
  }) => throw UnimplementedError();

  @override
  Future<SessionDetail> getSession(String id) => throw UnimplementedError();

  @override
  Future<TurnResult> sendMessage(String id, String text) =>
      throw UnimplementedError();

  @override
  Future<QueueOpsResult> applyQueueOps(
    String id,
    List<QueueOp> ops,
    int? expectedVersion,
  ) => throw UnimplementedError();

  @override
  Future<DjSession> setStatus(String id, String status) =>
      throw UnimplementedError();

  @override
  Future<DjSession> renameSession(String id, String title) =>
      throw UnimplementedError();

  @override
  Future<void> postSessionEvent(String sessionId, String type) =>
      throw UnimplementedError();

  @override
  void close() {}
}

class _Suggestions implements SuggestionsApi {
  bool enabled = true;
  final List<bool> saves = [];
  Completer<SuggestionsData>? gate;

  @override
  Future<SuggestionsData> load(String zone) =>
      gate?.future ??
      Future.value(SuggestionsData(enabled: enabled, dismissed: false));

  @override
  Future<String> select(String id, String zone) => throw UnimplementedError();

  @override
  Future<void> dismiss(String id, String zone) async {}

  @override
  Future<void> save(bool value) async {
    saves.add(value);
    enabled = value;
  }
}

const _apple = LinkedAccount(
  id: 'a',
  accountId: 'apple-sub',
  providerId: 'apple',
);

ProviderContainer _container({
  _Auth? auth,
  String? name = 'Ada',
  AccountState accounts = const AccountState(accounts: [_apple]),
  _Suggestions? suggestions,
}) {
  final container = ProviderContainer(
    overrides: [
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      authProvider.overrideWith(() => auth ?? _Auth()),
      accountProvider.overrideWith(() => _Accounts(accounts)),
      accountNameProvider.overrideWith((ref) async => name),
      lastSignInProvider.overrideWith((_) async => AccountProvider.apple),
      googleAuthGatewayProvider.overrideWithValue(_Google()),
      djApiProvider.overrideWithValue(_DjApi()),
      playbackProvider.overrideWithValue(
        PlaybackController(FakeApi(), FakeBridge()),
      ),
      suggestionsApiProvider.overrideWithValue(suggestions ?? _Suggestions()),
      suggestionTimeZoneProvider.overrideWithValue(() async => 'UTC'),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  Brightness brightness = Brightness.light,
  Size size = const Size(390, 844),
  double textScale = 1,
  bool dockInset = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: brightness == Brightness.dark
            ? MixtapeTheme.dark()
            : MixtapeTheme.light(),
        home: Builder(
          builder: (context) {
            final media = MediaQuery.of(context);
            return MediaQuery(
              // `dockInset` stands in for the shell, which hands a tab root
              // the dock's own height as bottom padding (task 2.2).
              data: media.copyWith(
                textScaler: TextScaler.linear(textScale),
                padding: dockInset
                    ? media.padding.copyWith(bottom: kFrostedDockHeight)
                    : media.padding,
              ),
              child: const YouTab(),
            );
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpSettings(WidgetTester tester, SuggestionsApi api) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        suggestionsApiProvider.overrideWithValue(api),
        suggestionTimeZoneProvider.overrideWithValue(() async => 'UTC'),
      ],
      child: const MaterialApp(home: SuggestionSettingsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('chrome', () {
    for (final brightness in Brightness.values) {
      testWidgets('renders the title, the identity block and every row in '
          '${brightness.name}', (tester) async {
        await _pump(tester, _container(), brightness: brightness);

        expect(find.text('You'), findsOneWidget);
        expect(find.text('Ada'), findsOneWidget);
        expect(find.byKey(YouTab.avatarKey), findsOneWidget);
        expect(find.byType(InsetGroup), findsNWidgets(3));
        for (final key in const [
          'you-memories',
          'you-listening',
          'you-suggestions',
          'you-account',
          'you-signout',
        ]) {
          expect(find.byKey(Key(key)), findsOneWidget, reason: key);
        }
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('falls back to the placeholder name and the Account subtitle', (
      tester,
    ) async {
      await _pump(
        tester,
        _container(name: null, accounts: const AccountState()),
      );

      expect(find.text(YouTab.unnamedListener), findsOneWidget);
      expect(find.text('Account'), findsWidgets);
    });

    testWidgets('names the linked sign-in methods when they are known', (
      tester,
    ) async {
      await _pump(tester, _container());

      expect(find.text('Apple'), findsOneWidget);
    });

    testWidgets('leaves room under the groups for the floating dock', (
      tester,
    ) async {
      await _pump(tester, _container(), dockInset: true);

      // The dock's height arrives as MediaQuery padding from the shell, which
      // LargeTitleScaffold emits at the end of its slivers; the tab adds its
      // own row of breathing room on top, and never the dock again.
      final media = MediaQuery.of(tester.element(find.byType(YouTab)));
      expect(media.padding.bottom, kFrostedDockHeight);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SizedBox && widget.height == media.padding.bottom,
        ),
        findsWidgets,
        reason: "the scaffold ends on the dock's own height",
      );
      final bottoms = tester
          .widgetList<SliverPadding>(find.byType(SliverPadding))
          .map((padding) => padding.padding.resolve(TextDirection.ltr).bottom);
      expect(bottoms, contains(YouTab.defaultBottomInset));
      expect(
        media.padding.bottom + YouTab.defaultBottomInset,
        greaterThanOrEqualTo(kFrostedDockHeight + 16),
        reason: 'content has to clear the dock, once',
      );
    });

    testWidgets('wraps rather than overflows at 200% text on a 320 pt phone', (
      tester,
    ) async {
      await _pump(
        tester,
        _container(),
        size: const Size(320, 844),
        textScale: 2,
      );

      expect(find.text('You'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('routing', () {
    testWidgets('What the DJ knows opens the memory screen', (tester) async {
      await _pump(tester, _container());

      await tester.tap(find.byKey(const Key('you-memories')));
      await tester.pumpAndSettle();

      expect(find.byType(MemoryScreen), findsOneWidget);
    });

    testWidgets('Listening opens the listening preferences', (tester) async {
      await _pump(tester, _container());

      await tester.tap(find.byKey(const Key('you-listening')));
      await tester.pumpAndSettle();

      expect(find.byType(ListeningPreferencesScreen), findsOneWidget);
    });

    testWidgets('Suggestions opens the suggestion settings', (tester) async {
      await _pump(tester, _container());

      await tester.tap(find.byKey(const Key('you-suggestions')));
      await tester.pumpAndSettle();

      expect(find.byType(SuggestionSettingsScreen), findsOneWidget);
      expect(find.text('Suggest mixes from my routines'), findsOneWidget);
    });

    testWidgets('a saved suggestion setting writes through to the API', (
      tester,
    ) async {
      final suggestions = _Suggestions();
      await _pump(tester, _container(suggestions: suggestions));

      await tester.tap(find.byKey(const Key('you-suggestions')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SuggestionSettingsScreen.toggleKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SuggestionSettingsScreen.saveKey));
      await tester.pumpAndSettle();

      expect(suggestions.saves, [false]);
      expect(find.byType(SuggestionSettingsScreen), findsNothing);
    });

    testWidgets('an account change stops the settings screen saving', (
      tester,
    ) async {
      final mine = _Suggestions();
      await _pumpSettings(tester, mine);
      expect(find.byKey(SuggestionSettingsScreen.saveKey), findsOneWidget);

      // The account changed under the screen: suggestionsApiProvider hands
      // out a new API.
      final theirs = _Suggestions();
      await _pumpSettings(tester, theirs);

      expect(
        find.text(SuggestionSettingsScreen.accountChanged),
        findsOneWidget,
      );
      expect(find.byKey(SuggestionSettingsScreen.saveKey), findsNothing);
      expect(find.byKey(SuggestionSettingsScreen.toggleKey), findsNothing);
      expect(mine.saves, isEmpty);
      expect(theirs.saves, isEmpty);
    });

    testWidgets('Account opens the account screen', (tester) async {
      await _pump(tester, _container());

      await tester.tap(find.byKey(const Key('you-account')));
      await tester.pumpAndSettle();

      expect(find.byType(AccountScreen), findsOneWidget);
    });
  });

  group('sign out', () {
    testWidgets('signs the listener out', (tester) async {
      final auth = _Auth();
      await _pump(tester, _container(auth: auth));

      await tester.tap(find.byKey(const Key('you-signout')));
      await tester.pumpAndSettle();

      expect(auth.signsOut, 1);
    });

    testWidgets('cannot be fired twice while it is in flight', (tester) async {
      final auth = _Auth()..gate = Completer<void>();
      await _pump(tester, _container(auth: auth));

      await tester.tap(find.byKey(const Key('you-signout')));
      await tester.pump();
      // Disabled means the row drops its InkWell, so the second tap has
      // nothing to land on — which is the point.
      await tester.tap(
        find.byKey(const Key('you-signout')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(auth.signsOut, 1, reason: 'the row is disabled while awaiting');

      auth.gate!.complete();
      await tester.pumpAndSettle();
      expect(auth.signsOut, 1);
    });

    testWidgets('says so once when signing out fails', (tester) async {
      final auth = _Auth()..failSignOut = true;
      await _pump(tester, _container(auth: auth));

      await tester.tap(find.byKey(const Key('you-signout')));
      await tester.pumpAndSettle();

      expect(auth.signsOut, 1);
      expect(find.text(YouTab.signOutFailed), findsOneWidget);
    });
  });
}
