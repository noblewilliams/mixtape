import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/providers/voice_providers.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/mix_prompt_input.dart';
import 'package:mixtape/presentation/widgets/voice_level_meter.dart';

void main() {
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
    await tester.tap(find.byKey(const Key('start-session')));
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
      expect(find.text('Listening…'), findsOneWidget);
      expect(find.byType(VoiceLevelMeter), findsOneWidget);
      expect(
        find.byKey(const Key('prompt-field')),
        findsNothing,
        reason: 'the meter replaces the field while listening',
      );
      expect(find.bySemanticsLabel('Listening'), findsOneWidget);
      expect(
        tester.getSemantics(find.byKey(const Key('voice-input'))).label,
        'Stop listening',
      );
      expect(find.byIcon(Icons.pause), findsOneWidget);
      expect(find.byIcon(Icons.mic_none), findsNothing);

      controller.text = 'typed while listening';
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('start-session')));
      expect(submits, 0, reason: 'send is off while the mic is open');
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
      // Not `pumpAndSettle`: a locked composer spins its progress key.
      await tester.pump();
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
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('voice-input')))
            .onPressed,
        isNull,
      );
      expect(calls, isEmpty);

      await tester.pumpWidget(const SizedBox());
      v.dispose();
      controller.dispose();
    });
  });
}
