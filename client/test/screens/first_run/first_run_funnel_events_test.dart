// The in-flow funnel events, hooked into the first-run pages (plan Task 10,
// moved from Task 9): recorded before the anonymous session exists, posted
// once it does, each once; Library's add flow records none.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/data/playback/playback_controller.dart';
import 'package:mixtape/data/settings/author_store.dart';
import 'package:mixtape/main.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/playback_provider.dart';
import 'package:mixtape/presentation/screens/first_run/artists_screen.dart';
import 'package:mixtape/presentation/screens/first_run/choose_method_screen.dart';
import 'package:mixtape/presentation/screens/first_run/choose_service_screen.dart';
import 'package:mixtape/presentation/screens/first_run/doing_screen.dart';
import 'package:mixtape/presentation/screens/first_run/first_run_flow.dart';
import 'package:mixtape/presentation/screens/first_run/welcome_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/keep_sheet.dart';
import 'package:mixtape/presentation/widgets/mix_energy_summary.dart';

import '../../data/playback/playback_controller_test.dart'
    as playback
    show FakeApi, FakeBridge;
import '../../helpers/fake_bridge.dart' show FakeBridge;
import 'first_run_harness.dart';

Future<ProviderContainer> _pumpApp(
  WidgetTester tester,
  FirstRunHarness h,
) async {
  phone(tester);
  final container = ProviderContainer(
    overrides: [
      ...h.overrides,
      musicKitBridgeProvider.overrideWithValue(FakeBridge(const [])),
      authorStoreProvider.overrideWithValue(InMemoryAuthorStore()),
      accountNameProvider.overrideWith((ref) async => null),
      mixEnergyProvider.overrideWith((ref, key) async => <String, dynamic>{}),
      playbackProvider.overrideWithValue(
        PlaybackController(playback.FakeApi(), playback.FakeBridge()),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const MixtapeApp()),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  reduceMotion();

  testWidgets('path A: first_run_opened and chose_make_mix wait for the '
      'session, then post once; the refused first mix is recorded', (
    tester,
  ) async {
    final h = FirstRunHarness();
    await _pumpApp(tester, h);
    expect(find.byType(WelcomeScreen), findsOneWidget);

    await tester.enterText(find.byKey(const Key('prompt-field')), 'rainy');
    await tester.pump();
    await tester.tap(find.byKey(const Key('start-session')));
    await tester.pumpAndSettle();
    expect(find.byType(ArtistsScreen), findsOneWidget);
    expect(h.listening.funnelEvents, isEmpty, reason: 'no session yet');
    expect(h.auth.anonymousSignIns, 0);

    for (final (i, name) in [(0, 'Burna Boy'), (1, 'Tems'), (2, 'Sade')]) {
      await tester.enterText(find.byKey(ArtistsScreen.fieldKey(i)), name);
      await tester.testTextInput.receiveAction(TextInputAction.next);
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byKey(ArtistsScreen.continueKey));
    await tester.pumpAndSettle();

    expect(h.auth.anonymousSignIns, 1);
    // The harness's DJ answers with an empty queue: the honest refusal.
    expect(h.listening.funnelEvents, [
      FunnelEventType.firstRunOpened,
      FunnelEventType.choseMakeMix,
      FunnelEventType.firstMixRefused,
    ]);
    expect(find.text(KeepSheet.headline), findsNothing);
  });

  testWidgets('path B: chose_add_music, chose_service, chose_method, then '
      'sync_done, each once', (tester) async {
    final h = FirstRunHarness();
    await _pumpApp(tester, h);

    await tester.tap(find.byKey(WelcomeScreen.addMusicKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ChooseServiceScreen.appleKey));
    await tester.pumpAndSettle();
    expect(h.listening.funnelEvents, isEmpty);

    // Back and choose again: still once.
    await tester.tap(find.byKey(const Key('first-run-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ChooseServiceScreen.appleKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ChooseMethodScreen.appleSyncKey));
    await tester.pumpAndSettle();

    // The sync page's first action creates the anonymous listener.
    expect(find.byType(DoingScreen), findsOneWidget);
    expect(h.auth.anonymousSignIns, 1);
    expect(h.listening.funnelEvents, [
      FunnelEventType.firstRunOpened,
      FunnelEventType.choseAddMusic,
      FunnelEventType.choseService,
      FunnelEventType.choseMethod,
    ]);

    h.sync.done(1284);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(DoingScreen.doneKey));
    await tester.pumpAndSettle();
    expect(find.byType(WelcomeScreen), findsOneWidget, reason: 'prompt page');
    expect(h.listening.funnelEvents.last, FunnelEventType.syncDone);
    expect(
      h.listening.funnelEvents.where((e) => e == FunnelEventType.syncDone),
      hasLength(1),
    );
    expect(
      h.listening.funnelEvents.where(
        (e) => e == FunnelEventType.firstRunOpened,
      ),
      hasLength(1),
      reason: 'the prompt page is not Welcome',
    );
  });

  testWidgets('Library add flow records nothing', (tester) async {
    final h = FirstRunHarness(status: AuthStatus.session, anonymous: true);
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
    await tester.tap(find.byKey(ChooseServiceScreen.appleKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ChooseMethodScreen.appleSyncKey));
    await tester.pumpAndSettle();
    h.sync.done(40);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(DoingScreen.doneKey));
    await tester.pumpAndSettle();

    expect(h.listening.funnelEvents, isEmpty);
  });
}
