import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/presentation/providers/account_provider.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/voice_providers.dart';
import 'package:mixtape/presentation/widgets/ai_consent_sheet.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/prism_stripe.dart';
import 'package:mixtape/presentation/widgets/mix_prompt_input.dart';
import 'package:mixtape/presentation/widgets/voice_level_meter.dart';

import '../../helpers/fake_ai_consent.dart';

class _SessionAuth extends AuthNotifier {
  @override
  AuthStatus build() => AuthStatus.session;
}

void main() {
  testWidgets('long placeholders stay on one line without resizing the field', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    Future<void> show(String hint) => tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Scaffold(
          body: SizedBox(
            width: 280,
            child: MixPromptInput(
              controller: controller,
              busy: false,
              onSubmit: () {},
              placeholder: hint,
            ),
          ),
        ),
      ),
    );
    await show('Short');
    final height = tester.getSize(find.byKey(const Key('prompt-field'))).height;
    await show(
      'Something like my very long favourite playlist name, but softer and slower',
    );
    expect(
      tester.getSize(find.byKey(const Key('prompt-field'))).height,
      height,
    );
    final hint = tester.widget<Text>(
      find.text(
        'Something like my very long favourite playlist name, but softer and slower',
      ),
    );
    expect(hint.maxLines, 1);
    expect(hint.overflow, TextOverflow.ellipsis);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'rotates only empty unfocused prompts and never changes entered text',
    (tester) async {
      final controller = TextEditingController();
      var submits = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MixPromptInput(
              controller: controller,
              busy: false,
              onSubmit: () => submits++,
            ),
          ),
        ),
      );
      expect(find.text('A slow Sunday morning'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 4500));
      expect(find.text('High-energy songs for my workout'), findsOneWidget);
      await tester.tap(find.byKey(const Key('prompt-field')));
      await tester.pump(const Duration(milliseconds: 4500));
      expect(find.text('High-energy songs for my workout'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('prompt-field')),
        'My own prompt',
      );
      await tester.pump(const Duration(seconds: 9));
      expect(controller.text, 'My own prompt');
      await tester.tap(find.byKey(const Key('start-session')));
      expect(submits, 1);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
  testWidgets('the send key takes its name from the owner', (tester) async {
    final handle = tester.ensureSemantics();
    final controller = TextEditingController(text: 'something warm');
    addTearDown(controller.dispose);
    Future<void> pump(String? label) => tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Scaffold(
          body: label == null
              ? MixPromptInput(
                  controller: controller,
                  busy: false,
                  onSubmit: () {},
                )
              : MixPromptInput(
                  controller: controller,
                  busy: false,
                  onSubmit: () {},
                  sendLabel: label,
                ),
        ),
      ),
    );
    String tooltip() => tester
        .widget<IconButton>(find.byKey(const Key('start-session')))
        .tooltip!;

    await pump(null);
    expect(tooltip(), 'Start new mix');
    await pump('Find an album');
    expect(tooltip(), 'Find an album');
    expect(find.bySemanticsLabel('Find an album'), findsOneWidget);
    handle.dispose();
  });
  testWidgets('the send key appears only once the field has text', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Scaffold(
          body: MixPromptInput(
            controller: controller,
            busy: false,
            onSubmit: () {},
            showVoiceInput: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('send-surface')), findsNothing);
    expect(find.byKey(const Key('start-session')), findsNothing);
    expect(
      find.byKey(const Key('voice-input')),
      findsOneWidget,
      reason: 'the mic stays where it is',
    );

    await tester.enterText(find.byKey(const Key('prompt-field')), 'focus');
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('send-surface')), findsOneWidget);
    final mic = tester.getRect(find.byKey(const Key('voice-input')));
    final send = tester.getRect(find.byKey(const Key('start-session')));
    expect(send.left, greaterThanOrEqualTo(mic.right - 0.01));

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the field sits a step down from body text on tighter padding', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Scaffold(
          body: MixPromptInput(
            controller: controller,
            busy: false,
            onSubmit: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
      find.byKey(const Key('prompt-field')),
    );
    final body = MixtapeTokens.light.body.fontSize!;
    expect(field.style?.fontSize, body - 1);
    expect(field.decoration?.hintStyle?.fontSize, body - 1);
    expect(
      field.decoration?.contentPadding,
      const EdgeInsets.symmetric(vertical: MixPromptInput.fieldVerticalPadding),
    );
    // Device smoke 2026-11-13: the field read as mostly padding.
    expect(MixPromptInput.fieldVerticalPadding, 6);

    await tester.pumpWidget(const SizedBox());
  });

  group('compact composer (device smoke 2026-11-13)', () {
    Future<void> pump(
      WidgetTester tester,
      TextEditingController controller, {
      bool busy = false,
      FocusNode? focusNode,
      VoidCallback? onSubmit,
    }) => tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Scaffold(
          body: Column(
            children: [
              const Expanded(
                child: SizedBox.expand(key: Key('outside')),
              ),
              MixPromptInput(
                controller: controller,
                focusNode: focusNode,
                busy: busy,
                showVoiceInput: true,
                onSubmit: onSubmit ?? () {},
              ),
            ],
          ),
        ),
      ),
    );

    testWidgets('one line of draft sits in a 40 pt surface', (tester) async {
      final controller = TextEditingController(text: 'warm');
      addTearDown(controller.dispose);
      await pump(tester, controller);
      await tester.pumpAndSettle();

      expect(MixPromptInput.minHeight, 40);
      expect(
        tester.getSize(find.byKey(MixPromptInput.surfaceKey)).height,
        moreOrLessEquals(MixPromptInput.minHeight, epsilon: 0.5),
      );
      // The text starts 16 pt in, not 22.
      final surface = tester.getRect(find.byKey(MixPromptInput.surfaceKey));
      final field = tester.getRect(find.byKey(const Key('prompt-field')));
      expect(field.left - surface.left, lessThanOrEqualTo(17));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the prism runs along the foot of the field, clear of the text', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'warm');
      addTearDown(controller.dispose);
      await pump(tester, controller);
      await tester.pumpAndSettle();

      final surface = tester.getRect(find.byKey(MixPromptInput.surfaceKey));
      final stripe = tester.getRect(find.byType(PrismStripe));
      final field = tester.getRect(find.byKey(const Key('prompt-field')));
      expect(stripe.height, MixPromptInput.stripeHeight);
      // Along the bottom edge, inside the 1 pt border, clear of the corners.
      expect(surface.bottom - stripe.bottom, lessThanOrEqualTo(1.5));
      expect(
        stripe.left - surface.left,
        greaterThanOrEqualTo(MixPromptInput.stripeInset),
      );
      expect(stripe.width, greaterThan(surface.width / 2));
      // The draft's own room is untouched: nothing upright sits beside it.
      expect(field.left - surface.left, lessThanOrEqualTo(15));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a long draft grows to five lines with the keys at its foot', (
      tester,
    ) async {
      final controller = TextEditingController(
        text: 'one\ntwo\nthree\nfour\nfive\nsix',
      );
      addTearDown(controller.dispose);
      await pump(tester, controller);
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(
        find.byKey(const Key('prompt-field')),
      );
      expect(field.maxLines, 5);
      final surface = tester.getRect(find.byKey(MixPromptInput.surfaceKey));
      final send = tester.getRect(find.byKey(const Key('start-session')));
      final mic = tester.getRect(find.byKey(const Key('voice-input')));
      expect(surface.bottom - send.bottom, lessThanOrEqualTo(3));
      expect(surface.bottom - mic.bottom, lessThanOrEqualTo(3));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a busy composer is a plain field: no mic, no send, no spinner', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'something warm');
      addTearDown(controller.dispose);
      await pump(tester, controller, busy: true);
      await tester.pump();

      expect(find.byKey(const Key('prompt-field')), findsOneWidget);
      expect(find.byKey(const Key('voice-input')), findsNothing);
      expect(find.byKey(const Key('start-session')), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a tap outside the field puts the keyboard away', (
      tester,
    ) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      await pump(tester, controller, focusNode: focus);
      await tester.tap(find.byKey(const Key('prompt-field')));
      await tester.pump();
      expect(focus.hasFocus, isTrue);

      await tester.tapAt(tester.getCenter(find.byKey(const Key('outside'))));
      await tester.pump();
      expect(focus.hasFocus, isFalse);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the send key is part of the field, not a tap outside it', (
      tester,
    ) async {
      final controller = TextEditingController();
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      bool? focusedAtSend;
      await pump(
        tester,
        controller,
        focusNode: focus,
        onSubmit: () => focusedAtSend = focus.hasFocus,
      );
      await tester.tap(find.byKey(const Key('prompt-field')));
      await tester.enterText(find.byKey(const Key('prompt-field')), 'warm');
      await tester.pump();

      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pump();
      expect(focusedAtSend, isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets('a given placeholder replaces the rotating hints and stays put', (
    tester,
  ) async {
    final controller = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MixPromptInput(
            controller: controller,
            busy: false,
            placeholder: 'Something like Late nights, but…',
            onSubmit: () {},
          ),
        ),
      ),
    );

    expect(find.text('Something like Late nights, but…'), findsOneWidget);
    expect(find.text('A slow Sunday morning'), findsNothing);
    await tester.pump(const Duration(seconds: 9));
    expect(find.text('Something like Late nights, but…'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets('reduced motion freezes examples and blank input cannot submit', (
    tester,
  ) async {
    final controller = TextEditingController();
    var submits = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: MixPromptInput(
              controller: controller,
              busy: false,
              onSubmit: () => submits++,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 9));
    expect(find.text('A slow Sunday morning'), findsOneWidget);
    // Nothing to send: the key is not drawn at all.
    expect(find.byKey(const Key('start-session')), findsNothing);
    expect(submits, 0);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets('pauses while inactive and behind another route', (tester) async {
    final controller = TextEditingController();
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: MixPromptInput(
            controller: controller,
            busy: false,
            onSubmit: () {},
          ),
        ),
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(milliseconds: 4500));
    expect(find.text('A slow Sunday morning'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Other screen')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 4500));
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('A slow Sunday morning'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 4500));
    expect(find.text('High-energy songs for my workout'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets('keyboard send submits only nonblank nonbusy input', (
    tester,
  ) async {
    final controller = TextEditingController();
    var submits = 0;
    Future<void> render(bool busy) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MixPromptInput(
            controller: controller,
            busy: busy,
            onSubmit: () => submits++,
          ),
        ),
      ),
    );
    await render(false);
    final field = tester.widget<TextField>(
      find.byKey(const Key('prompt-field')),
    );
    expect(field.textInputAction, TextInputAction.send);
    field.onSubmitted!('');
    expect(submits, 0);
    controller.text = '   ';
    field.onSubmitted!('   ');
    expect(submits, 0);
    await tester.enterText(
      find.byKey(const Key('prompt-field')),
      'A road trip',
    );
    await tester.testTextInput.receiveAction(TextInputAction.send);
    expect(submits, 1);
    await render(true);
    tester
        .widget<TextField>(find.byKey(const Key('prompt-field')))
        .onSubmitted!('A road trip');
    expect(submits, 1);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets('narrow large text composer has no caption or overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController(
      text: 'A long prompt for a slow Sunday morning',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: MixPromptInput(
              controller: controller,
              busy: false,
              onSubmit: () {},
            ),
          ),
        ),
      ),
    );
    expect(find.text('Describe your new mix'), findsNothing);
    expect(tester.takeException(), isNull);
    final submit = tester.getRect(find.byKey(const Key('start-session')));
    expect(submit.right, lessThanOrEqualTo(320));
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  group('voice input', () {
    late StreamController<double> amplitude;
    late Completer<String> transcript;
    late List<String> calls;
    late VoiceInputException? startError;
    late bool settingsReachable;
    late int settingsOpened;

    setUp(() {
      calls = [];
      startError = null;
      settingsReachable = true;
      settingsOpened = 0;
    });

    /// Built inside the test body, never in `setUp`: a future completed in
    /// the enclosing zone never resumes inside a widget test's fake async.
    VoiceComposerController voice() {
      // Held locally: a controller outliving its test must not write into the
      // next one's log.
      final log = calls;
      final levels = StreamController<double>.broadcast();
      amplitude = levels;
      addTearDown(levels.close);
      transcript = Completer<String>();
      final ready = transcript;
      return VoiceComposerController(
        onStart: () async {
          log.add('start');
          if (startError != null) throw startError!;
        },
        onStop: () {
          log.add('stop');
          return ready.future;
        },
        onCancel: () async => log.add('cancel'),
        amplitude: levels.stream,
        probeSettings: () async => settingsReachable,
        onOpenSettings: () async => settingsOpened++,
      );
    }

    Future<void> render(
      WidgetTester tester, {
      required TextEditingController controller,
      required VoiceComposerController? voiceController,
      FocusNode? focusNode,
      bool busy = false,
      bool showVoiceInput = true,
      void Function()? onSubmit,
    }) => tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Scaffold(
          body: MixPromptInput(
            controller: controller,
            focusNode: focusNode,
            busy: busy,
            onSubmit: onSubmit ?? () {},
            showVoiceInput: showVoiceInput,
            voiceController: voiceController,
          ),
        ),
      ),
    );

    testWidgets('the mic listens, stops and lands the transcript', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final controller = TextEditingController();
      final focus = FocusNode();
      final v = voice();
      var submits = 0;
      await render(
        tester,
        controller: controller,
        voiceController: v,
        focusNode: focus,
        onSubmit: () => submits++,
      );

      await tester.tap(find.byKey(const Key('voice-input')));
      await tester.pumpAndSettle();
      expect(calls, ['start']);
      // The field stays, saying it is listening; the meter sits by the key.
      expect(find.byKey(const Key('prompt-field')), findsOneWidget);
      expect(find.text('Listening…'), findsOneWidget);
      expect(find.byType(VoiceLevelMeter), findsOneWidget);
      expect(find.bySemanticsLabel('Listening'), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(const Key('voice-input'))).label,
        'Stop listening',
      );
      expect(find.byIcon(Icons.pause), findsOneWidget);
      expect(find.byIcon(Icons.mic_none), findsNothing);
      expect(
        tester.widget<TextField>(find.byKey(const Key('prompt-field'))).readOnly,
        isTrue,
        reason: 'the words are the microphone\'s while it is open',
      );
      expect(focus.hasFocus, isFalse, reason: 'the keyboard goes while speaking');

      controller.text = 'typed while listening';
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('start-session')),
        findsNothing,
        reason: 'no send while the mic is open',
      );
      controller.text = '';

      amplitude.add(0.8);
      await tester.pumpAndSettle();
      expect(
        tester.widget<VoiceLevelMeter>(find.byType(VoiceLevelMeter)).level,
        0.8,
      );

      await tester.tap(find.byKey(const Key('voice-input')));
      await tester.pumpAndSettle();
      expect(calls, ['start', 'stop']);
      expect(find.text('Transcribing…'), findsOneWidget);
      expect(find.text('Listening…'), findsNothing);
      amplitude.add(0.1);
      await tester.pumpAndSettle();
      expect(
        tester.widget<VoiceLevelMeter>(find.byType(VoiceLevelMeter)).level,
        0.8,
        reason: 'the meter freezes while the transcript is on its way',
      );

      transcript.complete('a rainy commute');
      await tester.pumpAndSettle();
      expect(controller.text, 'a rainy commute');
      expect(controller.selection.baseOffset, 'a rainy commute'.length);
      expect(controller.selection.extentOffset, 'a rainy commute'.length);
      expect(focus.hasFocus, isTrue);
      expect(submits, 0, reason: 'a transcript never sends by itself');
      expect(find.byKey(const Key('prompt-field')), findsOneWidget);
      expect(find.byIcon(Icons.mic_none), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      v.dispose();
      focus.dispose();
      controller.dispose();
      semantics.dispose();
    });

    testWidgets('words stream into the field as they are heard', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'Something for');
      final focus = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focus.dispose);
      final words = StreamController<String>.broadcast();
      addTearDown(words.close);
      final ready = Completer<String>();
      final v = VoiceComposerController(
        onStart: () async {},
        onStop: () => ready.future,
        onCancel: () async {},
        partials: words.stream,
      );
      addTearDown(v.dispose);
      await render(
        tester,
        controller: controller,
        voiceController: v,
        focusNode: focus,
      );

      await tester.tap(find.byKey(const Key('voice-input')));
      await tester.pumpAndSettle();
      words.add('a rainy');
      await tester.pump();
      expect(controller.text, 'Something for a rainy');
      words.add('a rainy drive home');
      await tester.pump();
      expect(controller.text, 'Something for a rainy drive home');

      // Stopped: the words stay while the better pass is on its way, then
      // that pass replaces them.
      await tester.tap(find.byKey(const Key('voice-input')));
      await tester.pump();
      expect(controller.text, 'Something for a rainy drive home');
      ready.complete('a rainy drive home.');
      await tester.pumpAndSettle();
      expect(controller.text, 'Something for a rainy drive home.');
      expect(controller.selection.baseOffset, controller.text.length);
      expect(focus.hasFocus, isTrue);
    });

    testWidgets('a long dictation keeps its latest line in view', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final words = StreamController<String>.broadcast();
      addTearDown(words.close);
      final v = VoiceComposerController(
        onStart: () async {},
        onStop: () => Completer<String>().future,
        onCancel: () async {},
        partials: words.stream,
      );
      addTearDown(v.dispose);
      await render(tester, controller: controller, voiceController: v);

      await tester.tap(find.byKey(const Key('voice-input')));
      await tester.pumpAndSettle();
      final long = List.generate(
        40,
        (i) => 'word$i',
      ).join(' ');
      words.add(long);
      await tester.pump();
      await tester.pump();

      final scrollable = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const Key('prompt-field')),
          matching: find.byType(Scrollable),
        ),
      );
      final position = scrollable.position;
      expect(position.maxScrollExtent, greaterThan(0));
      expect(position.pixels, position.maxScrollExtent);
    });

    testWidgets('a dictation that fails puts the draft back as it was', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'Something for');
      addTearDown(controller.dispose);
      final words = StreamController<String>.broadcast();
      addTearDown(words.close);
      final ready = Completer<String>();
      final v = VoiceComposerController(
        onStart: () async {},
        onStop: () => ready.future,
        onCancel: () async {},
        partials: words.stream,
      );
      addTearDown(v.dispose);
      await render(tester, controller: controller, voiceController: v);

      await tester.tap(find.byKey(const Key('voice-input')));
      await tester.pumpAndSettle();
      words.add('mumble');
      await tester.pump();
      await tester.tap(find.byKey(const Key('voice-input')));
      await tester.pump();
      ready.completeError(
        const VoiceInputException(VoiceInputFailure.failed, 'nope'),
      );
      await tester.pumpAndSettle();
      expect(controller.text, 'Something for');
    });

    testWidgets('a transcript joins existing text with a space', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'something for');
      controller.selection = TextSelection.collapsed(
        offset: 'something for'.length,
      );
      final v = voice();
      await render(tester, controller: controller, voiceController: v);

      await tester.tap(find.byKey(const Key('voice-input')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-input')));
      await tester.pumpAndSettle();
      transcript.complete('a rainy commute');
      await tester.pumpAndSettle();

      expect(controller.text, 'something for a rainy commute');
      expect(
        controller.selection.baseOffset,
        'something for a rainy commute'.length,
      );

      await tester.pumpWidget(const SizedBox());
      v.dispose();
      controller.dispose();
    });

    testWidgets('every failure kind shows its own line under the field', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final controller = TextEditingController();
      for (final failure in {
        VoiceInputFailure.playbackActive:
            TranscribeRecording.playbackActiveCopy,
        VoiceInputFailure.noAudio: TranscribeRecording.noAudioCopy,
        VoiceInputFailure.failed: TranscribeRecording.failedCopy,
        VoiceInputFailure.unauthorized: TranscribeRecording.unauthorizedCopy,
      }.entries) {
        startError = VoiceInputException(failure.key, failure.value);
        final v = voice();
        await render(tester, controller: controller, voiceController: v);
        await tester.tap(find.byKey(const Key('voice-input')));
        await tester.pumpAndSettle();

        expect(find.text(failure.value), findsOneWidget);
        expect(
          tester.widget<Text>(find.text(failure.value)).style?.color,
          MixtapeTokens.light.errInk,
        );
        expect(
          tester
              .getSemantics(find.text(failure.value))
              .getSemanticsData()
              .flagsCollection
              .isLiveRegion,
          isTrue,
        );
        expect(find.text('Open Settings'), findsNothing);
        expect(find.byKey(const Key('prompt-field')), findsOneWidget);
        expect(find.text('Listening…'), findsNothing);

        await tester.pumpWidget(const SizedBox());
        v.dispose();
      }
      controller.dispose();
      semantics.dispose();
    });

    testWidgets('a denied microphone offers Settings when it can open them', (
      tester,
    ) async {
      final controller = TextEditingController();
      startError = const VoiceInputException(
        VoiceInputFailure.permissionDenied,
        TranscribeRecording.permissionDeniedCopy,
      );
      final v = voice();
      await render(tester, controller: controller, voiceController: v);
      await tester.tap(find.byKey(const Key('voice-input')));
      await tester.pumpAndSettle();

      expect(
        find.text(TranscribeRecording.permissionDeniedCopy),
        findsOneWidget,
      );
      await tester.tap(find.text('Open Settings'));
      await tester.pumpAndSettle();
      expect(settingsOpened, 1);
      await tester.pumpWidget(const SizedBox());
      v.dispose();

      settingsReachable = false;
      final offline = voice();
      await render(tester, controller: controller, voiceController: offline);
      await tester.tap(find.byKey(const Key('voice-input')));
      await tester.pumpAndSettle();
      expect(
        find.text(TranscribeRecording.permissionDeniedCopy),
        findsOneWidget,
      );
      expect(find.text('Open Settings'), findsNothing);

      await tester.pumpWidget(const SizedBox());
      offline.dispose();
      controller.dispose();
    });

    testWidgets('leaving the screen gives the microphone back', (tester) async {
      final controller = TextEditingController();
      final v = voice();
      await render(tester, controller: controller, voiceController: v);
      await tester.tap(find.byKey(const Key('voice-input')));
      await tester.pumpAndSettle();
      expect(v.state, VoiceComposerState.listening);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(calls, ['start', 'cancel']);
      expect(v.state, VoiceComposerState.idle);
      v.dispose();
      controller.dispose();
    });

    testWidgets('the rotating examples hold while the mic is open', (
      tester,
    ) async {
      final controller = TextEditingController();
      final v = voice();
      await render(tester, controller: controller, voiceController: v);
      expect(find.text('A slow Sunday morning'), findsOneWidget);

      await tester.tap(find.byKey(const Key('voice-input')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 4500));
      await tester.pump(const Duration(milliseconds: 4500));
      await tester.tap(find.byKey(const Key('voice-input')));
      await tester.pumpAndSettle();
      transcript.completeError(
        const VoiceInputException(
          VoiceInputFailure.noAudio,
          TranscribeRecording.noAudioCopy,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('A slow Sunday morning'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      v.dispose();
      controller.dispose();
    });

    testWidgets('without AI consent the mic asks first and opens on Agree', (
      tester,
    ) async {
      final controller = TextEditingController();
      final v = voice();
      final account = FakeConsentAccountApi();
      final container = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
          authProvider.overrideWith(_SessionAuth.new),
          accountApiProvider.overrideWithValue(account),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: MixtapeTheme.light(),
            home: Scaffold(
              body: MixPromptInput(
                controller: controller,
                busy: false,
                onSubmit: () {},
                showVoiceInput: true,
                voiceController: v,
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('voice-input')));
      await tester.pumpAndSettle();
      expect(find.byKey(AiConsentCopy.titleKey), findsOneWidget);
      expect(calls, isEmpty);

      await tester.tap(find.byKey(AiConsentCopy.notNowKey));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(v.state, VoiceComposerState.idle);

      await tester.tap(find.byKey(const Key('voice-input')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(AiConsentCopy.agreeKey));
      await tester.pumpAndSettle();
      expect(account.grants, 1);
      expect(calls, ['start']);

      await tester.pumpWidget(const SizedBox());
      v.dispose();
      controller.dispose();
    });

    testWidgets('a transcribe 403 ai_consent_required shows the sheet, not a '
        'failure line', (tester) async {
      final controller = TextEditingController(text: 'kept');
      final account = FakeConsentAccountApi(aiConsent: true);
      final v = VoiceComposerController(
        onStart: () async {},
        onStop: () async => throw const VoiceInputException(
          VoiceInputFailure.consentRequired,
          TranscribeRecording.consentRequiredCopy,
        ),
        onCancel: () async {},
        amplitude: const Stream<double>.empty(),
      );
      final container = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
          authProvider.overrideWith(_SessionAuth.new),
          accountApiProvider.overrideWithValue(account),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: MixtapeTheme.light(),
            home: Scaffold(
              body: MixPromptInput(
                controller: controller,
                busy: false,
                onSubmit: () {},
                showVoiceInput: true,
                voiceController: v,
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('voice-input')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-input')));
      await tester.pumpAndSettle();

      expect(find.byKey(AiConsentCopy.titleKey), findsOneWidget);
      expect(find.text(TranscribeRecording.consentRequiredCopy), findsNothing);
      expect(v.failure, isNull);
      expect(controller.text, 'kept');

      await tester.tap(find.byKey(AiConsentCopy.notNowKey));
      await tester.pumpAndSettle();
      // The next tap on the mic asks first now.
      await tester.tap(find.byKey(const Key('voice-input')));
      await tester.pumpAndSettle();
      expect(find.byKey(AiConsentCopy.titleKey), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      v.dispose();
      controller.dispose();
    });

    testWidgets('a second tap while transcribing is ignored', (tester) async {
      final controller = TextEditingController();
      final v = voice();
      await render(tester, controller: controller, voiceController: v);
      await tester.tap(find.byKey(const Key('voice-input')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-input')));
      await tester.pumpAndSettle();
      expect(v.state, VoiceComposerState.transcribing);

      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('voice-input')))
            .onPressed,
        isNull,
      );
      await tester.tap(
        find.byKey(const Key('voice-input')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(calls, ['start', 'stop']);

      transcript.complete('a rainy commute');
      await tester.pumpAndSettle();
      expect(controller.text, 'a rainy commute');

      await tester.pumpWidget(const SizedBox());
      v.dispose();
      controller.dispose();
    });

    testWidgets('a transcript dropped mid-text is spaced on both sides', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'something forlater');
      controller.selection = TextSelection.collapsed(
        offset: 'something for'.length,
      );
      final v = voice();
      await render(tester, controller: controller, voiceController: v);
      await tester.tap(find.byKey(const Key('voice-input')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-input')));
      await tester.pumpAndSettle();
      transcript.complete('a rainy commute');
      await tester.pumpAndSettle();

      expect(controller.text, 'something for a rainy commute later');
      expect(
        controller.selection.baseOffset,
        'something for a rainy commute'.length,
      );

      await tester.pumpWidget(const SizedBox());
      v.dispose();
      controller.dispose();
    });

    testWidgets('a composer that locks gives the microphone back', (
      tester,
    ) async {
      final controller = TextEditingController();
      final v = voice();
      await render(tester, controller: controller, voiceController: v);
      await tester.tap(find.byKey(const Key('voice-input')));
      await tester.pumpAndSettle();
      expect(v.state, VoiceComposerState.listening);

      await render(
        tester,
        controller: controller,
        voiceController: v,
        busy: true,
      );
      await tester.pumpAndSettle();
      expect(calls, ['start', 'cancel']);
      expect(v.state, VoiceComposerState.idle);
      expect(find.text('Listening…'), findsNothing);
      expect(find.byKey(const Key('prompt-field')), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      v.dispose();
      controller.dispose();
    });

    testWidgets('busy and a hidden mic both keep the microphone shut', (
      tester,
    ) async {
      final controller = TextEditingController();
      final v = voice();
      await render(
        tester,
        controller: controller,
        voiceController: v,
        showVoiceInput: false,
      );
      expect(find.byKey(const Key('voice-input')), findsNothing);

      await render(
        tester,
        controller: controller,
        voiceController: v,
        busy: true,
      );
      // Busy, the composer is a plain field: the mic is not drawn at all.
      expect(find.byKey(const Key('voice-input')), findsNothing);
      expect(calls, isEmpty);

      await tester.pumpWidget(const SizedBox());
      v.dispose();
      controller.dispose();
    });
  });
}
