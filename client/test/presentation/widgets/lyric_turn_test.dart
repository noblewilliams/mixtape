// The lyric transcript's pieces (board section 1; locked record →
// Transcript, Version markers, Working, Failed turn).
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
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
