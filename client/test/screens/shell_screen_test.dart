/// The four-tab shell (plan task 2.2; board → Dock, Conversation and
/// arrangement, Accessibility).
///
/// The native dock is faked at the channel: `TestDefaultBinaryMessengerBinding`
/// records what the shell sends and lets the test speak back as the dock.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/playlists/playlist_context_models.dart';
import 'package:mixtape/data/playback/listening_meter.dart';
import 'package:mixtape/data/playback/playback_controller.dart';
import 'package:mixtape/data/playback/player_bridge.dart';
import 'package:mixtape/data/shell/mini_player_state.dart';
import 'package:mixtape/data/shell/shell_channel.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';
import 'package:mixtape/presentation/providers/playback_provider.dart';
import 'package:mixtape/presentation/providers/shell_providers.dart';
import 'package:mixtape/presentation/screens/home_screen.dart';
import 'package:mixtape/presentation/screens/mixes_screen.dart';
import 'package:mixtape/presentation/screens/playback_screen.dart';
import 'package:mixtape/presentation/screens/shell/shell_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/frosted_dock.dart';
import 'package:mixtape/presentation/widgets/foundation/frosted_surface.dart';

import '../helpers/fake_listening_api.dart';
import '../data/playback/playback_controller_test.dart' show FakeApi, song;

TestDefaultBinaryMessenger get messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

/// Records the transport commands the mini-player's buttons ask for.
class RecordingBridge extends AppPlayerBridge {
  final commands = <String>[];
  final events = StreamController<PlayerSample>.broadcast();

  @override
  Stream<PlayerSample> get samples => events.stream;

  @override
  Future<void> start(List<String> ids) async {}

  @override
  Future<void> command(String action, {double? seconds}) async {
    commands.add(action);
  }
}

/// A DJ that answers the Mixes tab with nothing and refuses the rest.
class ShellDjApi implements DjApi {
  @override
  Duration get timeout => const Duration(seconds: 120);

  @override
  Future<List<DjSession>> listSessions() async => [];

  @override
  Future<void> recordPlaylistCreation(String sessionId, String appleId) async {}

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
  Future<void> postSessionEvent(String sessionId, String type) async {}

  @override
  Future<List<DjMemory>> listMemories() async => [];

  @override
  Future<void> deleteMemory(String id) => throw UnimplementedError();

  @override
  void close() {}
}

class TestAuth extends AuthNotifier {
  TestAuth(this._initial);
  final AuthStatus _initial;

  @override
  AuthStatus build() => _initial;

  void set(AuthStatus status) => state = status;
}

/// A mini-player the test drives by hand, so the channel assertions do not
/// depend on the real player's internals.
class FakeMiniPlayer extends MiniPlayerNotifier {
  @override
  MiniPlayerState build() => const MiniPlayerState.hidden();

  void emit(MiniPlayerState next) => state = next;
}

ProviderContainer shellContainer({
  bool nativeDock = false,
  AuthNotifier? auth,
  PlaybackController? player,
  bool fakeMiniPlayer = false,
}) {
  final container = ProviderContainer(
    overrides: [
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      djApiProvider.overrideWithValue(ShellDjApi()),
      listeningApiProvider.overrideWithValue(FakeListeningApi()),
      authProvider.overrideWith(() => auth ?? TestAuth(AuthStatus.signedIn)),
      nativeDockAvailableProvider.overrideWith((ref) => nativeDock),
      if (player != null) playbackProvider.overrideWithValue(player),
      if (fakeMiniPlayer)
        miniPlayerStateProvider.overrideWith(FakeMiniPlayer.new),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> pumpShell(
  WidgetTester tester,
  ProviderContainer container, {
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: brightness == Brightness.dark
            ? MixtapeTheme.dark()
            : MixtapeTheme.light(),
        home: const ShellScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Taps a tab on the Flutter dock, by its label inside the tab bar.
Future<void> tapDockTab(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(
      of: find.byKey(FrostedDock.tabBarKey),
      matching: find.text(label),
    ),
  );
  await tester.pumpAndSettle();
}

int stackIndex(WidgetTester tester) =>
    tester.widget<IndexedStack>(find.byKey(ShellScreen.tabStackKey)).index!;

/// A scroll gesture as the shell hears it, from inside the tab content.
void dispatchScroll(
  WidgetTester tester,
  ScrollDirection direction, {
  double maxScrollExtent = 1000,
  double pixels = 120,
}) {
  final context = tester.element(find.byKey(ShellScreen.tabStackKey));
  UserScrollNotification(
    metrics: FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: maxScrollExtent,
      pixels: pixels,
      viewportDimension: 600,
      axisDirection: AxisDirection.down,
      devicePixelRatio: 1,
    ),
    context: context,
    direction: direction,
  ).dispatch(context);
}

/// The Home tab's own navigator — the one a route pushed "inside a mix" goes
/// on, and what the dock's hide/show follows.
NavigatorState homeNavigator(WidgetTester tester) =>
    tabNavigator(tester, AppTab.home);

/// A tab's own navigator, found through its subtree key so it works for a tab
/// that is not the one up.
NavigatorState tabNavigator(WidgetTester tester, AppTab tab) =>
    tester.state<NavigatorState>(
      find.descendant(
        of: find.byKey(ShellScreen.tabKey(tab), skipOffstage: false),
        matching: find.byType(Navigator, skipOffstage: false),
      ),
    );

/// Pushes a route inside the Home tab and hands back that tab's navigator —
/// an opaque route takes the root off the tree, so the state has to be read
/// before the push, not after.
Future<NavigatorState> pushInsideTab(
  WidgetTester tester,
  String label, {
  AppTab tab = AppTab.home,
}) async {
  final navigator = tabNavigator(tester, tab);
  navigator.push(
    MaterialPageRoute<void>(builder: (_) => Scaffold(body: Text(label))),
  );
  await tester.pumpAndSettle();
  return navigator;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(ShellChannel.channelName);
  late List<MethodCall> calls;

  Future<void> fromDock(String method, [Object? arguments]) =>
      messenger.handlePlatformMessage(
        ShellChannel.channelName,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(method, arguments),
        ),
        (_) {},
      );

  List<MethodCall> callsTo(String method) =>
      calls.where((c) => c.method == method).toList();

  setUp(() {
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  /// The dock only exists on iOS, and `ShellChannel` asks
  /// `defaultTargetPlatform` rather than `Platform.isIOS` so a widget test can
  /// stand in for it. The override has to be undone inside the body: the
  /// framework checks the foundation debug flags before `tearDown` runs.
  void iosWidgets(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await body(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  group('tabs', () {
    iosWidgets('each tab shows its own root', (tester) async {
      await pumpShell(tester, shellContainer());

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(stackIndex(tester), AppTab.home.index);

      await tapDockTab(tester, 'Mixes');
      expect(stackIndex(tester), AppTab.mixes.index);
      expect(find.byType(MixesScreen), findsOneWidget);

      await tapDockTab(tester, 'Library');
      expect(stackIndex(tester), AppTab.library.index);
      expect(find.byKey(ShellScreen.tabKey(AppTab.library)), findsOneWidget);

      await tapDockTab(tester, 'You');
      expect(stackIndex(tester), AppTab.you.index);
      expect(find.byKey(ShellScreen.tabKey(AppTab.you)), findsOneWidget);

      // Every tab keeps its own navigator, alive across switches — the three
      // that are not up are offstage inside the stack, not gone.
      expect(
        find.byType(Navigator, skipOffstage: false),
        findsNWidgets(AppTab.values.length + 1),
      );
    });

    iosWidgets('tapping the tab already up leaves it where it is', (
      tester,
    ) async {
      await pumpShell(tester, shellContainer());

      // The Flutter dock is not drawn while a route sits above a tab root, so
      // pop-to-root on a re-tap is exercised through the dock's own
      // `tabChanged` below; from the root it is simply a no-op.
      await tapDockTab(tester, 'Home');

      expect(stackIndex(tester), AppTab.home.index);
      expect(find.byType(HomeScreen), findsOneWidget);
    });
  });

  group('Flutter dock', () {
    iosWidgets('a pushed route hides the dock and popping brings it back', (
      tester,
    ) async {
      await pumpShell(tester, shellContainer());
      expect(find.byType(FrostedDock), findsOneWidget);

      final navigator = await pushInsideTab(tester, 'inside a mix');

      expect(find.byType(FrostedDock), findsNothing);
      expect(callsTo('hide'), hasLength(1));

      navigator.pop();
      await tester.pumpAndSettle();

      expect(find.byType(FrostedDock), findsOneWidget);
      expect(callsTo('show'), isNotEmpty);
    });

    iosWidgets('a route on a tab that is not up leaves the dock alone', (
      tester,
    ) async {
      final container = shellContainer();
      await pumpShell(tester, container);
      calls.clear();

      await pushInsideTab(tester, 'a mix in Mixes', tab: AppTab.mixes);

      // Home is still up, and Home is at its root.
      expect(find.byType(FrostedDock), findsOneWidget);
      expect(callsTo('hide'), isEmpty);

      // Switching into that tab is where the dock goes away...
      container.read(selectedTabProvider.notifier).selectTab(AppTab.mixes);
      await tester.pumpAndSettle();
      expect(find.text('a mix in Mixes'), findsOneWidget);
      expect(find.byType(FrostedDock), findsNothing);
      expect(callsTo('hide'), hasLength(1));

      // ...and switching back to a tab at its root brings it back.
      container.read(selectedTabProvider.notifier).selectTab(AppTab.home);
      await tester.pumpAndSettle();
      expect(find.byType(FrostedDock), findsOneWidget);
      expect(callsTo('show'), isNotEmpty);
    });

    iosWidgets('system back pops the tab before it leaves the shell', (
      tester,
    ) async {
      await pumpShell(tester, shellContainer());
      await pushInsideTab(tester, 'inside a mix');
      expect(find.text('inside a mix'), findsOneWidget);

      // What the platform channel sends on an Android back press.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('inside a mix'), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(FrostedDock), findsOneWidget);
    });

    iosWidgets('no dock at all until the platform has answered', (
      tester,
    ) async {
      final availability = Completer<bool>();
      final container = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
          djApiProvider.overrideWithValue(ShellDjApi()),
          listeningApiProvider.overrideWithValue(FakeListeningApi()),
          authProvider.overrideWith(() => TestAuth(AuthStatus.signedIn)),
          nativeDockAvailableProvider.overrideWith(
            (ref) => availability.future,
          ),
        ],
      );
      addTearDown(container.dispose);
      await pumpShell(tester, container);

      // On iOS 26 a Flutter dock drawn for this frame would flash beside the
      // real one, so neither is drawn and nothing is said to the channel.
      expect(find.byType(FrostedDock), findsNothing);
      // Reading Reduce Transparency is not a dock command; nothing that would
      // move or populate the dock has been sent.
      expect(
        calls.map((call) => call.method),
        everyElement('getReduceTransparency'),
      );

      availability.complete(false);
      await tester.pumpAndSettle();

      expect(find.byType(FrostedDock), findsOneWidget);
      expect(callsTo('show'), isNotEmpty);
    });

    iosWidgets('no Flutter dock is drawn when the native dock is available', (
      tester,
    ) async {
      await pumpShell(tester, shellContainer(nativeDock: true));
      expect(find.byType(FrostedDock), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    iosWidgets('the dock leaves room for itself under the tab content', (
      tester,
    ) async {
      await pumpShell(tester, shellContainer());
      final media = MediaQuery.of(tester.element(find.byType(HomeScreen)));
      expect(media.padding.bottom, greaterThanOrEqualTo(kFrostedDockHeight));
    });
  });

  group('the native dock', () {
    iosWidgets('mounting shows the dock on the first tab', (tester) async {
      await pumpShell(tester, shellContainer(nativeDock: true));

      expect(callsTo('show'), isNotEmpty);
      expect(callsTo('setTab').first.arguments, AppTab.home.index);
    });

    iosWidgets('a tab change is pushed down and undoes the minimise', (
      tester,
    ) async {
      final container = shellContainer(nativeDock: true);
      await pumpShell(tester, container);
      dispatchScroll(tester, ScrollDirection.reverse);
      await tester.pumpAndSettle();
      expect(callsTo('setMinimized').last.arguments, true);
      calls.clear();

      container.read(selectedTabProvider.notifier).selectTab(AppTab.library);
      await tester.pumpAndSettle();

      expect(callsTo('setTab').last.arguments, AppTab.library.index);
      expect(callsTo('setMinimized').last.arguments, false);
    });

    iosWidgets('the resolved brightness is pushed down on every change', (
      tester,
    ) async {
      final container = shellContainer(nativeDock: true);
      await pumpShell(tester, container);
      expect(callsTo('setAppearance').last.arguments, false);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: MixtapeTheme.dark(),
            home: const ShellScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(callsTo('setAppearance').last.arguments, true);
    });

    iosWidgets('what plays is pushed into the mini-player as it changes', (
      tester,
    ) async {
      final container = shellContainer(nativeDock: true, fakeMiniPlayer: true);
      await pumpShell(tester, container);
      expect(callsTo('setMiniPlayer'), hasLength(1));

      (container.read(miniPlayerStateProvider.notifier) as FakeMiniPlayer).emit(
        const MiniPlayerState(
          visible: true,
          title: 'Song',
          artist: 'Artist',
          playing: true,
        ),
      );
      await tester.pumpAndSettle();

      final last = callsTo('setMiniPlayer').last.arguments as Map;
      expect(last['visible'], true);
      expect(last['title'], 'Song');
      expect(last['playing'], true);
    });

    iosWidgets('leaving the shell hides the dock', (tester) async {
      final container = shellContainer(nativeDock: true);
      await pumpShell(tester, container);
      calls.clear();

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: SizedBox()),
        ),
      );
      await tester.pumpAndSettle();

      expect(callsTo('hide'), isNotEmpty);
    });
  });

  group('scroll minimises the dock', () {
    iosWidgets('down minimises, up restores', (tester) async {
      await pumpShell(tester, shellContainer(nativeDock: true));
      calls.clear();

      dispatchScroll(tester, ScrollDirection.reverse);
      await tester.pumpAndSettle();
      expect(callsTo('setMinimized').last.arguments, true);

      dispatchScroll(tester, ScrollDirection.forward);
      await tester.pumpAndSettle();
      expect(callsTo('setMinimized').last.arguments, false);
    });

    iosWidgets('nothing to scroll keeps the dock at full size', (tester) async {
      await pumpShell(tester, shellContainer(nativeDock: true));
      calls.clear();

      dispatchScroll(
        tester,
        ScrollDirection.reverse,
        maxScrollExtent: 0,
        pixels: 0,
      );
      await tester.pumpAndSettle();
      expect(callsTo('setMinimized'), isEmpty);
    });

    iosWidgets('the Flutter dock minimises with the same state', (
      tester,
    ) async {
      await pumpShell(tester, shellContainer());

      dispatchScroll(tester, ScrollDirection.reverse);
      await tester.pumpAndSettle();
      expect(
        tester.widget<FrostedDock>(find.byType(FrostedDock)).minimized,
        isTrue,
      );

      dispatchScroll(tester, ScrollDirection.forward);
      await tester.pumpAndSettle();
      expect(
        tester.widget<FrostedDock>(find.byType(FrostedDock)).minimized,
        isFalse,
      );
    });
  });

  group('what the dock says back', () {
    iosWidgets('tabChanged switches tabs', (tester) async {
      final container = shellContainer(nativeDock: true);
      await pumpShell(tester, container);

      await fromDock('tabChanged', AppTab.mixes.index);
      await tester.pumpAndSettle();

      expect(container.read(selectedTabProvider), AppTab.mixes.index);
      expect(find.byType(MixesScreen), findsOneWidget);
    });

    iosWidgets('re-selecting the current tab pops it to its root', (
      tester,
    ) async {
      await pumpShell(tester, shellContainer(nativeDock: true));
      await pushInsideTab(tester, 'pushed');

      await fromDock('tabChanged', AppTab.home.index);
      await tester.pumpAndSettle();

      expect(find.text('pushed'), findsNothing);
    });

    iosWidgets('miniPlayerTapped opens Now Playing on the current tab', (
      tester,
    ) async {
      await pumpShell(tester, shellContainer(nativeDock: true));

      await fromDock('miniPlayerTapped');
      await tester.pumpAndSettle();

      expect(find.byType(PlaybackScreen), findsOneWidget);
    });

    iosWidgets('the transport buttons drive the app player', (tester) async {
      final bridge = RecordingBridge();
      final player = PlaybackController(FakeApi(), bridge)
        ..sessionId = 'mix'
        ..title = 'A mix'
        ..tracks = [song]
        ..sample = const PlayerSample(
          index: 0,
          positionMs: 0,
          status: 'playing',
        );
      await pumpShell(tester, shellContainer(nativeDock: true, player: player));

      await fromDock('miniPlayerPlayPause');
      await tester.pumpAndSettle();
      expect(bridge.commands, ['pause']);

      await fromDock('miniPlayerNext');
      await tester.pumpAndSettle();
      expect(bridge.commands, ['pause', 'next']);
    });

    iosWidgets('reduceTransparencyChanged makes the glass opaque', (
      tester,
    ) async {
      await pumpShell(tester, shellContainer(nativeDock: true));
      expect(
        FrostedSurfaceMode.of(
          tester.element(find.byType(HomeScreen)),
        ).reduceTransparency,
        isFalse,
      );

      await fromDock('reduceTransparencyChanged', true);
      await tester.pumpAndSettle();

      expect(
        FrostedSurfaceMode.of(
          tester.element(find.byType(HomeScreen)),
        ).reduceTransparency,
        isTrue,
      );
    });
  });

  group('providers', () {
    test('signing out resets the selected tab', () {
      final auth = TestAuth(AuthStatus.signedIn);
      final container = shellContainer(auth: auth);

      container.read(selectedTabProvider.notifier).selectTab(AppTab.you);
      expect(container.read(selectedTabProvider), AppTab.you.index);

      auth.set(AuthStatus.signedOut);
      expect(container.read(selectedTabProvider), AppTab.home.index);
    });

    test('the mini-player mirrors what the app player is on', () {
      final player = PlaybackController(FakeApi(), RecordingBridge())
        ..sessionId = 'mix'
        ..title = 'A mix'
        ..tracks = [song]
        ..sample = const PlayerSample(
          index: 0,
          positionMs: 0,
          status: 'playing',
        );
      final container = shellContainer(player: player);

      expect(
        container.read(miniPlayerStateProvider),
        const MiniPlayerState(
          visible: true,
          title: 'Song',
          artist: 'Artist',
          playing: true,
        ),
      );
    });

    test('nothing playing hides the mini-player', () {
      final player = PlaybackController(FakeApi(), RecordingBridge());
      final container = shellContainer(player: player);

      expect(
        container.read(miniPlayerStateProvider),
        const MiniPlayerState.hidden(),
      );
    });
  });
}
