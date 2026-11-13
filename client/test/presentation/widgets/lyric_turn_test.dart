// The lyric transcript's pieces (board section 1; locked record →
// Transcript, Version markers, Working, Failed turn).
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/dj/dj_api.dart' show TurnStep;
import 'package:mixtape/presentation/providers/working_step.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/cassette_tile.dart';
import 'package:mixtape/presentation/widgets/lyric_turn.dart';
import 'package:mixtape/presentation/widgets/version_marker.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
  bool reducedMotion = false,
  double width = 360,
}) => tester.pumpWidget(
  MaterialApp(
    theme: brightness == Brightness.dark
        ? MixtapeTheme.dark()
        : MixtapeTheme.light(),
    home: MediaQuery(
      data: MediaQueryData(
        size: Size(width, 800),
        disableAnimations: reducedMotion,
      ),
      child: Scaffold(
        body: Center(
          child: SizedBox(width: width, child: child),
        ),
      ),
    ),
  ),
);

/// A working cassette whose step a test moves on, as a turn's stream does.
class _Following extends StatelessWidget {
  const _Following({required this.step});

  final ValueNotifier<WorkingStep?> step;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<WorkingStep?>(
    valueListenable: step,
    builder: (context, value, _) => WorkingCassette(seed: 0, step: value),
  );
}

void main() {
  testWidgets('no bubbles: DJ lines are large ink, yours smaller smoke', (
    tester,
  ) async {
    await _pump(
      tester,
      const Column(
        children: [
          LyricTurn(text: 'here you go', kind: ConversationTurnKind.dj),
          LyricTurn(text: 'play some jazz', kind: ConversationTurnKind.user),
        ],
      ),
    );
    final tokens = MixtapeTokens.light;
    final dj = tester.widget<Text>(find.byKey(LyricTurn.djKey));
    expect(dj.style!.fontSize, 17);
    expect(dj.style!.color, tokens.text);
    final me = tester.widget<Text>(find.byKey(LyricTurn.userKey));
    expect(me.style!.fontSize, 15);
    expect(me.style!.color, tokens.smoke);
    expect(me.textAlign, TextAlign.right);
    // Right-aligned, and never wider than 84% of the line.
    expect(
      tester.getTopRight(find.byKey(LyricTurn.userKey)).dx,
      closeTo(tester.getTopRight(find.byType(Column)).dx, 0.5),
    );
    expect(
      tester.getSize(find.byKey(LyricTurn.userKey)).width,
      lessThanOrEqualTo(360 * 0.84 + 0.01),
    );
    expect(find.byType(DecoratedBox), findsNothing);
  });

  testWidgets('a failed turn is one err-ink line with a 44 pt Resend', (
    tester,
  ) async {
    var resent = 0;
    await _pump(
      tester,
      LyricTurn(
        text: "Couldn't reach the DJ.",
        kind: ConversationTurnKind.error,
        onResend: () => resent++,
      ),
      brightness: Brightness.dark,
    );
    expect(
      tester.widget<Text>(find.text("Couldn't reach the DJ.")).style!.color,
      MixtapeTokens.dark.errInk,
    );
    final resend = find.byKey(LyricTurn.resendKey);
    expect(tester.getSize(resend).height, greaterThanOrEqualTo(44));
    expect(tester.getSize(resend).width, greaterThanOrEqualTo(44));
    await tester.tap(resend);
    expect(resent, 1);
  });

  testWidgets('a disabled Resend stays drawn and does nothing', (tester) async {
    var resent = 0;
    await _pump(
      tester,
      LyricTurn(
        text: 'Failed',
        kind: ConversationTurnKind.error,
        onResend: () => resent++,
        resendEnabled: false,
      ),
    );
    await tester.tap(find.byKey(LyricTurn.resendKey));
    expect(resent, 0);
    expect(find.text('Resend'), findsOneWidget);
  });

  group('what the DJ is doing (device smoke 2026-11-13)', () {
    testWidgets('the caption walks the DJ through the job, then holds', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, const WorkingCassette(seed: 0));
      final phases = DjWorkingPhrases.mix.phases;
      expect(phases.first.lines.single, WorkingCassette.caption);
      expect(find.text('The DJ is listening…'), findsOneWidget);

      var elapsed = Duration.zero;
      for (final phase in phases.skip(1)) {
        final line = DjWorkingPhrases.mix.lineAt(phase.from, seed: 0);
        expect(phase.lines, contains(line));
        await tester.pump(
          phase.from - const Duration(milliseconds: 1) - elapsed,
        );
        expect(find.text(line), findsNothing);
        await tester.pump(const Duration(milliseconds: 1));
        await tester.pump(const Duration(milliseconds: 400));
        elapsed = phase.from + const Duration(milliseconds: 400);
        expect(find.text(line), findsOneWidget);
        // Whatever it says, VoiceOver hears one steady line.
        expect(
          tester.getSemantics(find.byKey(WorkingCassette.indicatorKey)).label,
          'The DJ is working',
        );
      }
      // The last line stays however long the turn takes.
      await tester.pump(const Duration(minutes: 3));
      expect(find.text(phases.last.lines.single), findsOneWidget);
      handle.dispose();
    });

    test('every phase is a short line of its own, in order', () {
      for (final phrases in [DjWorkingPhrases.mix, DjWorkingPhrases.album]) {
        final seen = <String>{};
        var last = const Duration(seconds: -1);
        for (final phase in phrases.phases) {
          expect(phase.from, greaterThan(last));
          last = phase.from;
          expect(phase.lines, isNotEmpty);
          for (final line in phase.lines) {
            expect(seen.add(line), isTrue, reason: 'repeated: $line');
            expect(line.length, lessThanOrEqualTo(44), reason: line);
          }
        }
        expect(phrases.phases.first.from, Duration.zero);
      }
    });

    test('a seed picks one line per phase and keeps it', () {
      const phrases = DjWorkingPhrases.mix;
      final at = phrases.phases[2].from;
      expect(phrases.lineAt(at, seed: 1), phrases.lineAt(at, seed: 1));
      final lines = {
        for (var seed = 0; seed < 12; seed++) phrases.lineAt(at, seed: seed),
      };
      expect(lines.length, phrases.phases[2].lines.length);
    });

    testWidgets('a turn already under way picks up where it had got to', (
      tester,
    ) async {
      final phase = DjWorkingPhrases.mix.phases[3];
      await _pump(
        tester,
        WorkingCassette(
          seed: 0,
          startedAt: DateTime.now().subtract(
            phase.from + const Duration(seconds: 1),
          ),
        ),
      );
      expect(
        find.text(DjWorkingPhrases.mix.lineAt(phase.from, seed: 0)),
        findsOneWidget,
      );
    });

    testWidgets('an album turn has its own lines', (tester) async {
      await _pump(
        tester,
        const WorkingCassette(
          seed: 0,
          phrases: DjWorkingPhrases.album,
          announcementText: WorkingCassette.albumAnnouncement,
        ),
      );
      expect(find.text(WorkingCassette.albumCaption), findsOneWidget);
      await tester.pump(DjWorkingPhrases.album.phases[1].from);
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.text(
          DjWorkingPhrases.album.lineAt(
            DjWorkingPhrases.album.phases[1].from,
            seed: 0,
          ),
        ),
        findsOneWidget,
      );
    });
  });

  group('the turn\'s own steps (turn steps 2026-11-13)', () {
    const listening = 'The DJ is listening…';
    const still = 'Still at the decks. Worth the wait…';
    String line(TurnStep? step, {int seconds = 0, int seed = 0}) =>
        DjWorkingPhrases.stepLineAt(
          step,
          Duration(seconds: seconds),
          seed: seed,
        );

    test('every step the server may send has words, and only those', () {
      for (final name in WorkingStep.known) {
        expect(DjWorkingPhrases.knows(TurnStep(name)), isTrue, reason: name);
      }
      expect(DjWorkingPhrases.knows(const TurnStep('tuning')), isFalse);
      expect(line(null), listening);
      expect(line(const TurnStep('listening')), listening);
    });

    test('each step says its own line, one picked per turn', () {
      final cases = {
        const TurnStep('playlists'): [
          'Looking through your playlists…',
          'Pulling that playlist off the shelf…',
        ],
        const TurnStep('digging', scope: 'library'): [
          'Flipping through your records…',
          'Thumbing through your stacks…',
        ],
        const TurnStep('digging', scope: 'catalogue'): [
          'Digging through the crates…',
          'Crate-digging for you…',
        ],
        // A scope it does not know reads as the crates.
        const TurnStep('digging'): [
          'Digging through the crates…',
          'Crate-digging for you…',
        ],
        const TurnStep('picking'): [
          'Pulling records that fit…',
          'Cueing up contenders…',
        ],
        const TurnStep('checking'): [
          'Checking the pressings…',
          'Giving it a sound check…',
        ],
        const TurnStep('editing'): [
          'Reworking the tracklist…',
          'Swapping records…',
        ],
        const TurnStep('pressing'): ['Pressing the tape…', 'Spooling it up…'],
        const TurnStep('labelling'): ['Labelling the cassette…'],
        const TurnStep('noting'): ['Jotting that on the sleeve…'],
        const TurnStep('writing'): ['Writing the liner notes…'],
      };
      for (final MapEntry(key: step, value: lines) in cases.entries) {
        final picked = {
          for (var seed = 0; seed < 6; seed++) line(step, seed: seed),
        };
        expect(picked, lines.toSet(), reason: step.toString());
        expect(line(step, seed: 3), line(step, seed: 3));
      }
    });

    test('names: artists, genres, a playlist, a title, a count', () {
      const tems = ['Tems'];
      expect(
        {
          for (var seed = 0; seed < 4; seed++)
            line(
              const TurnStep('digging', scope: 'library', artists: tems),
              seed: seed,
            ),
        },
        {'Flipping through your Tems records…', 'Pulling your Tems records…'},
      );
      expect(
        {
          for (var seed = 0; seed < 4; seed++)
            line(
              const TurnStep('digging', scope: 'catalogue', artists: tems),
              seed: seed,
            ),
        },
        {'Digging for Tems…', 'Crate-digging for Tems…'},
      );
      expect(
        {
          for (var seed = 0; seed < 4; seed++)
            line(const TurnStep('picking', artists: tems), seed: seed),
        },
        {'Pulling records that sit with Tems…', 'Finding company for Tems…'},
      );
      // Two artists, three read as "and more"; at most two genres.
      expect(
        line(
          const TurnStep(
            'digging',
            scope: 'catalogue',
            artists: ['Tems', 'Asake'],
          ),
          seed: 0,
        ),
        isIn([
          'Digging for Tems and Asake…',
          'Crate-digging for Tems and Asake…',
        ]),
      );
      expect(
        line(
          const TurnStep(
            'digging',
            scope: 'catalogue',
            artists: ['Tems', 'Asake', 'Wizkid'],
          ),
        ),
        isIn([
          'Digging for Tems, Asake and more…',
          'Crate-digging for Tems, Asake and more…',
        ]),
      );
      expect(
        line(const TurnStep('checking', genres: ['Afrobeats'])),
        'Running the Afrobeats sound check…',
      );
      expect(
        line(const TurnStep('checking', genres: ['Jazz', 'Soul', 'Funk'])),
        'Running the Jazz and Soul sound check…',
      );
      expect(
        line(const TurnStep('playlists', playlist: 'Late nights')),
        'Pulling “Late nights” off the shelf…',
      );
      expect(
        line(const TurnStep('labelling', title: 'Rainy Commute')),
        'Labelling it “Rainy Commute”…',
      );
      expect(
        line(const TurnStep('pressing', count: 24)),
        'Pressing 24 songs to tape…',
      );
      expect(
        line(const TurnStep('pressing', count: 1)),
        'Pressing one song to tape…',
      );
    });

    test('a named line past 44 characters says the nameless one', () {
      const nameless = ['Pulling records that fit…', 'Cueing up contenders…'];
      const crowd = TurnStep(
        'picking',
        artists: ['Burna Boy', 'Asake', 'Tems'],
      );
      for (var seed = 0; seed < 4; seed++) {
        expect(line(crowd, seed: seed), isIn(nameless));
      }
      expect(
        line(
          const TurnStep(
            'labelling',
            title: 'Slow Burn Sunday Morning Records',
          ),
        ),
        'Labelling the cassette…',
      );
      for (var seed = 0; seed < 4; seed++) {
        expect(
          line(
            const TurnStep('picking', artists: ['Tems', 'Asake', 'Burna Boy']),
            seed: seed,
          ).length,
          lessThanOrEqualTo(44),
        );
      }
    });

    test('later lines take over every 12 s; any step past 30 s holds', () {
      const picking = TurnStep('picking', artists: ['Tems']);
      expect(line(picking, seconds: 11), isNot('Sequencing the tracklist…'));
      expect(line(picking, seconds: 12), 'Sequencing the tracklist…');
      expect(line(picking, seconds: 24), 'Lining up the transitions…');
      expect(line(picking, seconds: 30), still);
      expect(line(picking, seconds: 600), still);
      const crates = TurnStep('digging', scope: 'catalogue');
      expect(line(crates, seconds: 12), 'Deeper in the crates…');
      expect(
        line(const TurnStep('digging', scope: 'library'), seconds: 12),
        'Still flipping…',
      );
      expect(
        line(const TurnStep('labelling'), seconds: 12),
        'Labelling the cassette…',
      );
      expect(line(const TurnStep('labelling'), seconds: 30), still);
      expect(line(null, seconds: 29), listening);
      expect(line(null, seconds: 30), still);
      expect(
        DjWorkingPhrases.untilNextStepLine(picking, const Duration(seconds: 5)),
        const Duration(seconds: 7),
      );
      expect(
        DjWorkingPhrases.untilNextStepLine(
          picking,
          const Duration(seconds: 25),
        ),
        const Duration(seconds: 5),
      );
      expect(
        DjWorkingPhrases.untilNextStepLine(
          picking,
          const Duration(seconds: 30),
        ),
        isNull,
      );
    });

    testWidgets('with no stream the clock walks on, however often it builds', (
      tester,
    ) async {
      final step = ValueNotifier<WorkingStep?>(null);
      await _pump(tester, _Following(step: step), reducedMotion: true);
      await tester.pump(const Duration(seconds: 3));
      step.value = null;
      await tester.pump(const Duration(seconds: 2));
      expect(
        find.text(
          DjWorkingPhrases.mix.lineAt(const Duration(seconds: 5), seed: 0),
        ),
        findsOneWidget,
      );
    });

    testWidgets('once the stream opens the clock stops: listening holds', (
      tester,
    ) async {
      final step = ValueNotifier<WorkingStep?>(null);
      await _pump(tester, _Following(step: step), reducedMotion: true);
      await tester.pump(const Duration(milliseconds: 600));
      step.value = WorkingStep.listening(DateTime.now());
      await tester.pump();
      // Well past the clock's 4 s: still listening.
      await tester.pump(const Duration(seconds: 15));
      expect(find.text(listening), findsOneWidget);
      // A stream that sends nothing for 30 s still says it is working on it.
      await tester.pump(const Duration(seconds: 15));
      expect(find.text(still), findsOneWidget);
    });

    testWidgets(
      'a stream opening after the clock moved goes back to listening',
      (tester) async {
        final step = ValueNotifier<WorkingStep?>(null);
        await _pump(tester, _Following(step: step), reducedMotion: true);
        // The clock's second line went up at 4 s and has held its 1.5 s.
        await tester.pump(const Duration(seconds: 6));
        expect(find.text(listening), findsNothing);
        step.value = WorkingStep.listening(DateTime.now());
        await tester.pump();
        expect(find.text(listening), findsOneWidget);
      },
    );

    testWidgets('each step shows its line; an unknown one keeps the line', (
      tester,
    ) async {
      final step = ValueNotifier<WorkingStep?>(
        WorkingStep.listening(DateTime.now()),
      );
      await _pump(tester, _Following(step: step), reducedMotion: true);
      expect(find.text(listening), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));

      const crates = TurnStep('digging', scope: 'catalogue', artists: ['Tems']);
      step.value = WorkingStep(crates, DateTime.now());
      await tester.pump();
      expect(find.text(line(crates)), findsOneWidget);
      expect(line(crates), contains('Tems'));

      await tester.pump(const Duration(seconds: 2));
      step.value = WorkingStep(const TurnStep('tuning'), DateTime.now());
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(find.text(line(crates)), findsOneWidget);
      // The step's own clock keeps running through it.
      await tester.pump(const Duration(seconds: 9));
      expect(find.text('Deeper in the crates…'), findsOneWidget);
    });

    testWidgets('a line holds 1.5 s; a step superseded meanwhile is skipped', (
      tester,
    ) async {
      final step = ValueNotifier<WorkingStep?>(
        WorkingStep.listening(DateTime.now()),
      );
      await _pump(tester, _Following(step: step), reducedMotion: true);
      // 0.5 s in: the listening line has not held its 1.5 s yet.
      await tester.pump(const Duration(milliseconds: 500));
      step.value = WorkingStep(const TurnStep('labelling'), DateTime.now());
      await tester.pump();
      expect(find.text(listening), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 999));
      expect(find.text(listening), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('Labelling the cassette…'), findsOneWidget);

      // 0.2 s later a note, then 0.1 s later the reply: the note never shows.
      await tester.pump(const Duration(milliseconds: 200));
      step.value = WorkingStep(const TurnStep('noting'), DateTime.now());
      await tester.pump(const Duration(milliseconds: 100));
      step.value = WorkingStep(const TurnStep('writing'), DateTime.now());
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('Jotting that on the sleeve…'), findsNothing);
      }
      expect(find.text('Writing the liner notes…'), findsOneWidget);
    });

    testWidgets('within a step the line moves on at 12 s, and holds at 30 s', (
      tester,
    ) async {
      const picking = TurnStep('picking');
      final step = ValueNotifier<WorkingStep?>(
        WorkingStep(picking, DateTime.now()),
      );
      await _pump(tester, _Following(step: step), reducedMotion: true);
      expect(find.text(line(picking)), findsOneWidget);
      await tester.pump(const Duration(seconds: 12));
      expect(find.text('Sequencing the tracklist…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 12));
      expect(find.text('Lining up the transitions…'), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      expect(find.text(still), findsOneWidget);
      // A step that arrives anew (a replacement round names the artists)
      // starts a clock of its own.
      const named = TurnStep('picking', artists: ['Tems']);
      step.value = WorkingStep(named, DateTime.now());
      await tester.pump(const Duration(seconds: 2));
      expect(find.text(still), findsNothing);
      expect(find.text(line(named)), findsOneWidget);
    });

    testWidgets('a step already under way picks up where it had got to', (
      tester,
    ) async {
      await _pump(
        tester,
        WorkingCassette(
          seed: 0,
          startedAt: DateTime.now().subtract(const Duration(seconds: 40)),
          step: WorkingStep(
            const TurnStep('picking'),
            DateTime.now().subtract(const Duration(seconds: 13)),
          ),
        ),
        reducedMotion: true,
      );
      expect(find.text('Sequencing the tracklist…'), findsOneWidget);
    });

    testWidgets('one line, cut with an ellipsis; VoiceOver hears no names', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        WorkingCassette(
          seed: 0,
          step: WorkingStep(
            const TurnStep('playlists', playlist: 'Late nights'),
            DateTime.now(),
          ),
        ),
        width: 160,
      );
      final caption = tester.widget<Text>(
        find.descendant(
          of: find.byKey(WorkingCassette.captionKey),
          matching: find.byType(Text),
        ),
      );
      expect(caption.data, 'Pulling “Late nights” off the shelf…');
      expect(caption.maxLines, 1);
      expect(caption.overflow, TextOverflow.ellipsis);
      expect(caption.softWrap, isFalse);
      expect(
        tester.getSemantics(find.byKey(WorkingCassette.indicatorKey)).label,
        'The DJ is working',
      );
      handle.dispose();
    });
  });

  testWidgets('working: a 44 pt cassette in the tape colour, announced', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    const denim = Color(0xFF617F9C);
    await _pump(tester, const WorkingCassette(caseColor: denim));
    final cassette = tester.widget<CassetteTile>(
      find.byKey(WorkingCassette.cassetteKey),
    );
    // Device smoke 2026-11-13: down from 56, which read too large.
    expect(cassette.width, 44);
    expect(cassette.caseColor, denim);
    expect(cassette.spinning, isTrue);
    expect(
      tester
          .state<CassetteTileState>(find.byKey(WorkingCassette.cassetteKey))
          .isSpinning,
      isTrue,
    );
    expect(find.text('The DJ is listening…'), findsOneWidget);
    final node = tester.getSemantics(find.byKey(WorkingCassette.indicatorKey));
    expect(node.label, 'The DJ is working');
    expect(node.flagsCollection.isLiveRegion, isTrue);
    handle.dispose();
  });

  testWidgets('working under reduced motion: the hubs stand still', (
    tester,
  ) async {
    await _pump(tester, const WorkingCassette(), reducedMotion: true);
    expect(
      tester
          .state<CassetteTileState>(find.byKey(WorkingCassette.cassetteKey))
          .isSpinning,
      isFalse,
    );
    // Before the first mix: the default case.
    expect(
      tester
          .widget<CassetteTile>(find.byKey(WorkingCassette.cassetteKey))
          .caseColor,
      CassetteTile.caseColors.first,
    );
  });

  group('the fade', () {
    test('full in the lower half, 34% above it, eased between', () {
      double at(double bottom) => LyricFade.opacityFor(
        itemBottom: bottom,
        visibleTop: 0,
        visibleBottom: 600,
      );
      expect(at(590), 1);
      expect(at(300), 1);
      expect(at(100), LyricFade.fadedOpacity);
      final eased = at(300 - LyricFade.ramp / 2);
      expect(eased, greaterThan(LyricFade.fadedOpacity));
      expect(eased, lessThan(1));
    });

    testWidgets('older turns fade as they scroll away; semantics unaffected', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: MixtapeTheme.light(),
          home: Scaffold(
            body: ListView.builder(
              controller: controller,
              addRepaintBoundaries: false,
              itemCount: 30,
              itemBuilder: (context, index) => LyricFade(
                key: ValueKey('fade-$index'),
                child: SizedBox(height: 80, child: Text('Line $index')),
              ),
            ),
          ),
        ),
      );
      RenderLyricFade fade(int index) =>
          tester.renderObject(find.byKey(ValueKey('fade-$index')));

      // The first lines sit in the top half: faded. Further down: full.
      expect(fade(0).lastOpacity, LyricFade.fadedOpacity);
      expect(fade(6).lastOpacity, 1);
      // VoiceOver still reads the faded line.
      expect(find.bySemanticsLabel('Line 0'), findsOneWidget);

      // Scrolled, a line that was bright moves up and fades.
      controller.jumpTo(400);
      await tester.pump();
      expect(fade(6).lastOpacity, LyricFade.fadedOpacity);
      expect(fade(10).lastOpacity, 1);
      handle.dispose();
    });
  });

  group('version markers', () {
    testWidgets('an earlier one opens history; the current one reads current', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      var opened = 0;
      const denim = Color(0xFF617F9C);
      await _pump(
        tester,
        Column(
          children: [
            VersionMarker(
              key: VersionMarker.keyFor(1),
              version: 1,
              caseColor: denim,
              onOpen: () => opened++,
            ),
            VersionMarker(
              key: VersionMarker.keyFor(2),
              version: 2,
              caseColor: denim,
              songs: 13,
              current: true,
              onOpen: () => opened++,
            ),
          ],
        ),
      );
      final cassettes = tester.widgetList<CassetteTile>(
        find.byType(CassetteTile),
      );
      expect(cassettes.map((c) => c.width), [34, 34]);
      expect(cassettes.map((c) => c.caseColor), [denim, denim]);
      expect(find.textContaining('13 songs · current'), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);

      await tester.tap(find.byKey(VersionMarker.keyFor(2)));
      expect(opened, 0);
      await tester.tap(find.byKey(VersionMarker.keyFor(1)));
      expect(opened, 1);

      final earlier = tester.getSemantics(find.bySemanticsLabel('Version 1'));
      expect(earlier.flagsCollection.isButton, isTrue);
      expect(earlier.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      expect(
        find.bySemanticsLabel('Version 2, 13 songs · current'),
        findsOneWidget,
      );
      handle.dispose();
    });
  });
}
