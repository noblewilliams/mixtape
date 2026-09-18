// The conversation's turns (plan `docs/superpowers/plans/2026-09-17-native-
// design-implementation.md` task 4.2; `.turn`, `.turn.me`, `.turn.dj`,
// `.turn.err` and `.dots` on
// `docs/mockups/2026-09-17-mobile-conversation-states.html`).
//
// User turns are tape-coloured on the right, DJ turns are glass on the left
// with NO accent bar, and a failed turn is err-tinted with Resend.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/conversation_turn.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
  bool reducedMotion = false,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: brightness == Brightness.dark
          ? MixtapeTheme.dark()
          : MixtapeTheme.light(),
      builder: (context, inner) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
        child: inner!,
      ),
      home: Scaffold(body: Align(alignment: Alignment.topCenter, child: child)),
    ),
  );
  await tester.pump();
}

BoxDecoration _decoration(WidgetTester tester, Key key) =>
    tester.widget<Container>(find.byKey(key)).decoration! as BoxDecoration;

void main() {
  testWidgets('a user turn is tape-filled with tape ink, right aligned', (
    tester,
  ) async {
    await _pump(
      tester,
      const ConversationTurn(text: 'last bus home', kind: ConversationTurnKind.user),
    );

    final tokens = MixtapeTokens.light;
    expect(_decoration(tester, ConversationTurn.userKey).color, tokens.tapeFill);
    expect(
      _decoration(tester, ConversationTurn.userKey).borderRadius,
      ConversationTurn.userRadius,
    );
    expect(tester.widget<Text>(find.text('last bus home')).style?.color, tokens.tapeInk);

    final align = tester.widget<Align>(
      find.ancestor(of: find.text('last bus home'), matching: find.byType(Align)).first,
    );
    expect(align.alignment, Alignment.centerRight);
  });

  testWidgets('a DJ turn is glass, left aligned, with no accent bar', (tester) async {
    await _pump(
      tester,
      const ConversationTurn(text: 'eighteen songs', kind: ConversationTurnKind.dj),
    );

    expect(
      _decoration(tester, ConversationTurn.djKey).color,
      ConversationTurn.djFillLight,
    );
    expect(
      _decoration(tester, ConversationTurn.djKey).borderRadius,
      ConversationTurn.djRadius,
    );
    expect(
      tester.widget<Text>(find.text('eighteen songs')).style?.color,
      MixtapeTokens.light.text,
    );
    // The board's departure from the shipped screen: no decorative left bar.
    expect(find.byKey(const Key('dj-accent-bar')), findsNothing);

    final align = tester.widget<Align>(
      find.ancestor(of: find.text('eighteen songs'), matching: find.byType(Align)).first,
    );
    expect(align.alignment, Alignment.centerLeft);
  });

  testWidgets('a DJ turn takes the dark fill in dark mode', (tester) async {
    await _pump(
      tester,
      const ConversationTurn(text: 'eighteen songs', kind: ConversationTurnKind.dj),
      brightness: Brightness.dark,
    );

    expect(
      _decoration(tester, ConversationTurn.djKey).color,
      ConversationTurn.djFillDark,
    );
    expect(
      tester.widget<Text>(find.text('eighteen songs')).style?.color,
      MixtapeTokens.dark.text,
    );
  });

  testWidgets('an error turn is err-tinted with err ink and a 36 pt Resend', (
    tester,
  ) async {
    var resends = 0;
    await _pump(
      tester,
      ConversationTurn(
        text: "Couldn't reach the DJ.",
        kind: ConversationTurnKind.error,
        onResend: () => resends++,
      ),
    );

    expect(
      _decoration(tester, ConversationTurn.errorKey).color,
      ConversationTurn.errorFill,
    );
    expect(
      tester.widget<Text>(find.text("Couldn't reach the DJ.")).style?.color,
      MixtapeTokens.light.errInk,
    );

    final resend = find.byKey(ConversationTurn.resendKey);
    expect(tester.getSize(resend).height, ConversationTurn.resendSize);
    await tester.tap(resend);
    expect(resends, 1);
  });

  testWidgets('Resend renders but is inert while another send is in flight', (
    tester,
  ) async {
    var resends = 0;
    await _pump(
      tester,
      ConversationTurn(
        text: 'failed',
        kind: ConversationTurnKind.error,
        onResend: () => resends++,
        resendEnabled: false,
      ),
    );

    expect(find.byKey(ConversationTurn.resendKey), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byKey(ConversationTurn.resendKey)).onPressed,
      isNull,
    );
    await tester.tap(find.byKey(ConversationTurn.resendKey));
    expect(resends, 0);
  });

  testWidgets('an error turn with nothing to resend draws no button', (tester) async {
    await _pump(
      tester,
      const ConversationTurn(text: 'a stray apology', kind: ConversationTurnKind.error),
    );

    expect(find.byKey(ConversationTurn.errorKey), findsOneWidget);
    expect(find.byKey(ConversationTurn.resendKey), findsNothing);
  });

  testWidgets('no turn is wider than 86% of the transcript', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: Column(
              children: const [
                ConversationTurn(
                  text: 'a very long turn that would happily run the whole width '
                      'of the transcript if nothing stopped it',
                  kind: ConversationTurnKind.dj,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.getSize(find.byKey(ConversationTurn.djKey)).width,
      lessThanOrEqualTo(300 * ConversationTurn.maxWidthFraction + 0.01),
    );
  });

  testWidgets('the working indicator shows three dots at once, the caption on delay', (
    tester,
  ) async {
    await _pump(tester, const WorkingIndicator(showCaption: false));

    expect(find.byKey(WorkingIndicator.dotsKey), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(WorkingIndicator.dotsKey),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              (widget.decoration as BoxDecoration).shape == BoxShape.circle,
        ),
      ),
      findsNWidgets(WorkingIndicator.dotCount),
    );
    expect(find.byKey(WorkingIndicator.captionKey), findsNothing);

    await _pump(tester, const WorkingIndicator(showCaption: true));
    expect(find.text('the DJ is listening…'), findsOneWidget);
  });

  testWidgets('the working indicator announces itself and stays still under reduced motion', (
    tester,
  ) async {
    await _pump(
      tester,
      const WorkingIndicator(showCaption: false),
      reducedMotion: true,
    );

    final semantics = tester.widget<Semantics>(
      find.ancestor(
        of: find.byKey(WorkingIndicator.dotsKey),
        matching: find.byType(Semantics),
      ).first,
    );
    expect(semantics.properties.liveRegion, isTrue);
    expect(semantics.properties.label, 'The DJ is working');

    final state = tester.state<WorkingIndicatorState>(find.byType(WorkingIndicator));
    expect(state.isAnimating, isFalse);
  });
}
