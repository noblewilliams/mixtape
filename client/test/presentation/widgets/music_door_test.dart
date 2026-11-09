// The music door on a catalog mix (approval `docs/mockups/approved/2026-11-09-
// add-your-music-loop.md`; board frames 1A to 1E, 2A to 2D and 3A): one line
// and one action, worded for the platform, following the run it started.
import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/music_platform_provider.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/idea_pill.dart';
import 'package:mixtape/presentation/widgets/foundation/service_marks.dart';
import 'package:mixtape/presentation/widgets/foundation/tape_button.dart';
import 'package:mixtape/presentation/widgets/library_sync_dialog.dart';
import 'package:mixtape/presentation/widgets/music_door.dart';

import '../../helpers/add_music_harness.dart';
import '../../helpers/fake_listening_api.dart';

const String _catalog =
    "From Mixtape's catalog for now. With your music, the DJ picks from what "
    'you actually play.';

const double _width = 346;

final DateTime _requested = DateTime.utc(2026, 11, 2);

OnboardingState _waiting() =>
    onboardingState(chosenService: 'spotify', markedRequestedAt: _requested);

const List<MusicPlatform?> _platforms = [
  MusicPlatform.apple,
  MusicPlatform.spotify,
  null,
];

String _name(MusicPlatform? platform) => platform?.name ?? 'unknown';

Future<AddMusicHarness> _pumpDoor(
  WidgetTester tester, {
  MusicPlatform? platform,
  OnboardingState? onboarding,
  SyncState sync = const SyncIdle(),
  bool notPersonal = true,
  MusicDoorLayout layout = MusicDoorLayout.transcript,
  VoidCallback? onRemake,
  double textScale = 1,
}) async {
  final h = AddMusicHarness(
    platform: platform,
    onboarding: onboarding ?? onboardingState(),
    sync: sync,
  );
  await h.pump(
    tester,
    Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: _width,
        child: MusicDoor(
          notPersonal: notPersonal,
          layout: layout,
          onRemake: onRemake,
        ),
      ),
    ),
    textScale: textScale,
  );
  return h;
}

Finder get _action => find.byKey(MusicDoor.actionKey);

Finder _inAction(Finder matching) =>
    find.descendant(of: _action, matching: matching);

Finder _icon(IconData icon) =>
    find.byWidgetPredicate((widget) => widget is Icon && widget.icon == icon);

void _expectNoMarks() {
  expect(find.byType(AppleMusicMark), findsNothing);
  expect(find.byType(SpotifyMark), findsNothing);
}

SemanticsNode _door(WidgetTester tester) =>
    tester.getSemantics(find.byKey(MusicDoor.lineKey));

void main() {
  group('no music yet: the line and the platform action', () {
    testWidgets('Apple Music: the Apple Music mark, "Sync Apple Music"', (
      tester,
    ) async {
      await _pumpDoor(tester, platform: MusicPlatform.apple);
      expect(find.text(_catalog), findsOneWidget);
      expect(_inAction(find.text('Sync Apple Music')), findsOneWidget);
      expect(_inAction(find.byType(AppleMusicMark)), findsOneWidget);
      expect(find.byType(SpotifyMark), findsNothing);
      expect(find.byType(IdeaPill), findsOneWidget);
    });

    testWidgets('Spotify: the Spotify mark, "Add Spotify music"', (
      tester,
    ) async {
      await _pumpDoor(tester, platform: MusicPlatform.spotify);
      expect(find.text(_catalog), findsOneWidget);
      expect(_inAction(find.text('Add Spotify music')), findsOneWidget);
      expect(_inAction(find.byType(SpotifyMark)), findsOneWidget);
      expect(find.byType(AppleMusicMark), findsNothing);
    });

    testWidgets('unknown: "Add your music", with no mark', (tester) async {
      await _pumpDoor(tester);
      expect(find.text(_catalog), findsOneWidget);
      expect(_inAction(find.text('Add your music')), findsOneWidget);
      _expectNoMarks();
    });

    testWidgets('refused library access returns the line to no music', (
      tester,
    ) async {
      await _pumpDoor(
        tester,
        platform: MusicPlatform.apple,
        sync: const SyncFailed('denied', accessDenied: true),
      );
      expect(find.text(_catalog), findsOneWidget);
      expect(find.text("Sync didn't finish."), findsNothing);
      expect(_inAction(find.text('Sync Apple Music')), findsOneWidget);
    });

    testWidgets('a sync that brought nothing usable is no music again', (
      tester,
    ) async {
      await _pumpDoor(
        tester,
        platform: MusicPlatform.apple,
        sync: const SyncDone(landedSummary),
      );
      expect(find.text(_catalog), findsOneWidget);
    });

    testWidgets('the pill reads at weight 600', (tester) async {
      await _pumpDoor(tester, platform: MusicPlatform.apple);
      final label = tester.widget<Text>(
        _inAction(find.text('Sync Apple Music')),
      );
      expect(label.style?.fontWeight, FontWeight.w600);
    });

    testWidgets('the line in smoke, flush, with no box', (tester) async {
      await _pumpDoor(tester, platform: MusicPlatform.apple);
      final context = tester.element(find.byType(MusicDoor));
      final text = tester.widget<Text>(find.text(_catalog));
      expect(text.style?.color, context.tokens.smoke);
      expect(
        tester.getTopLeft(find.text(_catalog)).dx,
        tester.getTopLeft(find.byType(MusicDoor)).dx,
      );
      final action = _action.evaluate().single;
      final outlined = find
          .descendant(
            of: find.byType(MusicDoor),
            matching: find.byWidgetPredicate(
              (w) =>
                  w is Container &&
                  w.decoration is BoxDecoration &&
                  (w.decoration as BoxDecoration).border != null,
            ),
          )
          .evaluate()
          .where((element) {
            var insideAction = false;
            element.visitAncestorElements((ancestor) {
              insideAction = ancestor == action;
              return !insideAction;
            });
            return !insideAction;
          });
      expect(outlined, isEmpty, reason: 'only the pill draws an outline');
    });

    testWidgets(
      'the action routes the door: Sync Apple Music opens the alert',
      (tester) async {
        final h = await _pumpDoor(
          tester,
          platform: MusicPlatform.apple,
          onboarding: onboardingState(chosenService: 'apple'),
        );
        await tester.tap(_action);
        await tester.pumpAndSettle();
        expect(find.byType(LibrarySyncDialog), findsOneWidget);
        expect(h.events, [FunnelEventType.musicDoorTapped]);
      },
    );
  });

  group('syncing: the line follows the run, with no action', () {
    for (final platform in _platforms) {
      testWidgets('${_name(platform)}: 42% shows its percent and the bar', (
        tester,
      ) async {
        await _pumpDoor(
          tester,
          platform: platform,
          sync: const SyncRunning(0.42),
        );
        expect(
          find.text(
            'Syncing Apple Music… 42%. You can keep chatting while it runs.',
          ),
          findsOneWidget,
        );
        expect(find.byKey(MusicDoor.barKey), findsOneWidget);
        expect(find.byType(IdeaPill), findsNothing);
        expect(find.byType(TapeButton), findsNothing);
        _expectNoMarks();
      });
    }

    testWidgets('at 0 there is no percent', (tester) async {
      await _pumpDoor(
        tester,
        platform: MusicPlatform.apple,
        sync: const SyncRunning(0),
      );
      expect(
        find.text('Syncing Apple Music… You can keep chatting while it runs.'),
        findsOneWidget,
      );
      expect(find.textContaining('%'), findsNothing);
    });

    testWidgets('the bar is 3 pt of plum about 200 pt wide', (tester) async {
      await _pumpDoor(
        tester,
        platform: MusicPlatform.apple,
        sync: const SyncRunning(0.42),
      );
      final bar = tester.getSize(find.byKey(MusicDoor.barKey));
      expect(bar.height, 3);
      expect(bar.width, 200);
      final context = tester.element(find.byType(MusicDoor));
      final fill = tester.widget<ColoredBox>(
        find.descendant(
          of: find.byKey(MusicDoor.barKey),
          matching: find.byWidgetPredicate(
            (w) => w is ColoredBox && w.color == context.tokens.plum,
          ),
        ),
      );
      expect(fill.color, context.tokens.plum);
      expect(
        tester
            .getSize(
              find.descendant(
                of: find.byKey(MusicDoor.barKey),
                matching: find.byWidget(fill),
              ),
            )
            .width,
        closeTo(84, 0.5),
      );
    });

    testWidgets('the live region keeps one label while the percent moves', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final h = await _pumpDoor(
        tester,
        platform: MusicPlatform.apple,
        sync: const SyncRunning(0.42),
      );
      final first = _door(tester).label;
      expect(
        first,
        'Syncing Apple Music. You can keep chatting while it runs.',
      );
      expect(first, isNot(contains('%')));
      expect(
        _door(tester).getSemanticsData().flagsCollection.isLiveRegion,
        isTrue,
      );

      h.sync.progress(0.43);
      await tester.pumpAndSettle();
      expect(find.textContaining('43%'), findsOneWidget);
      expect(_door(tester).label, first);
      expect(find.bySemanticsLabel(RegExp('43')), findsNothing);
      handle.dispose();
    });

    testWidgets(
      'a finished run still reads as syncing until its onboarding read lands',
      (tester) async {
        final h = await _pumpDoor(
          tester,
          platform: MusicPlatform.apple,
          sync: const SyncRunning(0.9),
        );
        final reload = Completer<OnboardingState>();
        h.listening.onGetOnboarding = () => reload.future;
        h.sync.land();
        await tester.pump();
        expect(find.textContaining('Syncing Apple Music'), findsOneWidget);
        expect(find.text(_catalog), findsNothing, reason: 'no flash of 1A');

        reload.complete(onboardingState(musicReady: true));
        await tester.pumpAndSettle();
        expect(
          find.text('Your music is in. This mix was made before it.'),
          findsOneWidget,
        );
      },
    );
  });

  group('sync failed: error ink, Try again', () {
    for (final platform in [MusicPlatform.apple, null]) {
      testWidgets(_name(platform), (tester) async {
        await _pumpDoor(
          tester,
          platform: platform,
          sync: const SyncFailed('Sync failed. Try again.'),
        );
        final context = tester.element(find.byType(MusicDoor));
        final line = tester.widget<Text>(find.text("Sync didn't finish."));
        expect(line.style?.color, context.tokens.errInk);
        expect(_inAction(find.text('Try again')), findsOneWidget);
        expect(
          _inAction(_icon(CupertinoIcons.arrow_2_circlepath)),
          findsOneWidget,
        );
        _expectNoMarks();
        expect(find.text(_catalog), findsNothing);
      });
    }

    testWidgets('on a Spotify device a failed Apple sync is not the door', (
      tester,
    ) async {
      await _pumpDoor(
        tester,
        platform: MusicPlatform.spotify,
        sync: const SyncFailed('Sync failed. Try again.'),
      );
      expect(find.text("Sync didn't finish."), findsNothing);
      expect(find.text(_catalog), findsOneWidget);
      expect(_inAction(find.text('Add Spotify music')), findsOneWidget);

      await _pumpDoor(
        tester,
        platform: MusicPlatform.spotify,
        onboarding: _waiting(),
        sync: const SyncFailed('Sync failed. Try again.'),
      );
      expect(find.text("Sync didn't finish."), findsNothing);
      expect(_inAction(find.text('Choose files')), findsOneWidget);
    });

    for (final platform in [MusicPlatform.apple, null]) {
      testWidgets('${_name(platform)}: it outranks Spotify waiting', (
        tester,
      ) async {
        await _pumpDoor(
          tester,
          platform: platform,
          onboarding: _waiting(),
          sync: const SyncFailed('Sync failed. Try again.'),
        );
        expect(find.text("Sync didn't finish."), findsOneWidget);
        expect(_inAction(find.text('Try again')), findsOneWidget);
        expect(
          find.text('Waiting on your Spotify data. It can take a few days.'),
          findsNothing,
        );
      });
    }

    testWidgets('Try again reopens the alert at its confirm', (tester) async {
      final h = await _pumpDoor(
        tester,
        platform: MusicPlatform.apple,
        sync: const SyncFailed('Sync failed. Try again.'),
      );
      await tester.tap(_action);
      await tester.pumpAndSettle();
      expect(find.text(LibrarySyncDialog.firstTitle), findsOneWidget);
      expect(h.events, [FunnelEventType.musicDoorTapped]);
    });
  });

  group('Spotify data waiting: Choose files', () {
    for (final platform in _platforms) {
      testWidgets(_name(platform), (tester) async {
        await _pumpDoor(tester, platform: platform, onboarding: _waiting());
        expect(
          find.text('Waiting on your Spotify data. It can take a few days.'),
          findsOneWidget,
        );
        expect(_inAction(find.text('Choose files')), findsOneWidget);
        expect(_inAction(_icon(CupertinoIcons.doc)), findsOneWidget);
        _expectNoMarks();
      });
    }

    testWidgets('a landed package is no longer waiting', (tester) async {
      await _pumpDoor(
        tester,
        platform: MusicPlatform.spotify,
        onboarding: onboardingState(
          chosenService: 'spotify',
          markedRequestedAt: _requested,
          sources: [
            musicSource(packages: const ['spotify_account']),
          ],
        ),
      );
      expect(find.text(_catalog), findsOneWidget);
    });

    testWidgets('Choose files opens the import flow', (tester) async {
      final h = await _pumpDoor(
        tester,
        platform: MusicPlatform.spotify,
        onboarding: _waiting(),
      );
      await tester.tap(_action);
      await tester.pumpAndSettle();
      expect(h.picker.picks, 1);
    });
  });

  group('music in: Remake with my music on the tape button', () {
    for (final platform in _platforms) {
      testWidgets(_name(platform), (tester) async {
        await _pumpDoor(
          tester,
          platform: platform,
          onboarding: onboardingState(musicReady: true),
        );
        expect(
          find.text('Your music is in. This mix was made before it.'),
          findsOneWidget,
        );
        final remake = find.byKey(MusicDoor.remakeKey);
        expect(remake, findsOneWidget);
        expect(tester.widget<TapeButton>(remake).label, 'Remake with my music');
        expect(
          find.descendant(of: remake, matching: find.byKey(MusicDoor.reelKey)),
          findsOneWidget,
        );
        expect(find.byType(IdeaPill), findsNothing);
        _expectNoMarks();
      });
    }

    testWidgets('the tape button sits 8 pt from its reel', (tester) async {
      await _pumpDoor(tester, onboarding: onboardingState(musicReady: true));
      final remake = tester.getTopLeft(find.byKey(MusicDoor.remakeKey));
      final reel = tester.getTopLeft(find.byKey(MusicDoor.reelKey));
      expect(reel.dx - remake.dx, 8);
    });

    testWidgets('outranks a sync still running', (tester) async {
      await _pumpDoor(
        tester,
        platform: MusicPlatform.apple,
        onboarding: onboardingState(musicReady: true),
        sync: const SyncRunning(0.3),
      );
      expect(find.byKey(MusicDoor.remakeKey), findsOneWidget);
      expect(find.byKey(MusicDoor.barKey), findsNothing);
    });

    testWidgets('disabled until a remake is wired; enabled with one', (
      tester,
    ) async {
      await _pumpDoor(tester, onboarding: onboardingState(musicReady: true));
      expect(
        tester.widget<TapeButton>(find.byKey(MusicDoor.remakeKey)).onPressed,
        isNull,
      );

      var remakes = 0;
      await _pumpDoor(
        tester,
        onboarding: onboardingState(musicReady: true),
        onRemake: () => remakes++,
      );
      await tester.tap(find.byKey(MusicDoor.remakeKey));
      expect(remakes, 1);
    });

    testWidgets('its hint says what it makes', (tester) async {
      final handle = tester.ensureSemantics();
      await _pumpDoor(
        tester,
        onboarding: onboardingState(musicReady: true),
        onRemake: () {},
      );
      final node = tester.getSemantics(
        find.bySemanticsLabel('Remake with my music'),
      );
      expect(node.hint, 'Makes a new version from your music.');
      expect(node.getSemanticsData().flagsCollection.isButton, isTrue);
      handle.dispose();
    });
  });

  testWidgets('remade (not a catalog mix any more): nothing at all', (
    tester,
  ) async {
    await _pumpDoor(tester, platform: MusicPlatform.apple, notPersonal: false);
    expect(find.byKey(MusicDoor.lineKey), findsNothing);
    expect(
      find.descendant(of: find.byType(MusicDoor), matching: find.byType(Text)),
      findsNothing,
    );
    expect(tester.getSize(find.byType(MusicDoor)).height, 0);
  });

  group('accessibility', () {
    testWidgets('one container, one live region: the line, then the button', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pumpDoor(tester, platform: MusicPlatform.apple);

      final door = _door(tester);
      expect(door.label, _catalog);
      expect(door.getSemanticsData().flagsCollection.isLiveRegion, isTrue);

      final action = tester.getSemantics(
        find.bySemanticsLabel('Sync Apple Music'),
      );
      expect(action.getSemanticsData().flagsCollection.isButton, isTrue);
      expect(action.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      expect(action.parent, door, reason: 'the button sits inside the line');
      handle.dispose();
    });

    testWidgets('the action keeps a 44 pt target', (tester) async {
      await _pumpDoor(tester, platform: MusicPlatform.apple);
      expect(
        tester.getSize(_action).height,
        greaterThanOrEqualTo(MixtapeMetrics.minTarget),
      );
    });

    testWidgets('below the strip\'s threshold the action shrink-wraps', (
      tester,
    ) async {
      await _pumpDoor(tester, platform: MusicPlatform.apple);
      expect(tester.getSize(_action).width, lessThan(_width));
    });

    for (final (name, onboarding, sync, label) in [
      ('no music', onboardingState(), const SyncIdle(), 'Sync Apple Music'),
      ('failed', onboardingState(), const SyncFailed('x'), 'Try again'),
      ('waiting', _waiting(), const SyncIdle(), 'Choose files'),
      (
        'music in',
        onboardingState(musicReady: true),
        const SyncIdle(),
        'Remake with my music',
      ),
    ]) {
      testWidgets('largest text, $name: the line and the action label wrap in '
          'full, and the action goes full width at 52 pt', (tester) async {
        await _pumpDoor(
          tester,
          platform: MusicPlatform.apple,
          onboarding: onboarding,
          sync: sync,
          textScale: 3,
        );
        expect(tester.takeException(), isNull);
        final action = name == 'music in'
            ? find.byKey(MusicDoor.remakeKey)
            : _action;
        expect(tester.getSize(action).width, _width);
        expect(
          tester.getSize(action).height,
          greaterThanOrEqualTo(MusicDoor.largeActionHeight),
        );
        final words = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.descendant(of: action, matching: find.text(label)),
            matching: find.byType(RichText),
          ),
        );
        expect(words.didExceedMaxLines, isFalse, reason: '$label is cut');
        final line = find.byKey(MusicDoor.textKey);
        final text = tester.widget<Text>(line);
        expect(text.maxLines, isNull);
        expect(text.overflow, isNot(TextOverflow.ellipsis));
        expect(tester.getSize(line).width, lessThanOrEqualTo(_width));
      });
    }

    testWidgets('largest text: the catalog line takes several lines', (
      tester,
    ) async {
      await _pumpDoor(tester, platform: MusicPlatform.apple, textScale: 2);
      final line = tester.getSize(find.byKey(MusicDoor.textKey));
      expect(line.height, greaterThan(3 * 12 * 2));
    });
  });

  group('the tape layout', () {
    testWidgets('"Not personal yet", then the door, with a hairline under it', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pumpDoor(
        tester,
        platform: MusicPlatform.spotify,
        layout: MusicDoorLayout.tape,
      );
      expect(find.text('Not personal yet'), findsOneWidget);
      expect(find.text(_catalog), findsOneWidget);
      expect(_inAction(find.text('Add Spotify music')), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Not personal yet')).dy,
        lessThan(tester.getTopLeft(find.text(_catalog)).dy),
      );

      final context = tester.element(find.byType(MusicDoor));
      final hairline = find.descendant(
        of: find.byType(MusicDoor),
        matching: find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).border ==
                  Border(bottom: BorderSide(color: context.tokens.hairline)),
        ),
      );
      expect(hairline, findsOneWidget);
      expect(
        tester.getBottomLeft(hairline).dy,
        greaterThanOrEqualTo(tester.getBottomLeft(_action).dy),
      );

      final door = _door(tester);
      expect(door.label, 'Not personal yet\n$_catalog');
      expect(door.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
      handle.dispose();
    });

    testWidgets('remade: nothing on the tape either', (tester) async {
      await _pumpDoor(tester, layout: MusicDoorLayout.tape, notPersonal: false);
      expect(find.text('Not personal yet'), findsNothing);
    });
  });

  testWidgets('dark: renders without a box or an overflow', (tester) async {
    final h = AddMusicHarness(platform: MusicPlatform.apple);
    await h.pump(
      tester,
      const MusicDoor(notPersonal: true, layout: MusicDoorLayout.transcript),
      brightness: Brightness.dark,
    );
    expect(tester.takeException(), isNull);
    expect(find.text(_catalog), findsOneWidget);
  });
}
