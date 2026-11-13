// The use case the composer calls: server transcription first, Apple's
// on-device recogniser only where the server could not answer at all, one
// sentence of copy per failure, and never a clip left behind.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/voice/live_dictation.dart';
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

class _FakeLive implements LiveTranscriber {
  _FakeLive(this.clip);

  final File? clip;
  DictationException? startError;
  String heard = 'a rainy drive';
  final calls = <String>[];
  final discarded = <String?>[];

  @override
  Stream<String> get partials => const Stream.empty();

  @override
  Stream<double> get levels => const Stream.empty();

  @override
  Future<void> start({List<String> vocabulary = const []}) async {
    calls.add('start');
    if (startError != null) throw startError!;
  }

  @override
  Future<DictationResult> stop() async {
    calls.add('stop');
    return DictationResult(path: clip?.path, text: heard);
  }

  @override
  Future<void> cancel() async => calls.add('cancel');

  @override
  Future<void> discard(String? path) async {
    discarded.add(path);
    if (path != null && File(path).existsSync()) File(path).deleteSync();
  }
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

  test('a consent 403 is its own failure, not retried and not a sign-out', () async {
    final use = build(
      server: (_) => throw const TranscriptionException(
        TranscriptionFailure.consentRequired,
      ),
    );
    await use.begin();
    final path = recorder.startedAt!;

    await expectLater(
      use.finish(),
      throwsA(
        isA<VoiceInputException>().having(
          (e) => e.failure,
          'failure',
          VoiceInputFailure.consentRequired,
        ),
      ),
    );
    expect(expiries, 0);
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

  group('live words, then the server\'s pass (device smoke 2026-11-13)', () {
    late _FakeLive live;
    late File clip;

    setUp(() {
      clip = File('${clips.path}/live.m4a')
        ..writeAsBytesSync(List<int>.filled(4096, 1));
      live = _FakeLive(clip);
    });

    TranscribeRecording buildLive({
      Future<String> Function(File clip)? server,
    }) => TranscribeRecording(
      capture: capture,
      live: live,
      server: (clip) {
        attempts.add('server');
        return server?.call(clip) ?? Future.value('A rainy drive, home.');
      },
      onDevice: (path) {
        attempts.add('on-device');
        return Future.value('from the device');
      },
      onSessionExpired: () async => expiries++,
    );

    test('the server polishes what was heard and the clip goes', () async {
      final use = buildLive();
      await use.begin();
      expect(live.calls, ['start']);
      expect(recorder.startedAt, isNull, reason: 'the recorder stays shut');

      expect(await use.finish(), 'A rainy drive, home.');
      expect(attempts, ['server']);
      expect(live.discarded, [clip.path]);
      expect(clip.existsSync(), isFalse);
    });

    test('a server that cannot answer keeps the live words', () async {
      final use = buildLive(
        server: (_) =>
            throw const TranscriptionException(TranscriptionFailure.upstream),
      );
      await use.begin();
      expect(await use.finish(), 'a rainy drive');
      expect(attempts, ['server'], reason: 'no second on-device pass');
      expect(clip.existsSync(), isFalse);
    });

    test('a clip the server calls too short keeps the live words', () async {
      final use = buildLive(
        server: (_) =>
            throw const TranscriptionException(TranscriptionFailure.tooShort),
      );
      await use.begin();
      expect(await use.finish(), 'a rainy drive');
    });

    test('nothing heard and nothing from the server is no audio', () async {
      live.heard = '';
      final use = buildLive(
        server: (_) =>
            throw const TranscriptionException(TranscriptionFailure.tooShort),
      );
      await use.begin();
      await expectLater(
        use.finish(),
        throwsA(
          isA<VoiceInputException>().having(
            (e) => e.failure,
            'failure',
            VoiceInputFailure.noAudio,
          ),
        ),
      );
    });

    test('consent and an expired session still speak for themselves', () async {
      final consent = buildLive(
        server: (_) => throw const TranscriptionException(
          TranscriptionFailure.consentRequired,
        ),
      );
      await consent.begin();
      await expectLater(
        consent.finish(),
        throwsA(
          isA<VoiceInputException>().having(
            (e) => e.failure,
            'failure',
            VoiceInputFailure.consentRequired,
          ),
        ),
      );

      clip.writeAsBytesSync(List<int>.filled(4096, 1));
      final expired = buildLive(
        server: (_) => throw const TranscriptionException(
          TranscriptionFailure.unauthorized,
        ),
      );
      await expired.begin();
      await expectLater(expired.finish(), throwsA(isA<VoiceInputException>()));
      expect(expiries, 1);
    });

    test('speech recognition refused falls back to the recorder', () async {
      live.startError = const DictationException(DictationFailure.speechDenied);
      final use = buildLive();
      await use.begin();
      expect(recorder.startedAt, isNotNull);
      expect(await use.finish(), 'A rainy drive, home.');
      expect(live.calls, ['start'], reason: 'never stopped: it never ran');
    });

    test('a refused microphone and playing music fail as they always did', () async {
      live.startError = const DictationException(DictationFailure.micDenied);
      await expectLater(
        buildLive().begin(),
        throwsA(
          isA<VoiceInputException>().having(
            (e) => e.failure,
            'failure',
            VoiceInputFailure.permissionDenied,
          ),
        ),
      );
      live.startError = const DictationException(
        DictationFailure.playbackActive,
      );
      await expectLater(
        buildLive().begin(),
        throwsA(
          isA<VoiceInputException>().having(
            (e) => e.failure,
            'failure',
            VoiceInputFailure.playbackActive,
          ),
        ),
      );
      expect(recorder.startedAt, isNull);
    });

    test('abandon stops the live recogniser, not the recorder', () async {
      final use = buildLive();
      await use.begin();
      await use.abandon();
      expect(live.calls, ['start', 'cancel']);
      expect(attempts, isEmpty);
    });
  });
}
