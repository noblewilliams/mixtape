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

  testWidgets('working: a 56 pt cassette in the tape colour, announced', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    const denim = Color(0xFF617F9C);
    await _pump(tester, const WorkingCassette(caseColor: denim));
    final cassette = tester.widget<CassetteTile>(
      find.byKey(WorkingCassette.cassetteKey),
    );
    expect(cassette.width, 56);
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
