// Home's bottom panel (plan `docs/superpowers/plans/2026-09-17-native-design-
// implementation.md` tasks 3.1 and 3.2; frames H1/H2 in
// `docs/mockups/2026-09-17-mobile-shell-r3.html` and the Home states board).
//
// The panel owns the composer (with its static hint), the failure line and
// one row of idea pills drifting in a loop: the routine suggestion first when
// one is eligible, then every starter prompt. Pills fill the field and never
// send. Widget tests see the row still (`test/flutter_test_config.dart`).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/providers/device_providers.dart';
import 'package:mixtape/presentation/providers/suggestions_provider.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/idea_marquee.dart';
import 'package:mixtape/presentation/widgets/foundation/idea_pill.dart';
import 'package:mixtape/presentation/widgets/foundation/liquid_glass_surface.dart';
import 'package:mixtape/presentation/widgets/home_panel.dart';
import 'package:mixtape/presentation/widgets/mix_prompt_input.dart';
import 'package:mixtape/presentation/widgets/routine_suggestions.dart';

import '../../screens/routine_suggestions_test.dart' show FakeSuggestions;

/// The starter prompts the panel shows: all of the composer's examples, since
/// the field's hint is no longer one of them.
List<String> get _starters => MixPromptInput.examples;

class _Harness {
  _Harness({FakeSuggestions? api})
    : api = api ?? FakeSuggestions(),
      controller = TextEditingController(),
      focus = FocusNode();

  final FakeSuggestions api;
  final TextEditingController controller;
  final FocusNode focus;
  int submits = 0;

  void dispose() {
    controller.dispose();
    focus.dispose();
  }
}

Future<_Harness> _pumpPanel(
  WidgetTester tester, {
  FakeSuggestions? api,
  TimeZoneReader? readZone,
  bool busy = false,
  String? error,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);

  final harness = _Harness(api: api);
  addTearDown(harness.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        suggestionsApiProvider.overrideWithValue(harness.api),
        suggestionTimeZoneProvider.overrideWithValue(
          readZone ?? () async => 'UTC',
        ),
      ],
      child: MaterialApp(
        theme: brightness == Brightness.dark
            ? MixtapeTheme.dark()
            : MixtapeTheme.light(),
        home: Scaffold(
          backgroundColor: Colors.transparent,
          resizeToAvoidBottomInset: false,
          body: Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: HomePanel(
                  controller: harness.controller,
                  focusNode: harness.focus,
                  busy: busy,
                  error: error,
                  onSubmit: () => harness.submits++,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return harness;
}

List<IdeaPill> _pills(WidgetTester tester) =>
    tester.widgetList<IdeaPill>(find.byType(IdeaPill)).toList();

void main() {
  testWidgets('switching modes retains the loaded routine suggestion', (
    tester,
  ) async {
    final api = FakeSuggestions();
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    Future<void> show(bool mix) => tester.pumpWidget(
      ProviderScope(
        overrides: [
          suggestionsApiProvider.overrideWithValue(api),
          suggestionTimeZoneProvider.overrideWithValue(() async => 'UTC'),
        ],
        child: MaterialApp(
          theme: MixtapeTheme.light(),
          home: Scaffold(
            body: HomePanel(
              controller: controller,
              onSubmit: () {},
              routineSuggestion: mix,
            ),
          ),
        ),
      ),
    );
    await show(true);
    await tester.pumpAndSettle();
    expect(api.loads, 1);
    await show(false);
    await tester.pumpAndSettle();
    await show(true);
    await tester.pump();
    expect(api.loads, 1);
    expect(find.text(FakeSuggestions.eligible.title), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('the panel is as round as a bottom sheet', (tester) async {
    // The founder's smoke round three, note 2: 24 read like a card.
    expect(HomePanel.floatingRadius, 32);

    await _pumpPanel(tester);
    await tester.pumpAndSettle();

    final surface = tester.widget<LiquidGlassSurface>(
      find.byKey(HomePanel.surfaceKey),
    );
    expect(
      surface.borderRadius,
      BorderRadius.circular(HomePanel.floatingRadius),
    );
  });

  testWidgets('the pills sit on one row, 8 pt apart', (tester) async {
    // Home tidy, 2026-11-17: one sideways row instead of wrapped rows.
    await _pumpPanel(tester);
    await tester.pumpAndSettle();

    expect(find.byKey(IdeaMarquee.rowKey), findsOneWidget);
    final rects = find
        .byType(IdeaPill)
        .evaluate()
        .map((e) => tester.getRect(find.byWidget(e.widget)))
        .toList();
    expect(rects.length, 1 + _starters.length);
    for (var i = 1; i < rects.length; i++) {
      expect(rects[i].top, moreOrLessEquals(rects[0].top, epsilon: 0.5));
      expect(
        rects[i].left - rects[i - 1].right,
        moreOrLessEquals(HomePanel.pillGap, epsilon: 0.5),
      );
    }
  });

  testWidgets('the row runs to the glass edges; the first pill lines up', (
    tester,
  ) async {
    await _pumpPanel(tester);
    await tester.pumpAndSettle();

    final panel = tester.getRect(find.byKey(HomePanel.surfaceKey));
    final row = tester.getRect(find.byKey(IdeaMarquee.rowKey));
    expect(row.left, moreOrLessEquals(panel.left, epsilon: 0.5));
    expect(row.right, moreOrLessEquals(panel.right, epsilon: 0.5));
    final first = tester.getRect(find.byType(IdeaPill).first);
    expect(
      first.left,
      moreOrLessEquals(panel.left + HomePanel.sidePadding, epsilon: 0.5),
    );
  });

  testWidgets('the panel draws the composer and a row of pills', (
    tester,
  ) async {
    await _pumpPanel(tester);
    await tester.pumpAndSettle();

    expect(find.byType(MixPromptInput), findsOneWidget);
    expect(find.byKey(const Key('prompt-field')), findsOneWidget);
    final pills = _pills(tester);
    expect(pills.length, 1 + _starters.length);
    expect(pills.first.label, FakeSuggestions.eligible.title);
    expect(pills[1].label, _starters[0]);
    // The composer sits above the pills.
    expect(
      tester.getRect(find.byKey(const Key('prompt-field'))).bottom,
      lessThan(tester.getRect(find.byKey(HomePanel.pillsKey)).top),
    );
  });

  testWidgets('only the routine slot is a skeleton while it loads', (
    tester,
  ) async {
    final harness = await _pumpPanel(
      tester,
      api: FakeSuggestions()..loadGate = Completer<void>(),
    );
    await tester.pump();

    var pills = _pills(tester);
    expect(pills.length, 1 + _starters.length);
    expect(pills.first.skeleton, isTrue);
    expect(pills[1].skeleton, isFalse);
    expect(pills[1].label, _starters[0]);

    harness.api.loadGate!.complete();
    await tester.pumpAndSettle();
    pills = _pills(tester);
    expect(pills.first.skeleton, isFalse);
    expect(pills.first.label, FakeSuggestions.eligible.title);
  });

  testWidgets('with nothing eligible the row is the starters alone', (
    tester,
  ) async {
    await _pumpPanel(tester, api: FakeSuggestions()..enabled = false);
    await tester.pumpAndSettle();

    final pills = _pills(tester);
    expect(pills.map((pill) => pill.label), _starters);
    expect(pills.any((pill) => pill.skeleton), isFalse);
    expect(find.byKey(RoutinePillSlot.pillKey), findsNothing);
    expect(find.textContaining('Could not'), findsNothing);
  });

  testWidgets('tapping a starter fills the field, focuses it and never sends', (
    tester,
  ) async {
    final harness = await _pumpPanel(tester);
    await tester.pumpAndSettle();

    // The row scrolls sideways; bring the pill into view first.
    await tester.ensureVisible(find.text(_starters[0]));
    await tester.tap(find.text(_starters[0]));
    await tester.pumpAndSettle();

    expect(harness.controller.text, _starters[0]);
    expect(harness.focus.hasFocus, isTrue);
    expect(harness.submits, 0);
  });

  testWidgets('tapping the routine pill fills the field and never sends', (
    tester,
  ) async {
    final harness = await _pumpPanel(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(RoutinePillSlot.pillKey));
    await tester.pumpAndSettle();

    expect(harness.controller.text, FakeSuggestions.prompt);
    expect(harness.submits, 0);
  });

  testWidgets('every pill dims once the field has text', (tester) async {
    final harness = await _pumpPanel(tester);
    await tester.pumpAndSettle();
    expect(_pills(tester).every((pill) => pill.dimmed), isFalse);

    await tester.enterText(
      find.byKey(const Key('prompt-field')),
      'quiet soul for the evening',
    );
    await tester.pumpAndSettle();

    expect(_pills(tester).every((pill) => pill.dimmed), isTrue);
    // Still usable: the board's swap replaces the draft.
    // The row scrolls sideways; bring the pill into view first.
    await tester.ensureVisible(find.text(_starters[0]));
    await tester.tap(find.text(_starters[0]));
    await tester.pumpAndSettle();
    expect(harness.controller.text, _starters[0]);
  });

  testWidgets('while a mix is starting the pills are dimmed and inert', (
    tester,
  ) async {
    // The composer's send key is a spinner while busy, so this state never
    // settles: pump it by hand.
    final harness = await _pumpPanel(tester, busy: true);
    await tester.pump();
    await tester.pump();

    expect(_pills(tester).every((pill) => pill.dimmed), isTrue);
    await tester.tap(find.text(_starters[0]), warnIfMissed: false);
    await tester.pump();
    expect(harness.controller.text, isEmpty);
    expect(harness.submits, 0);
  });

  testWidgets('the panel floats 12 pt in from both screen edges', (
    tester,
  ) async {
    await _pumpPanel(tester);
    await tester.pumpAndSettle();

    final panel = tester.getRect(find.byKey(HomePanel.surfaceKey));
    expect(panel.left, HomePanel.sideInset);
    expect(panel.right, 390 - HomePanel.sideInset);
  });

  testWidgets('a short idea pill takes only the width its label needs', (
    tester,
  ) async {
    await _pumpPanel(tester);
    await tester.pumpAndSettle();

    final panel = tester.getRect(find.byKey(HomePanel.surfaceKey));
    final pills = tester.getRect(find.byKey(HomePanel.pillsKey));
    for (final pill in find.byType(IdeaPill).evaluate()) {
      final rect = tester.getRect(find.byWidget(pill.widget));
      expect(
        rect.width,
        lessThan(panel.width),
        reason: 'a pill never spans the panel',
      );
      expect(rect.left, greaterThanOrEqualTo(pills.left - 0.01));
    }
  });

  testWidgets('an idea pill is as wide as its own text, not its row', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 360,
              child: Wrap(
                spacing: HomePanel.pillGap,
                children: [
                  IdeaPill(label: 'Coffee'),
                  IdeaPill(label: 'Rain'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final first = tester.getRect(find.byType(IdeaPill).first);
    final second = tester.getRect(find.byType(IdeaPill).last);
    final label = tester.getSize(find.text('Coffee'));
    expect(first.width, lessThan(360));
    expect(
      first.width,
      closeTo(label.width + 28, 0.5),
      reason: 'the shell is the label, 13 pt of padding and a hairline a side',
    );
    expect(
      second.left,
      closeTo(first.right + HomePanel.pillGap, 0.5),
      reason: 'pills sit side by side on one row',
    );
  });

  testWidgets('starter pills have no context menu', (tester) async {
    await _pumpPanel(tester);
    await tester.pumpAndSettle();

    await tester.longPress(find.text(_starters[0]));
    await tester.pumpAndSettle();

    expect(find.text(RoutinePillSlot.notTodayLabel), findsNothing);
  });

  testWidgets('the failure line sits under the composer as a live region', (
    tester,
  ) async {
    await _pumpPanel(tester, error: "couldn't reach the DJ — try again");
    await tester.pumpAndSettle();

    final line = find.byKey(HomePanel.errorKey);
    expect(line, findsOneWidget);
    expect(find.text("couldn't reach the DJ — try again"), findsOneWidget);
    expect(
      tester.getSemantics(line).getSemanticsData().flagsCollection.isLiveRegion,
      isTrue,
    );
    expect(
      tester.getRect(find.byKey(const Key('prompt-field'))).bottom,
      lessThan(tester.getRect(line).top),
    );
  });

  testWidgets('the panel rides the keyboard', (tester) async {
    await _pumpPanel(tester);
    await tester.pumpAndSettle();
    final resting = tester.getRect(find.byKey(const Key('prompt-field')));

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    final lifted = tester.getRect(find.byKey(const Key('prompt-field')));

    expect(lifted.bottom, lessThan(resting.bottom));
    // The board's `.bpanel.kb` keeps a gap above the keyboard.
    expect(lifted.bottom, lessThanOrEqualTo(844 - 300 - HomePanel.keyboardGap));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a closing keyboard never carries the panel below its rest', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final inset = ValueNotifier<double>(0);
    addTearDown(inset.dispose);

    // The shell hands the dock down as bottom padding; the keyboard's inset
    // is set directly so its last frames can be held still.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          suggestionsApiProvider.overrideWithValue(FakeSuggestions()),
          suggestionTimeZoneProvider.overrideWithValue(() async => 'UTC'),
        ],
        child: MaterialApp(
          theme: MixtapeTheme.light(),
          home: ValueListenableBuilder<double>(
            valueListenable: inset,
            builder: (context, keyboard, _) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                padding: const EdgeInsets.only(bottom: 120),
                viewInsets: EdgeInsets.only(bottom: keyboard),
              ),
              child: Scaffold(
                resizeToAvoidBottomInset: false,
                body: Stack(
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: HomePanel(controller: controller, onSubmit: () {}),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Rect field() => tester.getRect(find.byKey(const Key('prompt-field')));
    final resting = field();

    // The last frames of the keyboard sliding away: a sliver of inset left.
    for (final sliver in [60.0, 30.0, 12.0]) {
      inset.value = sliver;
      await tester.pumpAndSettle();
      // Below rest here means a jump back up when the inset reaches zero.
      expect(
        field().bottom,
        lessThanOrEqualTo(resting.bottom),
        reason: '$sliver',
      );
    }

    // Well up, the keyboard still lifts it clear.
    inset.value = 300;
    await tester.pumpAndSettle();
    expect(
      field().bottom,
      lessThanOrEqualTo(844 - 300 - HomePanel.keyboardGap),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('the panel clears the dock inset the shell hands down', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          suggestionsApiProvider.overrideWithValue(FakeSuggestions()),
          suggestionTimeZoneProvider.overrideWithValue(() async => 'UTC'),
        ],
        child: MaterialApp(
          theme: MixtapeTheme.light(),
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(padding: const EdgeInsets.only(bottom: 120)),
              child: Scaffold(
                resizeToAvoidBottomInset: false,
                body: Stack(
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: HomePanel(
                        controller: controller,
                        onSubmit: () {},
                        error:
                            'A long error message that needs enough space to keep the panel scrollable with two suggestions and the keyboard open.',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final pills = tester.getRect(find.byKey(HomePanel.pillsKey));
    expect(pills.bottom, lessThanOrEqualTo(844 - 120));
  });

  testWidgets('at 200% text on a 320 pt phone nothing overflows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          suggestionsApiProvider.overrideWithValue(FakeSuggestions()),
          suggestionTimeZoneProvider.overrideWithValue(() async => 'UTC'),
        ],
        child: MaterialApp(
          theme: MixtapeTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            resizeToAvoidBottomInset: false,
            body: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: HomePanel(
                    controller: controller,
                    error: 'something went wrong on our end — try again',
                    onSubmit: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(_pills(tester).length, 1 + _starters.length);
  });

  testWidgets('the hint is a static "Ask for anything"', (tester) async {
    await _pumpPanel(tester);
    await tester.pumpAndSettle();

    String hint() =>
        (tester
                    .widget<TextField>(find.byKey(const Key('prompt-field')))
                    .decoration!
                    .hint!
                as Text)
            .data!;

    expect(hint(), HomePanel.restingPlaceholder);
    // Where the rotation would have turned several times over.
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(seconds: 5));
      expect(hint(), HomePanel.restingPlaceholder);
    }
  });

  testWidgets('a drag inside the panel never reaches the shell', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    // What the shell's dock listener would have seen.
    final escaped = <ScrollNotification>[];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          suggestionsApiProvider.overrideWithValue(FakeSuggestions()),
          suggestionTimeZoneProvider.overrideWithValue(() async => 'UTC'),
        ],
        child: MaterialApp(
          theme: MixtapeTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              escaped.add(notification);
              return false;
            },
            child: Scaffold(
              resizeToAvoidBottomInset: false,
              body: Stack(
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: HomePanel(
                      controller: controller,
                      onSubmit: () {},
                      error:
                          'A long error message that needs enough space to keep the panel scrollable with two suggestions and the keyboard open.',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Tall enough at 200% with the keyboard up that the panel does scroll:
    // the composer rides up with the content.
    final before = tester.getRect(find.byType(MixPromptInput));
    await tester.drag(find.byType(MixPromptInput), const Offset(0, -80));
    await tester.pumpAndSettle();

    expect(
      tester.getRect(find.byType(MixPromptInput)).top,
      lessThan(before.top),
    );
    expect(escaped, isEmpty);
  });

  testWidgets('renders in the dark theme', (tester) async {
    await _pumpPanel(tester, brightness: Brightness.dark);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(_pills(tester).length, 1 + _starters.length);
  });
}
