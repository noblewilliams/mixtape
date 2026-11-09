// The add-your-music router (spec `docs/superpowers/specs/2026-11-09-add-
// your-music-loop-design.md`, decisions 2 and 7; plan task C2): one function
// for the door, its sync retry and the history pill, opening the step that
// adds this listener's music and returning to the mix it was opened from.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/presentation/add_music/add_music_router.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/music_platform_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';
import 'package:mixtape/presentation/screens/first_run/choose_method_screen.dart'
    show AddMethod;
import 'package:mixtape/presentation/screens/first_run/choose_service_screen.dart';
import 'package:mixtape/presentation/screens/first_run/doing_screen.dart';
import 'package:mixtape/presentation/screens/first_run/first_run_flow.dart';
import 'package:mixtape/presentation/screens/first_run/step_scaffold.dart';
import 'package:mixtape/presentation/widgets/library_sync_dialog.dart';

import '../../helpers/add_music_harness.dart';
import '../../helpers/fake_listening_api.dart';

const Key _openKey = Key('open-add-music');

final DateTime _requested = DateTime.utc(2026, 11, 2);

OnboardingState _apple({bool ready = false}) =>
    onboardingState(chosenService: 'apple', musicReady: ready);

OnboardingState _spotify({bool requested = false, bool ready = false}) =>
    onboardingState(
      chosenService: 'spotify',
      markedRequestedAt: requested ? _requested : null,
      musicReady: ready,
    );

/// A mix's opener: watches what a door watches (so onboarding and the
/// platform are loaded by the time it is tapped), and calls the router.
class _Opener extends ConsumerWidget {
  const _Opener(this.target, {this.onClosed});

  final AddMusicTarget target;
  final VoidCallback? onClosed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(onboardingProvider);
    ref.watch(musicPlatformProvider);
    return Center(
      child: TextButton(
        key: _openKey,
        onPressed: () async {
          await openAddMusicFor(context, ref, target);
          onClosed?.call();
        },
        child: const Text('open'),
      ),
    );
  }
}

Future<void> _open(
  WidgetTester tester,
  AddMusicHarness h,
  AddMusicTarget target, {
  VoidCallback? onClosed,
}) async {
  await h.pump(tester, _Opener(target, onClosed: onClosed));
  await tester.tap(find.byKey(_openKey));
  await tester.pumpAndSettle();
}

String? _routeName(WidgetTester tester, Finder page) =>
    ModalRoute.of(tester.element(page))?.settings.name;

void main() {
  group('the destination table', () {
    AddMusicDestination where(
      AddMusicTarget target,
      MusicPlatform? platform,
      OnboardingState onboarding,
    ) =>
        addMusicDestination(target, platform: platform, onboarding: onboarding);

    test(
      'the door: by platform, and the import sheet while Spotify is waiting',
      () {
        expect(
          where(AddMusicTarget.door, MusicPlatform.apple, _apple()),
          AddMusicDestination.appleSync,
        );
        expect(
          where(AddMusicTarget.door, MusicPlatform.spotify, _spotify()),
          AddMusicDestination.exportify,
        );
        expect(
          where(
            AddMusicTarget.door,
            MusicPlatform.spotify,
            _spotify(requested: true),
          ),
          AddMusicDestination.importFiles,
        );
        expect(
          where(AddMusicTarget.door, null, onboardingState()),
          AddMusicDestination.chooseService,
          reason: 'null is nothing known, never Apple Music',
        );
      },
    );

    test('the door says "Choose files" whenever Spotify is waiting, so it '
        'always lands on the import sheet', () {
      expect(
        where(
          AddMusicTarget.door,
          MusicPlatform.apple,
          _spotify(requested: true),
        ),
        AddMusicDestination.importFiles,
      );
      expect(
        where(AddMusicTarget.door, null, _spotify(requested: true)),
        AddMusicDestination.importFiles,
      );
    });

    test('a landed package or an Exportify import is not waiting', () {
      for (final packages in [
        ['spotify_extended'],
        ['spotify_account'],
        ['spotify_exportify'],
      ]) {
        final onboarding = onboardingState(
          chosenService: 'spotify',
          markedRequestedAt: _requested,
          sources: [musicSource(packages: packages)],
        );
        expect(spotifyDataWaiting(onboarding), isFalse, reason: '$packages');
        expect(
          where(AddMusicTarget.door, MusicPlatform.spotify, onboarding),
          AddMusicDestination.exportify,
          reason: '$packages',
        );
      }
      expect(spotifyDataWaiting(_spotify(requested: true)), isTrue);
      expect(spotifyDataWaiting(_spotify()), isFalse, reason: 'not requested');
      expect(
        spotifyDataWaiting(
          onboardingState(
            chosenService: 'apple',
            markedRequestedAt: _requested,
          ),
        ),
        isFalse,
        reason: 'Spotify is not the chosen service',
      );
      expect(spotifyDataWaiting(null), isFalse);
    });

    test('Try again is the alert, whatever the platform', () {
      for (final platform in [
        MusicPlatform.apple,
        MusicPlatform.spotify,
        null,
      ]) {
        expect(
          where(AddMusicTarget.retrySync, platform, _spotify(requested: true)),
          AddMusicDestination.appleSync,
          reason: '$platform',
        );
      }
    });

    test('the history pill: the data-export page for the platform', () {
      expect(
        where(
          AddMusicTarget.history,
          MusicPlatform.spotify,
          _spotify(requested: true),
        ),
        AddMusicDestination.importFiles,
      );
      expect(
        where(AddMusicTarget.history, MusicPlatform.spotify, _spotify()),
        AddMusicDestination.spotifyExport,
      );
      expect(
        where(AddMusicTarget.history, MusicPlatform.apple, _apple()),
        AddMusicDestination.appleExport,
      );
      expect(
        where(AddMusicTarget.history, null, onboardingState()),
        AddMusicDestination.chooseService,
      );
    });
  });

  group('what opens', () {
    testWidgets('door, Apple Music: the Sync Apple Music alert', (
      tester,
    ) async {
      final h = AddMusicHarness(
        platform: MusicPlatform.apple,
        onboarding: _apple(),
      );
      await _open(tester, h, AddMusicTarget.door);

      expect(find.byType(LibrarySyncDialog), findsOneWidget);
      expect(find.text(LibrarySyncDialog.firstTitle), findsOneWidget);
      expect(find.byType(DoingScreen), findsNothing);
    });

    testWidgets(
      'door, Spotify: Exportify in library mode, named so it pops back to the mix',
      (tester) async {
        var closed = 0;
        final h = AddMusicHarness(
          platform: MusicPlatform.spotify,
          onboarding: _spotify(),
        );
        await _open(tester, h, AddMusicTarget.door, onClosed: () => closed++);

        final page = find.byType(DoingScreen);
        expect(page, findsOneWidget);
        final doing = tester.widget<DoingScreen>(page);
        expect(doing.method, AddMethod.exportify);
        expect(doing.mode, AddMusicMode.library);
        expect(_routeName(tester, page), '${addMusicRoutePrefix}3');

        await tester.tap(find.byKey(TapeBackButton.defaultKey));
        await tester.pumpAndSettle();
        expect(find.byType(DoingScreen), findsNothing);
        expect(find.byKey(_openKey), findsOneWidget, reason: 'back on the mix');
        expect(closed, 1);
      },
    );

    testWidgets('door, Spotify waiting: the import flow (Choose files)', (
      tester,
    ) async {
      final h = AddMusicHarness(
        platform: MusicPlatform.spotify,
        onboarding: _spotify(requested: true),
      );
      await _open(tester, h, AddMusicTarget.door);

      expect(h.picker.picks, 1, reason: 'the import flow opens the picker');
      expect(find.byType(DoingScreen), findsNothing);
    });

    testWidgets('door, platform unknown: Step 1 in library mode', (
      tester,
    ) async {
      final h = AddMusicHarness(onboarding: onboardingState());
      await _open(tester, h, AddMusicTarget.door);

      final page = find.byType(ChooseServiceScreen);
      expect(page, findsOneWidget);
      expect(
        tester.widget<ChooseServiceScreen>(page).mode,
        AddMusicMode.library,
      );
      expect(find.byType(LibrarySyncDialog), findsNothing);
    });

    testWidgets('Try again: the alert at its confirm, over the failed run', (
      tester,
    ) async {
      final h = AddMusicHarness(
        platform: MusicPlatform.spotify,
        onboarding: _apple(),
        sync: const SyncFailed('Sync failed. Try again.'),
      );
      await _open(tester, h, AddMusicTarget.retrySync);

      expect(find.byType(LibrarySyncDialog), findsOneWidget);
      expect(find.text(LibrarySyncDialog.firstTitle), findsOneWidget);
      expect(find.text(LibrarySyncDialog.failedTitle), findsNothing);
    });

    testWidgets('history, Spotify requested: the import flow', (tester) async {
      final h = AddMusicHarness(
        platform: MusicPlatform.spotify,
        onboarding: _spotify(requested: true),
      );
      await _open(tester, h, AddMusicTarget.history);
      expect(h.picker.picks, 1);
    });

    testWidgets("history, Spotify: the data export's request page", (
      tester,
    ) async {
      final h = AddMusicHarness(
        platform: MusicPlatform.spotify,
        onboarding: _spotify(),
      );
      await _open(tester, h, AddMusicTarget.history);

      final page = find.byType(DoingScreen);
      expect(tester.widget<DoingScreen>(page).method, AddMethod.spotifyExport);
      expect(tester.widget<DoingScreen>(page).mode, AddMusicMode.library);
      expect(_routeName(tester, page), '${addMusicRoutePrefix}3');
    });

    testWidgets(
      "Step 3's I've requested it pops back to the chat it was opened from",
      (tester) async {
        var closed = 0;
        final h = AddMusicHarness(
          platform: MusicPlatform.spotify,
          onboarding: _spotify(),
        );
        await h.pump(
          tester,
          Builder(
            builder: (context) => Center(
              child: TextButton(
                key: const Key('open-chat'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    settings: const RouteSettings(name: 'chat'),
                    builder: (_) => Scaffold(
                      body: _Opener(
                        AddMusicTarget.history,
                        onClosed: () => closed++,
                      ),
                    ),
                  ),
                ),
                child: const Text('mixes'),
              ),
            ),
          ),
        );
        await tester.tap(find.byKey(const Key('open-chat')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(_openKey));
        await tester.pumpAndSettle();
        expect(
          tester.widget<DoingScreen>(find.byType(DoingScreen)).method,
          AddMethod.spotifyExport,
        );

        await tester.scrollUntilVisible(
          find.byKey(DoingScreen.requestedKey),
          200,
          scrollable: find
              .descendant(
                of: find.byType(DoingScreen),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(find.byKey(DoingScreen.requestedKey));
        await tester.pumpAndSettle();

        expect(find.byType(DoingScreen), findsNothing);
        expect(find.byKey(_openKey), findsOneWidget, reason: 'on the chat');
        expect(
          find.byKey(const Key('open-chat')),
          findsNothing,
          reason: 'not popped past it',
        );
        expect(closed, 1);
        expect(h.events, contains(FunnelEventType.markedRequested));
        expect(h.events.first, FunnelEventType.musicChipTapped);
      },
    );

    testWidgets('history, Apple Music: Upload an Apple export', (tester) async {
      final h = AddMusicHarness(
        platform: MusicPlatform.apple,
        onboarding: _apple(),
      );
      await _open(tester, h, AddMusicTarget.history);

      final page = find.byType(DoingScreen);
      expect(tester.widget<DoingScreen>(page).method, AddMethod.appleExport);
      expect(tester.widget<DoingScreen>(page).mode, AddMusicMode.library);
    });

    testWidgets('history, platform unknown: Step 1', (tester) async {
      final h = AddMusicHarness(onboarding: onboardingState());
      await _open(tester, h, AddMusicTarget.history);
      expect(find.byType(ChooseServiceScreen), findsOneWidget);
    });
  });

  group('funnel and onboarding', () {
    testWidgets('the door records music_door_tapped', (tester) async {
      final h = AddMusicHarness(
        platform: MusicPlatform.apple,
        onboarding: _apple(),
      );
      await _open(tester, h, AddMusicTarget.door);
      expect(h.events, [FunnelEventType.musicDoorTapped]);
    });

    testWidgets('Try again records music_door_tapped too', (tester) async {
      final h = AddMusicHarness(
        platform: MusicPlatform.apple,
        onboarding: _apple(),
        sync: const SyncFailed('Sync failed. Try again.'),
      );
      await _open(tester, h, AddMusicTarget.retrySync);
      expect(h.events, [FunnelEventType.musicDoorTapped]);
    });

    testWidgets('the history pill records music_chip_tapped', (tester) async {
      final h = AddMusicHarness(
        platform: MusicPlatform.apple,
        onboarding: _apple(),
      );
      await _open(tester, h, AddMusicTarget.history);
      expect(h.events, [FunnelEventType.musicChipTapped]);
    });

    testWidgets('a page closing reads onboarding again', (tester) async {
      final h = AddMusicHarness(
        platform: MusicPlatform.spotify,
        onboarding: _spotify(),
      );
      await _open(tester, h, AddMusicTarget.door);
      final reads = h.listening.getOnboardingCalls;

      await tester.tap(find.byKey(TapeBackButton.defaultKey));
      await tester.pumpAndSettle();
      expect(h.listening.getOnboardingCalls, reads + 1);
    });
  });

  group('music_added_from_mix', () {
    testWidgets(
      'a sync hidden in the alert is followed to its landing and counts once, '
      'with no second onboarding read',
      (tester) async {
        final h = AddMusicHarness(
          platform: MusicPlatform.apple,
          onboarding: _apple(),
        );
        await _open(tester, h, AddMusicTarget.door);
        await tester.tap(find.byKey(LibrarySyncDialog.startKey));
        await tester.pumpAndSettle();
        expect(h.sync.runs, 1);
        await tester.tap(find.byKey(LibrarySyncDialog.hideKey));
        await tester.pumpAndSettle();
        expect(find.byType(LibrarySyncDialog), findsNothing);
        expect(h.events, [FunnelEventType.musicDoorTapped]);

        h.sync.progress(0.6);
        await tester.pumpAndSettle();
        h.listening.onboarding = _apple(ready: true);
        final reads = h.listening.getOnboardingCalls;
        h.sync.land();
        await tester.pumpAndSettle();

        expect(h.events, [
          FunnelEventType.musicDoorTapped,
          FunnelEventType.musicAddedFromMix,
        ]);
        expect(
          h.listening.getOnboardingCalls,
          reads + 1,
          reason: "the landing sync's own read is the refresh",
        );

        // A later run, not opened from the mix, counts nothing.
        await h.container.read(librarySyncProvider.notifier).sync();
        h.sync.land();
        await tester.pumpAndSettle();
        expect(
          h.events.where((e) => e == FunnelEventType.musicAddedFromMix),
          hasLength(1),
        );
      },
    );

    testWidgets('a run that lands inside the alert counts once', (
      tester,
    ) async {
      final h = AddMusicHarness(
        platform: MusicPlatform.apple,
        onboarding: _apple(),
      );
      await _open(tester, h, AddMusicTarget.door);
      await tester.tap(find.byKey(LibrarySyncDialog.startKey));
      await tester.pumpAndSettle();
      h.listening.onboarding = _apple(ready: true);
      h.sync.land();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LibrarySyncDialog.doneKey));
      await tester.pumpAndSettle();

      expect(h.events, [
        FunnelEventType.musicDoorTapped,
        FunnelEventType.musicAddedFromMix,
      ]);
    });

    testWidgets('nothing counts when the music was already ready', (
      tester,
    ) async {
      final h = AddMusicHarness(
        platform: MusicPlatform.apple,
        onboarding: _apple(ready: true),
      );
      await _open(tester, h, AddMusicTarget.retrySync);
      await tester.tap(find.byKey(LibrarySyncDialog.startKey));
      await tester.pumpAndSettle();
      h.sync.land();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LibrarySyncDialog.doneKey));
      await tester.pumpAndSettle();

      expect(h.events, [FunnelEventType.musicDoorTapped]);
    });

    testWidgets('a failed sync disarms: a later landing counts nothing', (
      tester,
    ) async {
      final h = AddMusicHarness(
        platform: MusicPlatform.apple,
        onboarding: _apple(),
      );
      await _open(tester, h, AddMusicTarget.door);
      await tester.tap(find.byKey(LibrarySyncDialog.startKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LibrarySyncDialog.hideKey));
      await tester.pumpAndSettle();

      h.sync.fail();
      await tester.pumpAndSettle();
      h.listening.onboarding = _apple(ready: true);
      await h.container.read(librarySyncProvider.notifier).sync();
      h.sync.land();
      await tester.pumpAndSettle();

      expect(h.events, [FunnelEventType.musicDoorTapped]);
    });

    testWidgets('a cancelled sync disarms too', (tester) async {
      final h = AddMusicHarness(
        platform: MusicPlatform.apple,
        onboarding: _apple(),
      );
      await _open(tester, h, AddMusicTarget.door);
      await tester.tap(find.byKey(LibrarySyncDialog.startKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LibrarySyncDialog.hideKey));
      await tester.pumpAndSettle();

      h.sync.cancel();
      await tester.pumpAndSettle();
      // A later run lands: nothing may still be following the cancelled one.
      h.listening.onboarding = _apple(ready: true);
      await h.container.read(librarySyncProvider.notifier).sync();
      await tester.pumpAndSettle();
      h.sync.land();
      await tester.pumpAndSettle();

      expect(h.events, [FunnelEventType.musicDoorTapped]);
    });

    testWidgets(
      'a failed read after the landing keeps it armed for the next good read',
      (tester) async {
        final h = AddMusicHarness(
          platform: MusicPlatform.apple,
          onboarding: _apple(),
        );
        await _open(tester, h, AddMusicTarget.door);
        await tester.tap(find.byKey(LibrarySyncDialog.startKey));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(LibrarySyncDialog.hideKey));
        await tester.pumpAndSettle();

        h.listening.onGetOnboarding = () =>
            Future<OnboardingState>.error(StateError('offline'));
        h.sync.land();
        await tester.pumpAndSettle();
        expect(h.events, [FunnelEventType.musicDoorTapped]);

        h.listening.onGetOnboarding = null;
        h.listening.onboarding = _apple(ready: true);
        await h.container.read(onboardingProvider.notifier).refresh();
        await tester.pumpAndSettle();
        expect(h.events, [
          FunnelEventType.musicDoorTapped,
          FunnelEventType.musicAddedFromMix,
        ]);
      },
    );

    testWidgets('a failed read is dropped when the router opens again', (
      tester,
    ) async {
      final h = AddMusicHarness(
        platform: MusicPlatform.apple,
        onboarding: _apple(),
      );
      await _open(tester, h, AddMusicTarget.door);
      await tester.tap(find.byKey(LibrarySyncDialog.startKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LibrarySyncDialog.hideKey));
      await tester.pumpAndSettle();
      h.listening.onGetOnboarding = () =>
          Future<OnboardingState>.error(StateError('offline'));
      h.sync.land();
      await tester.pumpAndSettle();

      // Opened again, then closed with nothing started: the next good read
      // says ready, but neither run brought the music in.
      h.listening.onGetOnboarding = null;
      h.listening.onboarding = _apple(ready: true);
      await tester.tap(find.byKey(_openKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(LibrarySyncDialog.cancelKey));
      await tester.pumpAndSettle();

      expect(h.events, [
        FunnelEventType.musicDoorTapped,
        FunnelEventType.musicDoorTapped,
      ]);
    });

    testWidgets(
      'the alert closed with nothing started counts nothing, even when the '
      'next read says ready',
      (tester) async {
        final h = AddMusicHarness(
          platform: MusicPlatform.apple,
          onboarding: _apple(),
        );
        await _open(tester, h, AddMusicTarget.door);
        h.listening.onboarding = _apple(ready: true);
        final reads = h.listening.getOnboardingCalls;
        await tester.tap(find.byKey(LibrarySyncDialog.cancelKey));
        await tester.pumpAndSettle();

        expect(
          h.listening.getOnboardingCalls,
          reads + 1,
          reason: 'still re-read',
        );
        expect(h.events, [FunnelEventType.musicDoorTapped]);
      },
    );

    testWidgets('music in when the Exportify page closes counts once', (
      tester,
    ) async {
      final h = AddMusicHarness(
        platform: MusicPlatform.spotify,
        onboarding: _spotify(),
      );
      await _open(tester, h, AddMusicTarget.door);
      h.listening.onboarding = _spotify(ready: true);
      await tester.tap(find.byKey(TapeBackButton.defaultKey));
      await tester.pumpAndSettle();

      expect(h.events, [
        FunnelEventType.musicDoorTapped,
        FunnelEventType.musicAddedFromMix,
      ]);

      await h.container.read(onboardingProvider.notifier).refresh();
      await tester.pumpAndSettle();
      expect(h.events, hasLength(2), reason: 'once per run the router opened');
    });

    testWidgets('a page closing with nothing in counts nothing', (
      tester,
    ) async {
      final h = AddMusicHarness(
        platform: MusicPlatform.spotify,
        onboarding: _spotify(),
      );
      await _open(tester, h, AddMusicTarget.door);
      await tester.tap(find.byKey(TapeBackButton.defaultKey));
      await tester.pumpAndSettle();
      expect(h.events, [FunnelEventType.musicDoorTapped]);
    });
  });
}
