// The recording half of voice input: permission, the iOS audio session, one
// AAC clip in the temp directory, a 0–1 level for the composer's meter, and a
// clip that is deleted on every path out.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/voice/voice_capture_service.dart';
import 'package:record/record.dart';

class _FakeRecorder implements VoiceRecorder {
  _FakeRecorder({this.startError});

  bool permitted = true;
  final Object? startError;
  Object? stopError;
  bool permissionRequested = false;
  bool disposed = false;
  int stops = 0;
  String? startedAt;
  RecordConfig? config;
  int bytes = 4096;

  final amplitudes = StreamController<Amplitude>.broadcast();

  @override
  Future<bool> hasPermission() async {
    permissionRequested = true;
    return permitted;
  }

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    if (startError != null) throw startError!;
    this.config = config;
    startedAt = path;
    File(path).writeAsBytesSync(List<int>.filled(bytes, 3));
  }

  @override
  Future<String?> stop() async {
    stops++;
    if (stopError != null) throw stopError!;
    return startedAt;
  }

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) => amplitudes.stream;

  @override
  Future<void> dispose() async {
    disposed = true;
    await amplitudes.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const audioSession = MethodChannel(VoiceCaptureService.audioSessionChannel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory clips;
  late _FakeRecorder recorder;
  late List<MethodCall> sessionCalls;

  setUp(() async {
    clips = await Directory.systemTemp.createTemp('mixtape-voice-test');
    recorder = _FakeRecorder();
    sessionCalls = [];
    messenger.setMockMethodCallHandler(audioSession, (call) async {
      sessionCalls.add(call);
      return true;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(audioSession, null);
    if (clips.existsSync()) clips.deleteSync(recursive: true);
  });

  VoiceCaptureService build({bool manageAudioSession = true}) =>
      VoiceCaptureService(
        recorderFactory: () => recorder,
        clipDirectory: clips,
        manageAudioSession: manageAudioSession,
      );

  test('start asks for the mic, activates the session, records AAC mono 44.1k', () async {
    final service = build();
    addTearDown(service.dispose);
    expect(service.state, VoiceCaptureState.idle);

    await service.start();

    expect(recorder.permissionRequested, isTrue);
    expect(sessionCalls.single.method, 'activate');
    expect(recorder.config!.encoder, AudioEncoder.aacLc);
    expect(recorder.config!.numChannels, 1);
    expect(recorder.config!.sampleRate, 44100);
    expect(recorder.startedAt, startsWith(clips.path));
    expect(recorder.startedAt, endsWith('.m4a'));
    expect(service.state, VoiceCaptureState.listening);
  });

  test('off iOS there is no audio session to activate', () async {
    final service = build(manageAudioSession: false);
    addTearDown(service.dispose);

    await service.start();

    expect(sessionCalls, isEmpty);
    expect(service.state, VoiceCaptureState.listening);
  });

  test('a refused mic fails without recording', () async {
    recorder.permitted = false;
    final service = build();
    addTearDown(service.dispose);

    await expectLater(
      service.start(),
      throwsA(
        isA<VoiceCaptureException>().having(
          (e) => e.failure,
          'failure',
          VoiceCaptureFailure.permissionDenied,
        ),
      ),
    );
    expect(recorder.startedAt, isNull);
    expect(service.state, VoiceCaptureState.failed);
  });

  test('music already playing refuses the recording', () async {
    messenger.setMockMethodCallHandler(audioSession, (call) async {
      throw PlatformException(code: 'PLAYBACK_ACTIVE');
    });
    final service = build();
    addTearDown(service.dispose);

    await expectLater(
      service.start(),
      throwsA(
        isA<VoiceCaptureException>().having(
          (e) => e.failure,
          'failure',
          VoiceCaptureFailure.playbackActive,
        ),
      ),
    );
    expect(recorder.startedAt, isNull);
    expect(service.state, VoiceCaptureState.failed);
  });

  test('any other audio session or recorder error is unavailable', () async {
    messenger.setMockMethodCallHandler(audioSession, (call) async {
      throw PlatformException(code: 'AUDIO_SESSION');
    });
    final first = build();
    addTearDown(first.dispose);
    await expectLater(
      first.start(),
      throwsA(
        isA<VoiceCaptureException>().having(
          (e) => e.failure,
          'failure',
          VoiceCaptureFailure.unavailable,
        ),
      ),
    );

    messenger.setMockMethodCallHandler(audioSession, (call) async {
      sessionCalls.add(call);
      return true;
    });
    recorder = _FakeRecorder(startError: StateError('no input device'));
    final second = build();
    addTearDown(second.dispose);
    await expectLater(
      second.start(),
      throwsA(
        isA<VoiceCaptureException>().having(
          (e) => e.failure,
          'failure',
          VoiceCaptureFailure.unavailable,
        ),
      ),
    );
    // A recorder that failed to start is thrown away, not reused, and the
    // session it took is handed straight back.
    expect(recorder.disposed, isTrue);
    expect(sessionCalls.map((call) => call.method), ['activate', 'deactivate']);
  });

  test('a second start while listening changes nothing', () async {
    final service = build();
    addTearDown(service.dispose);

    await service.start();
    final path = recorder.startedAt;
    await service.start();

    expect(recorder.startedAt, path);
    expect(sessionCalls, hasLength(1));
  });

  test('stop hands over the clip and moves to transcribing', () async {
    final service = build();
    addTearDown(service.dispose);
    await service.start();

    final clip = await service.stop();

    expect(clip.existsSync(), isTrue);
    expect(clip.path, recorder.startedAt);
    expect(recorder.stops, 1);
    expect(service.state, VoiceCaptureState.transcribing);
    // `.playAndRecord` goes back as soon as nothing is recording under it.
    expect(
      sessionCalls.map((call) => call.method),
      ['activate', 'deactivate'],
    );
  });

  test('a recorder that will not stop is no audio, and the clip goes', () async {
    final service = build();
    addTearDown(service.dispose);
    await service.start();
    final path = recorder.startedAt!;
    recorder.stopError = StateError('recorder is gone');

    await expectLater(
      service.stop(),
      throwsA(
        isA<VoiceCaptureException>()
            .having((e) => e.failure, 'failure', VoiceCaptureFailure.noAudio),
      ),
    );
    expect(File(path).existsSync(), isFalse);
    expect(service.state, VoiceCaptureState.failed);
    expect(sessionCalls.last.method, 'deactivate');
  });

  test('a clip under 1 KB is no audio, and the clip is deleted', () async {
    recorder.bytes = 900;
    final service = build();
    addTearDown(service.dispose);
    await service.start();

    await expectLater(
      service.stop(),
      throwsA(
        isA<VoiceCaptureException>()
            .having((e) => e.failure, 'failure', VoiceCaptureFailure.noAudio),
      ),
    );
    expect(File(recorder.startedAt!).existsSync(), isFalse);
    expect(service.state, VoiceCaptureState.failed);
    expect(clips.listSync(), isEmpty);
  });

  test('stop with nothing recorded is no audio, not an exception from nowhere', () async {
    final service = build();
    addTearDown(service.dispose);

    await expectLater(
      service.stop(),
      throwsA(
        isA<VoiceCaptureException>()
            .having((e) => e.failure, 'failure', VoiceCaptureFailure.noAudio),
      ),
    );
  });

  test('cancel stops the recorder, deletes the clip and returns to idle', () async {
    final service = build();
    addTearDown(service.dispose);
    await service.start();
    final path = recorder.startedAt!;

    await service.cancel();

    expect(recorder.stops, 1);
    expect(File(path).existsSync(), isFalse);
    expect(clips.listSync(), isEmpty);
    expect(service.state, VoiceCaptureState.idle);
    expect(
      sessionCalls.map((call) => call.method),
      ['activate', 'deactivate'],
    );

    // Idempotent: cancelling twice is not an error and stops nothing again.
    await service.cancel();
    expect(recorder.stops, 1);
  });

  test('discard deletes a handed-over clip, and tolerates one already gone', () async {
    final service = build();
    addTearDown(service.dispose);
    await service.start();
    final clip = await service.stop();

    await service.discard(clip);
    expect(clip.existsSync(), isFalse);
    expect(clips.listSync(), isEmpty);

    await service.discard(clip);
  });

  test('the amplitude stream is normalised to 0 – 1 against a -50 dB floor', () async {
    final service = build();
    addTearDown(service.dispose);
    final levels = <double>[];
    service.amplitude.listen(levels.add);

    await service.start();
    for (final db in const [0.0, -25.0, -50.0, -160.0, 6.0]) {
      recorder.amplitudes.add(Amplitude(current: db, max: 0));
    }
    await Future<void>.delayed(Duration.zero);

    expect(levels, [1.0, 0.5, 0.0, 0.0, 1.0]);
  });

  test('state transitions are published for the composer', () async {
    final service = build();
    addTearDown(service.dispose);
    final states = <VoiceCaptureState>[];
    service.states.listen(states.add);

    await service.start();
    final clip = await service.stop();
    service.settle();
    await service.discard(clip);
    await Future<void>.delayed(Duration.zero);

    expect(states, [
      VoiceCaptureState.listening,
      VoiceCaptureState.transcribing,
      VoiceCaptureState.idle,
    ]);
  });

  test('a failure marked by the caller is published, and reset clears it', () async {
    final service = build();
    addTearDown(service.dispose);
    await service.start();
    await service.stop();

    service.markFailed();
    expect(service.state, VoiceCaptureState.failed);

    service.settle();
    expect(service.state, VoiceCaptureState.idle);
  });

  test('dispose stops a live recording, deletes the clip and closes the streams', () async {
    final service = build();
    await service.start();
    final path = recorder.startedAt!;

    await service.dispose();

    expect(recorder.disposed, isTrue);
    expect(File(path).existsSync(), isFalse);
    expect(service.state, VoiceCaptureState.idle);
    expect(sessionCalls.last.method, 'deactivate');
  });
}
