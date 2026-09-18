// The use case the composer calls: server transcription first, Apple's
// on-device recogniser only where the server could not answer at all, one
// sentence of copy per failure, and never a clip left behind.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/voice/speech_channel.dart';
import 'package:mixtape/data/voice/transcription_api.dart';
import 'package:mixtape/data/voice/voice_capture_service.dart';
import 'package:mixtape/presentation/providers/voice_providers.dart';
import 'package:record/record.dart';

class _FakeRecorder implements VoiceRecorder {
  bool permitted = true;
  String? startedAt;
  int bytes = 4096;

  final _amplitudes = StreamController<Amplitude>.broadcast();

  @override
  Future<bool> hasPermission() async => permitted;

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    startedAt = path;
    File(path).writeAsBytesSync(List<int>.filled(bytes, 3));
  }

  @override
  Future<String?> stop() async => startedAt;

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) => _amplitudes.stream;

  @override
  Future<void> dispose() => _amplitudes.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const audioSession = MethodChannel(VoiceCaptureService.audioSessionChannel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory clips;
  late _FakeRecorder recorder;
  late VoiceCaptureService capture;
  late List<String> attempts;
  late int expiries;

  setUp(() async {
    clips = await Directory.systemTemp.createTemp('mixtape-voice-usecase');
    recorder = _FakeRecorder();
    attempts = [];
    expiries = 0;
    messenger.setMockMethodCallHandler(audioSession, (call) async => true);
    capture = VoiceCaptureService(
      recorderFactory: () => recorder,
      clipDirectory: clips,
      manageAudioSession: true,
    );
    addTearDown(capture.dispose);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(audioSession, null);
    if (clips.existsSync()) clips.deleteSync(recursive: true);
  });

  TranscribeRecording build({
    Future<String> Function(File clip)? server,
    Future<String> Function(String path)? onDevice,
  }) =>
      TranscribeRecording(
        capture: capture,
        server: (clip) {
          attempts.add('server');
          return server?.call(clip) ?? Future.value('from the server');
        },
        onDevice: (path) {
          attempts.add('on-device');
          return onDevice?.call(path) ?? Future.value('from the device');
        },
        onSessionExpired: () async => expiries++,
      );

  test('the server transcript wins and the clip is deleted', () async {
    final use = build();
    await use.begin();
    final path = recorder.startedAt!;

    expect(await use.finish(), 'from the server');

    expect(attempts, ['server']);
    expect(File(path).existsSync(), isFalse);
    expect(capture.state, VoiceCaptureState.idle);
  });

  test('a server that cannot answer falls back to the device', () async {
    for (final failure in const [
      TranscriptionFailure.notConfigured,
      TranscriptionFailure.upstream,
      TranscriptionFailure.timeout,
      TranscriptionFailure.network,
    ]) {
      attempts = [];
      final use = build(
        server: (_) => throw TranscriptionException(failure),
      );
      await use.begin();
      final path = recorder.startedAt!;

      expect(await use.finish(), 'from the device', reason: '$failure');
      expect(attempts, ['server', 'on-device'], reason: '$failure');
      expect(File(path).existsSync(), isFalse, reason: '$failure');
      expect(capture.state, VoiceCaptureState.idle);
    }
  });

  test('a clip the server refuses on its own terms is not retried on device', () async {
    for (final failure in const [
      TranscriptionFailure.tooShort,
      TranscriptionFailure.tooLarge,
      TranscriptionFailure.unauthorized,
    ]) {
      attempts = [];
      final use = build(server: (_) => throw TranscriptionException(failure));
      await use.begin();
      final path = recorder.startedAt!;

      await expectLater(
        use.finish(),
        throwsA(isA<VoiceInputException>()),
        reason: '$failure',
      );
      expect(attempts, ['server'], reason: '$failure');
      expect(File(path).existsSync(), isFalse, reason: '$failure');
      expect(capture.state, VoiceCaptureState.failed);
    }
  });

  test('both paths failing leaves one sentence and no clip', () async {
    final use = build(
      server: (_) => throw const TranscriptionException(TranscriptionFailure.upstream),
      onDevice: (_) => throw const SpeechException(SpeechFailure.failed),
    );
    await use.begin();
    final path = recorder.startedAt!;

    await expectLater(
      use.finish(),
      throwsA(
        isA<VoiceInputException>()
            .having((e) => e.failure, 'failure', VoiceInputFailure.failed)
            .having((e) => e.message, 'message', TranscribeRecording.failedCopy),
      ),
    );
    expect(File(path).existsSync(), isFalse);
    expect(capture.state, VoiceCaptureState.failed);
  });

  test('a refused microphone carries the Settings sentence', () async {
    recorder.permitted = false;
    final use = build();

    await expectLater(
      use.begin(),
      throwsA(
        isA<VoiceInputException>()
            .having((e) => e.failure, 'failure', VoiceInputFailure.permissionDenied)
            .having(
              (e) => e.message,
              'message',
              'Allow the microphone in Settings to speak your idea.',
            ),
      ),
    );
    expect(attempts, isEmpty);
  });

  test('music playing carries the pause sentence', () async {
    messenger.setMockMethodCallHandler(audioSession, (call) async {
      throw PlatformException(code: 'PLAYBACK_ACTIVE');
    });
    final use = build();

    await expectLater(
      use.begin(),
      throwsA(
        isA<VoiceInputException>()
            .having((e) => e.failure, 'failure', VoiceInputFailure.playbackActive)
            .having(
              (e) => e.message,
              'message',
              'Pause the music to speak your idea.',
            ),
      ),
    );
  });

  test('a clip under 1 KB never reaches either transcriber', () async {
    recorder.bytes = 512;
    final use = build();
    await use.begin();
    final path = recorder.startedAt!;

    await expectLater(
      use.finish(),
      throwsA(
        isA<VoiceInputException>()
            .having((e) => e.failure, 'failure', VoiceInputFailure.noAudio)
            .having(
              (e) => e.message,
              'message',
              'No audio captured. Hold the button a little longer.',
            ),
      ),
    );
    expect(attempts, isEmpty);
    expect(File(path).existsSync(), isFalse);
  });

  test('a clip the server calls too short reads as no audio too', () async {
    final use = build(
      server: (_) => throw const TranscriptionException(TranscriptionFailure.tooShort),
    );
    await use.begin();

    await expectLater(
      use.finish(),
      throwsA(
        isA<VoiceInputException>().having(
          (e) => e.message,
          'message',
          'No audio captured. Hold the button a little longer.',
        ),
      ),
    );
  });

  test('a 401 ends the session and says so, in its own words', () async {
    final use = build(
      server: (_) =>
          throw const TranscriptionException(TranscriptionFailure.unauthorized),
    );
    await use.begin();
    final path = recorder.startedAt!;

    await expectLater(
      use.finish(),
      throwsA(
        isA<VoiceInputException>()
            .having((e) => e.failure, 'failure', VoiceInputFailure.unauthorized)
            .having(
              (e) => e.message,
              'message',
              'Sign in again to speak your idea.',
            ),
      ),
    );
    // The session is over everywhere, not just in the composer.
    expect(expiries, 1);
    expect(attempts, ['server']);
    expect(File(path).existsSync(), isFalse);
  });

  test('only a 401 expires the session', () async {
    final use = build(
      server: (_) =>
          throw const TranscriptionException(TranscriptionFailure.tooLarge),
    );
    await use.begin();

    await expectLater(use.finish(), throwsA(isA<VoiceInputException>()));

    expect(expiries, 0);
  });

  test('abandon throws the clip away and says nothing', () async {
    final use = build();
    await use.begin();
    final path = recorder.startedAt!;

    await use.abandon();

    expect(attempts, isEmpty);
    expect(File(path).existsSync(), isFalse);
    expect(capture.state, VoiceCaptureState.idle);
  });
}
