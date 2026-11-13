// Live dictation's Dart half (device smoke 2026-11-13): the audio session
// first, then the recogniser over `mixtape/dictation`, words and levels back
// over `mixtape/dictation/events`, and one failure per native code.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/voice/live_dictation.dart';
import 'package:mixtape/data/voice/voice_capture_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methods = MethodChannel(LiveDictation.channelName);
  const events = EventChannel(LiveDictation.eventsName);
  const session = MethodChannel(VoiceCaptureService.audioSessionChannel);

  late Directory clips;
  late List<String> calls;
  late Object? sessionAnswer;
  late Object? startAnswer;
  late Map<String, Object?>? stopAnswer;
  late Map<Object?, Object?>? startArguments;
  MockStreamHandlerEventSink? sink;

  setUp(() async {
    clips = await Directory.systemTemp.createTemp('mixtape-dictation');
    calls = [];
    sessionAnswer = true;
    startAnswer = null;
    stopAnswer = {'path': '${clips.path}/clip.m4a', 'text': 'a rainy drive'};
    startArguments = null;
    sink = null;
    messenger.setMockMethodCallHandler(session, (call) async {
      calls.add('session.${call.method}');
      final answer = sessionAnswer;
      if (call.method == 'activate' && answer is PlatformException) {
        throw answer;
      }
      return true;
    });
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call.method);
      if (call.method == 'start') {
        startArguments = call.arguments as Map<Object?, Object?>;
        final answer = startAnswer;
        if (answer is PlatformException) throw answer;
      }
      if (call.method == 'stop') return stopAnswer;
      return null;
    });
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (arguments, events) => sink = events,
        onCancel: (arguments) => sink = null,
      ),
    );
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(session, null);
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(events, null);
    if (clips.existsSync()) clips.deleteSync(recursive: true);
  });

  LiveDictation build({bool available = true}) =>
      LiveDictation(clipDirectory: clips, available: available);

  test('the session opens first, then the recogniser, on a fresh clip', () async {
    final dictation = build();
    addTearDown(dictation.dispose);
    await dictation.start(vocabulary: const ['Asake', 'Tems']);
    expect(calls, ['session.activate', 'start']);
    final path = startArguments!['path']! as String;
    expect(path, startsWith(clips.path));
    expect(path, endsWith('.m4a'));
    expect(startArguments!['contextualStrings'], ['Asake', 'Tems']);
  });

  test('words and levels arrive as they are heard', () async {
    final dictation = build();
    addTearDown(dictation.dispose);
    final words = <String>[];
    final levels = <double>[];
    dictation.partials.listen(words.add);
    dictation.levels.listen(levels.add);
    await dictation.start();
    sink!.success({'type': 'partial', 'text': 'a rainy'});
    sink!.success({'type': 'level', 'value': 0.4});
    sink!.success({'type': 'partial', 'text': 'a rainy drive home'});
    await Future<void>.delayed(Duration.zero);
    expect(words, ['a rainy', 'a rainy drive home']);
    expect(levels, [0.4]);
  });

  test('stop hands back the clip and the words, and the session goes', () async {
    final dictation = build();
    addTearDown(dictation.dispose);
    await dictation.start();
    final result = await dictation.stop();
    expect(result.text, 'a rainy drive');
    expect(result.path, '${clips.path}/clip.m4a');
    expect(calls, ['session.activate', 'start', 'stop', 'session.deactivate']);
  });

  test('music playing refuses before the recogniser is asked', () async {
    sessionAnswer = PlatformException(code: 'PLAYBACK_ACTIVE');
    final dictation = build();
    addTearDown(dictation.dispose);
    await expectLater(
      dictation.start(),
      throwsA(
        isA<DictationException>().having(
          (e) => e.failure,
          'failure',
          DictationFailure.playbackActive,
        ),
      ),
    );
    expect(calls, ['session.activate']);
  });

  for (final (code, failure) in const [
    ('SPEECH_DENIED', DictationFailure.speechDenied),
    ('MIC_DENIED', DictationFailure.micDenied),
    ('UNAVAILABLE', DictationFailure.unavailable),
    ('SOMETHING_ELSE', DictationFailure.failed),
  ]) {
    test('$code is ${failure.name}, and the session is handed back', () async {
      startAnswer = PlatformException(code: code);
      final dictation = build();
      addTearDown(dictation.dispose);
      await expectLater(
        dictation.start(),
        throwsA(
          isA<DictationException>().having((e) => e.failure, 'failure', failure),
        ),
      );
      expect(calls.last, 'session.deactivate');
    });
  }

  test('off iOS there is nothing to ask', () async {
    final dictation = build(available: false);
    addTearDown(dictation.dispose);
    await expectLater(
      dictation.start(),
      throwsA(
        isA<DictationException>().having(
          (e) => e.failure,
          'failure',
          DictationFailure.unavailable,
        ),
      ),
    );
    expect(calls, isEmpty);
  });

  test('cancel stops the recogniser and hands the session back', () async {
    final dictation = build();
    addTearDown(dictation.dispose);
    await dictation.start();
    await dictation.cancel();
    expect(calls, ['session.activate', 'start', 'cancel', 'session.deactivate']);
  });

  test('discard deletes the clip it was handed', () async {
    final dictation = build();
    addTearDown(dictation.dispose);
    final clip = File('${clips.path}/clip.m4a')..writeAsBytesSync([1, 2, 3]);
    await dictation.discard(clip.path);
    expect(clip.existsSync(), isFalse);
    await dictation.discard(null);
  });
}
