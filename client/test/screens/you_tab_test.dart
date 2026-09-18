// The You tab (plan `docs/superpowers/plans/2026-09-17-native-design-
// implementation.md` task 8.3; board frame Y1): the identity block, What the
// DJ knows with its count, the board's two real toggles, the Together ghost,
// Account and Sign out.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/account_api.dart';
import 'package:mixtape/data/auth/google_auth_gateway.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/playback/playback_api.dart';
import 'package:mixtape/data/playback/playback_controller.dart';
import 'package:mixtape/data/playlists/playlist_context_models.dart';
import 'package:mixtape/data/suggestions/suggestions_api.dart';
import 'package:mixtape/presentation/providers/account_provider.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';
import 'package:mixtape/presentation/providers/playback_provider.dart';
import 'package:mixtape/presentation/providers/suggestions_provider.dart';
import 'package:mixtape/presentation/screens/account_screen.dart';
import 'package:mixtape/presentation/screens/memory_screen.dart';
import 'package:mixtape/presentation/screens/tabs/you_tab.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/frosted_dock.dart'
    show kFrostedDockHeight;
import 'package:mixtape/presentation/widgets/foundation/inset_group.dart';
import 'package:mixtape/presentation/widgets/suggestion_settings.dart';

import '../data/playback/playback_controller_test.dart'
    show FakeApi, FakeBridge;
import '../helpers/fake_listening_api.dart';
import '../presentation/widgets/suggestion_settings_test.dart'
    show FakeSuggestionsApi;

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
  _DjApi({this.memories = const []});

  final List<DjMemory> memories;

  @override
  Duration get timeout => const Duration(seconds: 120);

  @override
  Future<List<DjMemory>> listMemories() async => memories;

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

/// Answers the preferences read but refuses the write, so a failed save can
/// be retried.
class _FailingPlaybackApi implements PlaybackApi {
  bool failSave = true;
  bool enabled = true;
  int saves = 0;

  @override
  ApiClient get client => throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> preferences() async => {
    'enabled': enabled,
    'revision': 1,
    'userId': 'owner',
  };

  @override
  Future<Map<String, dynamic>> save(bool value) async {
    saves++;
    if (failSave) throw StateError('offline');
    enabled = value;
    return preferences();
  }

  @override
  Future<Map<String, dynamic>> clear(String id, int revision) =>
      throw UnimplementedError();

  @override
  Future<void> send(int revision, List<Map<String, dynamic>> events) async {}
}

/// Never answers `GET /me/playback/preferences`, so the learning setting
/// stays unknown for as long as the test needs it.
class _PendingPlaybackApi implements PlaybackApi {
  final _held = Completer<Map<String, dynamic>>();

  @override
  ApiClient get client => throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> preferences() => _held.future;

  @override
  Future<Map<String, dynamic>> save(bool value) => throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> clear(String id, int revision) =>
      throw UnimplementedError();

  @override
  Future<void> send(int revision, List<Map<String, dynamic>> events) async {}
}

DjMemory _memory(String id) =>
    DjMemory(id: id, note: 'note $id', createdAt: DateTime.now());

/// Which suggestions API the provider hands out; swapping it is an account
/// change under a live toggle.
class _ApiSlot {
  _ApiSlot(this.api);
  SuggestionsApi api;
}

late _ApiSlot _slot;

ProviderContainer _container({
  _Auth? auth,
  String? name = 'Ada',
  AccountState accounts = const AccountState(accounts: [_apple]),
  FakeSuggestionsApi? suggestions,
  PlaybackController? player,
  List<DjMemory> memories = const [],
  String? chosenService = 'apple',
}) {
  _slot = _ApiSlot(suggestions ?? FakeSuggestionsApi());
  final container = ProviderContainer(
    overrides: [
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      authProvider.overrideWith(() => auth ?? _Auth()),
      accountProvider.overrideWith(() => _Accounts(accounts)),
      accountNameProvider.overrideWith((ref) async => name),
      lastSignInProvider.overrideWith((_) async => AccountProvider.apple),
      googleAuthGatewayProvider.overrideWithValue(_Google()),
      djApiProvider.overrideWithValue(_DjApi(memories: memories)),
      listeningApiProvider.overrideWithValue(
        FakeListeningApi(
          onboarding: onboardingState(chosenService: chosenService),
        ),
      ),
      playbackProvider.overrideWithValue(
        player ?? PlaybackController(FakeApi(), FakeBridge()),
      ),
      suggestionsApiProvider.overrideWith((ref) => _slot.api),
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

Switch _switchAt(WidgetTester tester, Key key) =>
    tester.widget<Switch>(find.byKey(key));

const _learningSwitch = Key('you-learning-switch');

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('chrome', () {
    for (final brightness in Brightness.values) {
      testWidgets('renders the title, the identity block and every row in '
          '${brightness.name}', (tester) async {
        await _pump(tester, _container(), brightness: brightness);

        expect(find.text('You'), findsOneWidget);
        expect(find.text('Ada'), findsOneWidget);
        expect(find.byKey(YouTab.avatarKey), findsOneWidget);
        expect(find.text('A'), findsOneWidget, reason: 'the avatar initial');
        expect(
          find.byType(InsetGroup),
          findsNWidgets(4),
          reason: 'identity, toggles, the Together ghost, account',
        );
        for (final key in const [
          'you-memories',
          'you-learning-switch',
          'you-suggestions-switch',
          'you-together',
          'you-account',
          'you-signout',
        ]) {
          expect(find.byKey(Key(key)), findsOneWidget, reason: key);
        }
        expect(find.text('Learn from my listening'), findsOneWidget);
        expect(find.text(SuggestionSettings.title), findsOneWidget);
        expect(find.text(YouTab.learningFootnote), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('names the linked methods and the music service', (
      tester,
    ) async {
      await _pump(
        tester,
        _container(
          accounts: const AccountState(accounts: [_apple, _google]),
        ),
      );

      expect(
        find.text('Apple and Google sign-in · Apple Music'),
        findsOneWidget,
      );
    });

    testWidgets('falls back to the placeholder name and a plain subtitle', (
      tester,
    ) async {
      await _pump(
        tester,
        _container(
          name: null,
          accounts: const AccountState(),
          chosenService: null,
        ),
      );

      expect(find.text(YouTab.unnamedListener), findsOneWidget);
      expect(find.text('Account'), findsWidgets);
    });

    testWidgets('counts the remembered preferences once they load', (
      tester,
    ) async {
      await _pump(
        tester,
        _container(memories: [_memory('a'), _memory('b'), _memory('c')]),
      );

      expect(find.text('3 remembered preferences'), findsOneWidget);
    });

    test('the remembered line stays silent until the notes load', () {
      expect(YouTab.rememberedLine(null), isNull);
      expect(YouTab.rememberedLine(0), 'Nothing remembered yet');
      expect(YouTab.rememberedLine(1), '1 remembered preference');
      expect(YouTab.rememberedLine(7), '7 remembered preferences');
    });

    test('the identity subtitle drops what it does not know', () {
      expect(
        YouTab.identitySubtitle(null, null),
        'Account',
        reason: 'unknown is not "no methods"',
      );
      expect(
        YouTab.identitySubtitle(const [_apple], null),
        'Apple sign-in',
      );
      expect(
        YouTab.identitySubtitle(null, onboardingState(chosenService: 'apple')),
        'Apple Music',
      );
    });

    testWidgets('leaves room under the groups for the floating dock', (
      tester,
    ) async {
      await _pump(tester, _container(), dockInset: true);

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

  group('toggles', () {
    testWidgets('the listening switch reflects and writes the setting', (
      tester,
    ) async {
      final api = FakeApi();
      final player = PlaybackController(api, FakeBridge());
      addTearDown(player.dispose);
      await _pump(tester, _container(player: player));

      expect(_switchAt(tester, _learningSwitch).value, isTrue);
      await tester.tap(find.byKey(_learningSwitch));
      await tester.pumpAndSettle();

      expect(api.enabled, isFalse);
      expect(_switchAt(tester, _learningSwitch).value, isFalse);
    });

    testWidgets('the listening switch is muted while the setting is unknown', (
      tester,
    ) async {
      final player = PlaybackController(_PendingPlaybackApi(), FakeBridge());
      addTearDown(player.dispose);
      await _pump(tester, _container(player: player));

      expect(_switchAt(tester, _learningSwitch).onChanged, isNull);
      expect(_switchAt(tester, _learningSwitch).value, isFalse);
      expect(find.text('Not available right now'), findsOneWidget);
    });

    testWidgets('a failed listening save says so and stays retryable', (
      tester,
    ) async {
      final api = _FailingPlaybackApi();
      final player = PlaybackController(api, FakeBridge());
      addTearDown(player.dispose);
      await _pump(tester, _container(player: player));

      await tester.tap(find.byKey(_learningSwitch));
      await tester.pumpAndSettle();

      expect(api.saves, 1);
      expect(
        find.text('Could not save. Collection is paused until you try again.'),
        findsOneWidget,
      );
      expect(
        _switchAt(tester, _learningSwitch).value,
        isTrue,
        reason: 'the canonical setting was read back',
      );
      expect(
        _switchAt(tester, _learningSwitch).onChanged,
        isNotNull,
        reason: 'a failed save must stay retryable',
      );

      api.failSave = false;
      await tester.tap(find.byKey(_learningSwitch));
      await tester.pumpAndSettle();

      expect(api.saves, 2);
      expect(_switchAt(tester, _learningSwitch).value, isFalse);
    });

    testWidgets('the suggestions switch reflects and writes the setting', (
      tester,
    ) async {
      final suggestions = FakeSuggestionsApi();
      await _pump(tester, _container(suggestions: suggestions));

      expect(
        _switchAt(tester, SuggestionSettings.switchKey).value,
        isTrue,
      );
      await tester.tap(find.byKey(SuggestionSettings.switchKey));
      await tester.pumpAndSettle();

      expect(suggestions.saves, [false]);
    });

    testWidgets('the suggestions switch refuses to write after an account '
        'change', (tester) async {
      final mine = FakeSuggestionsApi();
      final container = _container(suggestions: mine);
      await _pump(tester, container);

      final theirs = FakeSuggestionsApi();
      _slot.api = theirs;
      container.invalidate(suggestionsApiProvider);
      await tester.pumpAndSettle();

      expect(find.text(SuggestionSettings.accountChanged), findsOneWidget);
      expect(
        _switchAt(tester, SuggestionSettings.switchKey).onChanged,
        isNull,
      );
      await tester.tap(
        find.byKey(SuggestionSettings.switchKey),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(mine.saves, isEmpty);
      expect(theirs.saves, isEmpty);
    });
  });

  group('Together', () {
    testWidgets('is a labelled ghost and takes no tap', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, _container());

      expect(find.text('Together'), findsOneWidget);
      expect(find.bySemanticsLabel(YouTab.togetherLabel), findsOneWidget);
      final node = tester.getSemantics(
        find.bySemanticsLabel(YouTab.togetherLabel),
      );
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
      expect(find.byType(InkWell), findsWidgets);
      handle.dispose();
    });
  });

  group('routing', () {
    testWidgets('What the DJ knows opens the memory screen', (tester) async {
      await _pump(tester, _container());

      await tester.tap(find.byKey(const Key('you-memories')));
      await tester.pumpAndSettle();

      expect(find.byType(MemoryScreen), findsOneWidget);
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
