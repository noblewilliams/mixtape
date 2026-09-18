// The on-device fallback's side of the wire: `mixtape/speech` answers with a
// transcript or one of four codes, and this maps those to the failures the
// composer can act on. No transcript is ever logged here or in the native side.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/voice/speech_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(SpeechChannel.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  void answer(Future<Object?> Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, handler);
  }

  test('a transcript comes back trimmed, with the path as the argument', () async {
    final calls = <MethodCall>[];
    answer((call) async {
      calls.add(call);
      return '  a slow start then a lift  ';
    });

    final text = await SpeechChannel().transcribeFile('/tmp/clip.m4a');

    expect(text, 'a slow start then a lift');
    expect(calls.single.method, 'transcribeFile');
    expect(calls.single.arguments, '/tmp/clip.m4a');
  });

  test('every speech permission code is one permissionDenied', () async {
    for (final code in const [
      'PERMISSION_DENIED',
      'PERMISSION_RESTRICTED',
      'PERMISSION_NOT_DETERMINED',
    ]) {
      answer((call) async => throw PlatformException(code: code));
      await expectLater(
        SpeechChannel().transcribeFile('/tmp/clip.m4a'),
        throwsA(
          isA<SpeechException>().having(
            (e) => e.failure,
            'failure',
            SpeechFailure.permissionDenied,
          ),
        ),
        reason: code,
      );
    }
  });

  test('an unavailable recogniser is unavailable, and so is a missing host', () async {
    answer((call) async => throw PlatformException(code: 'RECOGNIZER_UNAVAILABLE'));
    await expectLater(
      SpeechChannel().transcribeFile('/tmp/clip.m4a'),
      throwsA(
        isA<SpeechException>()
            .having((e) => e.failure, 'failure', SpeechFailure.unavailable),
      ),
    );

    // No handler at all: Android, or an iOS build without the transcriber.
    messenger.setMockMethodCallHandler(channel, null);
    await expectLater(
      SpeechChannel().transcribeFile('/tmp/clip.m4a'),
      throwsA(
        isA<SpeechException>()
            .having((e) => e.failure, 'failure', SpeechFailure.unavailable),
      ),
    );
  });

  test('recognition errors, an empty transcript and a timeout all fail', () async {
    for (final code in const ['RECOGNITION_FAILED', 'FILE_NOT_FOUND', 'WHATEVER']) {
      answer((call) async => throw PlatformException(code: code));
      await expectLater(
        SpeechChannel().transcribeFile('/tmp/clip.m4a'),
        throwsA(
          isA<SpeechException>()
              .having((e) => e.failure, 'failure', SpeechFailure.failed),
        ),
        reason: code,
      );
    }

    answer((call) async => '   ');
    await expectLater(
      SpeechChannel().transcribeFile('/tmp/clip.m4a'),
      throwsA(
        isA<SpeechException>()
            .having((e) => e.failure, 'failure', SpeechFailure.failed),
      ),
    );

    answer((call) => Future.delayed(const Duration(seconds: 2), () => 'late'));
    await expectLater(
      SpeechChannel(timeout: const Duration(milliseconds: 20))
          .transcribeFile('/tmp/clip.m4a'),
      throwsA(
        isA<SpeechException>()
            .having((e) => e.failure, 'failure', SpeechFailure.failed),
      ),
    );
  });

  test('the channel waits 30 s by default', () {
    expect(SpeechChannel().timeout, const Duration(seconds: 30));
  });
}
