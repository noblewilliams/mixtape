// The first-run flow at the root: gating, the hand-off to the shell, and the
// Library add flow (first-run spec → Account model "Gating", Clients).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/data/playback/playback_controller.dart';
import 'package:mixtape/data/settings/author_store.dart';
import 'package:mixtape/main.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/first_run_provider.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/playback_provider.dart';
import 'package:mixtape/presentation/screens/chat_screen.dart';
import 'package:mixtape/presentation/screens/first_run/artists_screen.dart';
import 'package:mixtape/presentation/screens/first_run/choose_method_screen.dart';
import 'package:mixtape/presentation/screens/first_run/choose_service_screen.dart';
import 'package:mixtape/presentation/screens/first_run/doing_screen.dart';
import 'package:mixtape/presentation/screens/first_run/first_run_flow.dart';
import 'package:mixtape/presentation/screens/first_run/welcome_screen.dart';
import 'package:mixtape/presentation/screens/home_screen.dart';
import 'package:mixtape/presentation/screens/shell/shell_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/mix_energy_summary.dart';

import '../../data/playback/playback_controller_test.dart'
    as playback
    show FakeApi, FakeBridge;
import '../../helpers/fake_bridge.dart' show FakeBridge;
import 'first_run_harness.dart';

ProviderContainer _container(FirstRunHarness h) {
  final c = ProviderContainer(
    overrides: [
      ...h.overrides,
      // The conversation the shell opens reaches MusicKit, the keychain,
      // GET /me and the player; none of that is under test here.
      musicKitBridgeProvider.overrideWithValue(FakeBridge(const [])),
      authorStoreProvider.overrideWithValue(InMemoryAuthorStore()),
      accountNameProvider.overrideWith((ref) async => null),
      mixEnergyProvider.overrideWith((ref, key) async => <String, dynamic>{}),
      playbackProvider.overrideWithValue(
        PlaybackController(playback.FakeApi(), playback.FakeBridge()),
      ),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

Future<ProviderContainer> _pumpApp(
  WidgetTester tester,
  FirstRunHarness h,
) async {
  phone(tester);
  final container = _container(h);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const MixtapeApp()),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _enterArtists(WidgetTester tester) async {
  for (final (i, name) in [(0, 'Burna Boy'), (1, 'Tems'), (2, 'Sade')]) {
    await tester.enterText(find.byKey(ArtistsScreen.fieldKey(i)), name);
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();
  }
}

void main() {
  reduceMotion();

  testWidgets('no session at launch: the flow opens on Welcome', (
    tester,
  ) async {
    final h = FirstRunHarness();
    final c = await _pumpApp(tester, h);

    expect(find.byType(FirstRunFlow), findsOneWidget);
    expect(find.byType(WelcomeScreen), findsOneWidget);
    expect(find.byType(ShellScreen), findsNothing);
    expect(c.read(firstRunActiveProvider), isTrue);
  });

  testWidgets('path A: the anonymous session appears mid-flow without '
      'leaving it; the mix hands off to the shell, which opens it', (
    tester,
  ) async {
    final h = FirstRunHarness();
    final saving = Completer<List<ArtistSeed>>();
    h.listening.onPutArtistSeeds = (_) => saving.future;
    final c = await _pumpApp(tester, h);

    await tester.enterText(find.byKey(const Key('prompt-field')), 'rainy');
    await tester.pump();
    await tester.tap(find.byKey(const Key('start-session')));
    await tester.pumpAndSettle();
    expect(find.byType(ArtistsScreen), findsOneWidget);

    await _enterArtists(tester);
    await tester.tap(find.byKey(ArtistsScreen.continueKey));
    await tester.pumpAndSettle();

    // Signed in anonymously, seeds still saving: the flow stays mounted.
    expect(h.auth.anonymousSignIns, 1);
    expect(c.read(authProvider), AuthStatus.session);
    expect(c.read(isAnonymousProvider), isTrue);
    expect(find.byType(ArtistsScreen), findsOneWidget);
    expect(find.byType(ShellScreen), findsNothing);

    saving.complete(const []);
    await tester.pumpAndSettle();

    expect(h.listening.putSeeds, [
      ['Burna Boy', 'Tems', 'Sade'],
    ]);
    expect(h.dj.prompts, ['rainy']);
    expect(h.auth.anonymousSignIns, 1);
    expect(c.read(firstRunActiveProvider), isFalse);
    expect(find.byType(FirstRunFlow), findsNothing);
    expect(find.byType(ShellScreen), findsOneWidget);
    expect(
      tester.widget<ChatScreen>(find.byType(ChatScreen)).sessionId,
      'session-new',
    );
    expect(c.read(pendingConversationProvider), isNull, reason: 'taken once');

    // Back from the mix lands on Home.
    await tester.tap(find.byKey(const Key('chat-back')));
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('signed in with an account, then signed out: the flow comes '
      'back, stays mounted through the anonymous sign-in and hands off once', (
    tester,
  ) async {
    final h = FirstRunHarness(status: AuthStatus.session);
    final saving = Completer<List<ArtistSeed>>();
    h.listening.onPutArtistSeeds = (_) => saving.future;
    final c = await _pumpApp(tester, h);
    expect(find.byType(ShellScreen), findsOneWidget);
    expect(c.read(firstRunActiveProvider), isFalse);

    await c.read(authProvider.notifier).signOut();
    await tester.pumpAndSettle();
    expect(find.byType(WelcomeScreen), findsOneWidget);
    expect(c.read(firstRunActiveProvider), isTrue);

    await tester.enterText(find.byKey(const Key('prompt-field')), 'late');
    await tester.pump();
    await tester.tap(find.byKey(const Key('start-session')));
    await tester.pumpAndSettle();
    await _enterArtists(tester);
    await tester.tap(find.byKey(ArtistsScreen.continueKey));
    await tester.pumpAndSettle();

    expect(c.read(authProvider), AuthStatus.session);
    expect(c.read(isAnonymousProvider), isTrue);
    expect(find.byType(ArtistsScreen), findsOneWidget);
    expect(find.byType(ShellScreen), findsNothing);

    saving.complete(const []);
    await tester.pumpAndSettle();

    expect(h.auth.anonymousSignIns, 1);
    expect(h.dj.prompts, ['late']);
    expect(c.read(firstRunActiveProvider), isFalse);
    expect(find.byType(ShellScreen), findsOneWidget);
    expect(find.byType(ChatScreen), findsOneWidget);
    expect(find.byType(FirstRunFlow), findsNothing);
  });

  testWidgets('an anonymous session present at launch opens the shell', (
    tester,
  ) async {
    final h = FirstRunHarness(status: AuthStatus.session, anonymous: true);
    final c = await _pumpApp(tester, h);

    expect(find.byType(FirstRunFlow), findsNothing);
    expect(find.byType(ShellScreen), findsOneWidget);
    expect(c.read(firstRunActiveProvider), isFalse);
  });

  testWidgets('Library add flow: Step 1 to Step 3 and back to Library on '
      'Done, never to the prompt page', (tester) async {
    final h = FirstRunHarness(status: AuthStatus.session);
    phone(tester);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp(
          theme: MixtapeTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  key: const Key('library-add'),
                  onPressed: () => openAddMusic(context),
                  child: const Text('Library'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('library-add')));
    await tester.pumpAndSettle();
    expect(find.byType(ChooseServiceScreen), findsOneWidget);
    expect(find.byKey(ChooseServiceScreen.skipKey), findsNothing);

    await tester.tap(find.byKey(ChooseServiceScreen.appleKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ChooseMethodScreen.appleSyncKey));
    await tester.pumpAndSettle();
    expect(find.byType(DoingScreen), findsOneWidget);
    expect(h.sync.runs, 1);
    expect(h.auth.anonymousSignIns, 0, reason: 'already signed in');

    h.sync.done(40);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(DoingScreen.doneKey));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('library-add')), findsOneWidget);
    expect(find.byType(ChooseServiceScreen), findsNothing);
    expect(find.byType(DoingScreen), findsNothing);
    expect(find.byType(WelcomeScreen), findsNothing);
    expect(h.sync.state, isA<SyncDone>());
  });
}
