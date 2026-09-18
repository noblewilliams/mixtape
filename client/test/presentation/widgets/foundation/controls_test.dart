import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/idea_pill.dart';
import 'package:mixtape/presentation/widgets/foundation/label_chip.dart';
import 'package:mixtape/presentation/widgets/foundation/prism_stripe.dart';
import 'package:mixtape/presentation/widgets/foundation/status_word.dart';
import 'package:mixtape/presentation/widgets/foundation/tape_button.dart';
import 'package:mixtape/presentation/widgets/foundation/text_action.dart';
import 'package:mixtape/presentation/widgets/mix_prompt_input.dart';

Future<void> _pump(WidgetTester tester, Widget child, {bool dark = false}) =>
    tester.pumpWidget(
      MaterialApp(
        theme: dark ? MixtapeTheme.dark() : MixtapeTheme.light(),
        home: Scaffold(
          body: Center(
            child: SingleChildScrollView(
              child: Align(alignment: Alignment.centerLeft, child: child),
            ),
          ),
        ),
      ),
    );

Widget _gallery() => const Wrap(
  spacing: 8,
  runSpacing: 8,
  children: [
    TapeButton(label: 'Play now', onPressed: _noop),
    TapeButton(label: 'Playing', onPressed: _noop, playing: true),
    TapeButton(label: 'Locked'),
    LabelChip(label: 'Create playlist', onPressed: _noop),
    LabelChip(label: 'No hole', onPressed: _noop, hole: false),
    TextAction(label: 'Rename', onPressed: _noop),
    TextAction(label: 'Quiet', onPressed: _noop, quiet: true),
    IdeaPill(label: 'Kitchen, early, coffee on', onPressed: _noop),
    IdeaPill(label: 'Dimmed', onPressed: _noop, dimmed: true),
    IdeaPill(label: 'Loading', skeleton: true),
    StatusWord(label: 'Connected', kind: StatusKind.ok),
    StatusWord(label: 'Waiting', kind: StatusKind.warn),
    StatusWord(label: 'Disconnected', kind: StatusKind.err),
    PrismStripe(),
  ],
);

void _noop() {}

double _targetHeight(WidgetTester tester, Finder control) => tester
    .getSize(
      find
          .descendant(of: control, matching: find.byType(GestureDetector))
          .first,
    )
    .height;

void main() {
  testWidgets('TextAction draws its glyph on the side asked for', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: const Scaffold(
          body: Column(
            children: [
              TextAction(
                label: 'Skip',
                icon: Icons.fast_forward_rounded,
                iconAfter: true,
                onPressed: _noop,
              ),
              TextAction(
                label: 'Sign out',
                icon: Icons.stop_rounded,
                onPressed: _noop,
              ),
            ],
          ),
        ),
      ),
    );
    final skipWord = tester.getRect(find.text('Skip'));
    final forward = tester.getRect(find.byIcon(Icons.fast_forward_rounded));
    expect(forward.left, greaterThan(skipWord.right), reason: 'after the word');
    final outWord = tester.getRect(find.text('Sign out'));
    final logout = tester.getRect(find.byIcon(Icons.stop_rounded));
    expect(logout.right, lessThan(outWord.left), reason: 'before the word');
    expect(
      tester.widget<Icon>(find.byIcon(Icons.stop_rounded)).size,
      TextAction.iconSize,
    );
  });

  testWidgets('every control renders in both themes without exceptions', (
    tester,
  ) async {
    for (final dark in [false, true]) {
      await _pump(tester, _gallery(), dark: dark);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(TapeButton), findsNWidgets(3));
      expect(find.text('Create playlist'), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
    }
  });

  testWidgets('interactive controls keep a 44 pt tall hit target', (
    tester,
  ) async {
    await _pump(tester, _gallery());
    expect(
      _targetHeight(tester, find.byType(TapeButton).first),
      greaterThanOrEqualTo(MixtapeMetrics.minTarget),
    );
    expect(
      _targetHeight(tester, find.byType(LabelChip).first),
      greaterThanOrEqualTo(MixtapeMetrics.minTarget),
    );
    expect(
      _targetHeight(tester, find.byType(TextAction).first),
      greaterThanOrEqualTo(MixtapeMetrics.minTarget),
    );
    expect(
      _targetHeight(tester, find.byType(IdeaPill).first),
      greaterThanOrEqualTo(MixtapeMetrics.minTarget),
    );
  });

  testWidgets('controls grow instead of clipping at 200% text', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(body: SingleChildScrollView(child: _gallery())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(find.byType(TapeButton).first).height,
      greaterThan(MixtapeMetrics.tapeButtonHeight),
    );
    expect(
      tester.getSize(find.byType(LabelChip).first).height,
      greaterThanOrEqualTo(MixtapeMetrics.chipHeight),
    );
  });

  testWidgets('long labels ellipsize instead of overflowing a narrow row', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: const MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: Center(
              child: SizedBox(
                width: 200,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LabelChip(label: 'Create playlist'),
                    TapeButton(label: 'Unavailable in your region'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    for (final label in ['Create playlist', 'Unavailable in your region']) {
      expect(
        tester.widget<Text>(find.text(label)).overflow,
        TextOverflow.ellipsis,
      );
    }
    expect(
      tester.getSize(find.byType(LabelChip)).width,
      lessThanOrEqualTo(200),
    );
    expect(
      tester.getSize(find.byType(TapeButton)).width,
      lessThanOrEqualTo(200),
    );
  });

  testWidgets('the tape button wears the prism along its bottom edge', (
    tester,
  ) async {
    await _pump(
      tester,
      TapeButton(label: 'Play now', onPressed: () {}),
    );

    final stripe = find.descendant(
      of: find.byType(TapeButton),
      matching: find.byKey(TapeButton.stripeKey),
    );
    expect(stripe, findsOneWidget, reason: 'the prism is inside the shell');

    final button = tester.getRect(find.byType(TapeButton));
    final shell = tester.getRect(
      find.descendant(
        of: find.byType(TapeButton),
        matching: find.byType(ClipRRect),
      ),
    );
    final rect = tester.getRect(stripe);
    expect(
      rect.bottom,
      closeTo(shell.bottom, 0.5),
      reason: 'it sits at the bottom of the shell',
    );
    expect(rect.height, TapeButton.stripeHeight);
    expect(
      rect.width,
      closeTo(shell.width, 0.5),
      reason: 'full width, edge to edge',
    );
    // The label is still centred over it, not pushed off.
    final label = tester.getRect(find.text('Play now'));
    expect(label.center.dx, closeTo(button.center.dx, 0.5));
    expect(label.bottom, lessThanOrEqualTo(rect.top + 1));
  });

  testWidgets('a disabled tape button never calls onPressed', (tester) async {
    var taps = 0;
    await _pump(
      tester,
      Column(
        children: [
          TapeButton(label: 'Live', onPressed: () => taps++),
          const TapeButton(label: 'Locked'),
        ],
      ),
    );
    await tester.tap(find.text('Locked'), warnIfMissed: false);
    await tester.pump();
    expect(taps, 0);
    await tester.tap(find.text('Live'));
    await tester.pump();
    expect(taps, 1);
    final semantics = tester.getSemantics(find.byType(TapeButton).last);
    expect(semantics.flagsCollection.isButton, isTrue);
    expect(semantics.flagsCollection.isEnabled, isFalse);
  });

  testWidgets('every control is one VoiceOver can activate', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      const Wrap(
        children: [
          TapeButton(label: 'Play now', onPressed: _noop),
          LabelChip(label: 'Create playlist', onPressed: _noop),
          TextAction(label: 'Rename', onPressed: _noop),
          IdeaPill(label: 'Kitchen, early, coffee on', onPressed: _noop),
        ],
      ),
    );

    for (final label in [
      'Play now',
      'Create playlist',
      'Rename',
      'Kitchen, early, coffee on',
    ]) {
      final data = tester
          .getSemantics(find.bySemanticsLabel(label))
          .getSemanticsData();
      expect(
        data.hasAction(SemanticsAction.tap),
        isTrue,
        reason:
            '$label: a node with no tap action cannot be activated by '
            'VoiceOver',
      );
      expect(data.flagsCollection.isButton, isTrue);
    }

    handle.dispose();
  });

  testWidgets('a disabled control offers VoiceOver no action', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      const Wrap(
        children: [
          TapeButton(label: 'Locked'),
          LabelChip(label: 'Unavailable'),
          TextAction(label: 'Quiet'),
          IdeaPill(label: 'Ignored', skeleton: true),
        ],
      ),
    );

    for (final label in [
      'Locked',
      'Unavailable',
      'Quiet',
      IdeaPill.skeletonLabel,
    ]) {
      final data = tester
          .getSemantics(find.bySemanticsLabel(label))
          .getSemanticsData();
      expect(
        data.hasAction(SemanticsAction.tap),
        isFalse,
        reason: '$label is disabled and must offer no action',
      );
    }

    handle.dispose();
  });

  testWidgets('a tape button centres its label in the shell at 1x and 2x text', (
    tester,
  ) async {
    for (final scale in [1.0, 2.0]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: MixtapeTheme.light(),
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: const Scaffold(
              body: Center(child: TapeButton(label: 'Start a mix')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = tester.getRect(find.byType(TapeButton));
      final label = tester.getRect(find.text('Start a mix'));
      expect(
        (label.center.dy - button.center.dy).abs(),
        lessThan(0.5),
        reason: 'the label rides the middle of the shell at ${scale}x text',
      );
    }
  });

  testWidgets('a tape button draws no glyph unless one is handed to it', (
    tester,
  ) async {
    await _pump(
      tester,
      const Wrap(children: [TapeButton(label: 'Start a mix')]),
    );
    expect(
      find.descendant(
        of: find.byType(TapeButton),
        matching: find.byType(CustomPaint),
      ),
      findsNothing,
      reason: 'the reel is gone from the default tape button',
    );

    await _pump(
      tester,
      const Wrap(
        children: [
          TapeButton(
            label: 'Start a mix',
            leading: Icon(Icons.play_arrow, key: Key('given-leading')),
          ),
        ],
      ),
    );
    expect(find.byKey(const Key('given-leading')), findsOneWidget);
  });

  testWidgets('a playing tape button is wider than the same idle button', (
    tester,
  ) async {
    await _pump(tester, const Wrap(children: [TapeButton(label: 'Playing')]));
    final idle = tester.getSize(find.byType(TapeButton)).width;
    await _pump(
      tester,
      const Wrap(children: [TapeButton(label: 'Playing', playing: true)]),
    );
    expect(tester.getSize(find.byType(TapeButton)).width, greaterThan(idle));
  });

  testWidgets('a skeleton idea pill is a labelled blank', (tester) async {
    await _pump(
      tester,
      const Wrap(children: [IdeaPill(label: 'Ignored', skeleton: true)]),
    );
    expect(
      find.descendant(of: find.byType(IdeaPill), matching: find.byType(Text)),
      findsNothing,
    );
    expect(find.bySemanticsLabel('Checking your usual moments'), findsOne);
    expect(
      tester.getSize(find.byType(IdeaPill)).width,
      greaterThanOrEqualTo(120),
    );
  });

  testWidgets('status words use the matching token ink', (tester) async {
    await _pump(tester, _gallery());
    final tokens = MixtapeTokens.light;
    expect(
      tester.widget<Text>(find.text('Connected')).style?.color,
      tokens.okInk,
    );
    expect(
      tester.widget<Text>(find.text('Waiting')).style?.color,
      tokens.warnInk,
    );
    expect(
      tester.widget<Text>(find.text('Disconnected')).style?.color,
      tokens.errInk,
    );
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Waiting'),
          matching: find.byType(StatusWord),
        ),
        matching: find.byType(Icon),
      ),
      findsNothing,
      reason: 'warn carries no icon by default',
    );
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('Connected'),
          matching: find.byType(StatusWord),
        ),
        matching: find.byType(Icon),
      ),
      findsOne,
    );
  });

  testWidgets('the prism stripe paints the five-stop vertical prism', (
    tester,
  ) async {
    await _pump(tester, const PrismStripe());
    final box = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byType(PrismStripe),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final decoration = box.decoration as BoxDecoration;
    final gradient = decoration.gradient! as LinearGradient;
    expect(gradient.colors, hasLength(5));
    expect(gradient.colors, MixtapeTokens.light.prism.take(5));
    expect(tester.getSize(find.byType(PrismStripe)), const Size(4, 26));
  });

  testWidgets('the composer hides the mic and shows send only with text', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    Future<void> render() => tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Scaffold(
          body: MixPromptInput(
            controller: controller,
            busy: false,
            onSubmit: () {},
            showVoiceInput: false,
          ),
        ),
      ),
    );
    await render();
    expect(find.byIcon(Icons.mic_none), findsNothing);
    double stripeOpacity() =>
        tester.widget<Opacity>(find.byKey(const Key('prompt-stripe'))).opacity;
    expect(stripeOpacity(), 1, reason: 'the stripe shows while unfocused');

    Color? surfaceColor() {
      final box = tester.widget<DecoratedBox>(
        find.byKey(const Key('send-surface')),
      );
      return (box.decoration as BoxDecoration).color;
    }

    // Nothing to send: the key is not drawn at all (smoke round two, note 9).
    expect(find.byKey(const Key('send-surface')), findsNothing);
    await tester.enterText(find.byKey(const Key('prompt-field')), 'A drive');
    await tester.pump();
    expect(find.byKey(const Key('send-surface')), findsOneWidget);
    expect(surfaceColor(), isNot(Colors.transparent));
    expect(stripeOpacity(), 0, reason: 'focus hands the field to the ring');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the composer draws the mic only when voice input is on', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    Future<void> render({required bool voice}) => tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Scaffold(
          body: MixPromptInput(
            controller: controller,
            busy: false,
            onSubmit: () {},
            showVoiceInput: voice,
          ),
        ),
      ),
    );
    final semantics = tester.ensureSemantics();
    await render(voice: false);
    expect(find.byKey(const Key('voice-input')), findsNothing);

    await render(voice: true);
    expect(find.byKey(const Key('voice-input')), findsOne);
    expect(find.byIcon(Icons.mic_none), findsOne);
    expect(
      tester.getSemantics(find.byKey(const Key('voice-input'))).label,
      'Speak your idea',
    );
    final mic = tester.getSize(find.byKey(const Key('voice-input')));
    expect(mic.height, greaterThanOrEqualTo(MixtapeMetrics.minTarget));
    expect(mic.width, greaterThanOrEqualTo(MixtapeMetrics.minTarget));
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });
}
