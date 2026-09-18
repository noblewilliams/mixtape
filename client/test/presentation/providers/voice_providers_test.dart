// The composer's voice state machine: what the mic, the meter and the
// failure line under the field read from.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/providers/voice_providers.dart';

void main() {
  late StreamController<double> amplitude;
  late Completer<String> transcript;
  late List<String> calls;
  late VoiceInputException? startError;
  late bool settingsReachable;
  late int settingsOpened;

  VoiceComposerController build() => VoiceComposerController(
    onStart: () async {
      calls.add('start');
      if (startError != null) throw startError!;
    },
    onStop: () {
      calls.add('stop');
      return transcript.future;
    },
    onCancel: () async => calls.add('cancel'),
    amplitude: amplitude.stream,
    probeSettings: () async => settingsReachable,
    onOpenSettings: () async => settingsOpened++,
  );

  setUp(() {
    amplitude = StreamController<double>.broadcast();
    transcript = Completer<String>();
    calls = [];
    startError = null;
    settingsReachable = true;
    settingsOpened = 0;
  });

  tearDown(() => amplitude.close());

  test('listening follows the amplitude and stops with a transcript', () async {
    final voice = build();
    addTearDown(voice.dispose);
    var notifications = 0;
    voice.addListener(() => notifications++);

    await voice.start();
    expect(voice.state, VoiceComposerState.listening);
    expect(voice.busy, isTrue);
    amplitude.add(0.7);
    await Future<void>.delayed(Duration.zero);
    expect(voice.level, 0.7);

    final stopping = voice.stop();
    expect(voice.state, VoiceComposerState.transcribing);
    amplitude.add(0.1);
    await Future<void>.delayed(Duration.zero);
    expect(voice.level, 0.7, reason: 'the meter freezes while transcribing');

    transcript.complete('  a rainy commute  ');
    expect(await stopping, 'a rainy commute');
    expect(voice.state, VoiceComposerState.idle);
    expect(voice.failure, isNull);
    expect(calls, ['start', 'stop']);
    expect(notifications, greaterThan(0));
  });

  test('a refused microphone keeps its copy and offers Settings', () async {
    startError = const VoiceInputException(
      VoiceInputFailure.permissionDenied,
      TranscribeRecording.permissionDeniedCopy,
    );
    final voice = build();
    addTearDown(voice.dispose);

    await voice.start();
    expect(voice.state, VoiceComposerState.failed);
    expect(voice.failure?.failure, VoiceInputFailure.permissionDenied);
    expect(voice.failure?.message, TranscribeRecording.permissionDeniedCopy);
    await Future<void>.delayed(Duration.zero);
    expect(voice.settingsAvailable, isTrue);
    await voice.openSettings();
    expect(settingsOpened, 1);

    voice.clearFailure();
    expect(voice.state, VoiceComposerState.idle);
    expect(voice.failure, isNull);
  });

  test('a device that cannot open Settings hides the action', () async {
    settingsReachable = false;
    startError = const VoiceInputException(
      VoiceInputFailure.permissionDenied,
      TranscribeRecording.permissionDeniedCopy,
    );
    final voice = build();
    addTearDown(voice.dispose);

    await voice.start();
    await Future<void>.delayed(Duration.zero);
    expect(voice.settingsAvailable, isFalse);
  });

  test('a failed transcription lands in the failure line', () async {
    final voice = build();
    addTearDown(voice.dispose);
    await voice.start();
    final stopping = voice.stop();
    transcript.completeError(
      const VoiceInputException(
        VoiceInputFailure.failed,
        TranscribeRecording.failedCopy,
      ),
    );
    expect(await stopping, isNull);
    expect(voice.state, VoiceComposerState.failed);
    expect(voice.failure?.message, TranscribeRecording.failedCopy);
    expect(voice.settingsAvailable, isFalse);
  });

  test('an empty transcript is nothing heard', () async {
    final voice = build();
    addTearDown(voice.dispose);
    await voice.start();
    final stopping = voice.stop();
    transcript.complete('   ');
    expect(await stopping, isNull);
    expect(voice.failure?.failure, VoiceInputFailure.noAudio);
  });

  test('cancel and dispose both give the microphone back', () async {
    final voice = build();
    await voice.start();
    await voice.cancel();
    expect(voice.state, VoiceComposerState.idle);
    expect(calls, ['start', 'cancel']);
    expect(voice.level, 0);

    final second = build();
    await second.start();
    second.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(calls.where((call) => call == 'cancel'), hasLength(2));

    voice.dispose();
  });
}
