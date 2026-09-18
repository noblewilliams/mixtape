// The native half of voice input, checked from Dart: the channel names and
// method names Dart calls, the error codes it maps, the two usage
// descriptions iOS demands before a mic or the recogniser opens, and the
// Runner target membership a new Swift file needs to be compiled at all.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/voice/speech_channel.dart';
import 'package:mixtape/data/voice/voice_capture_service.dart';

void main() {
  final transcriber = File('ios/Runner/SpeechTranscriber.swift').readAsStringSync();
  final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
  final plist = File('ios/Runner/Info.plist').readAsStringSync();
  final project = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();

  test('the transcriber speaks the mixtape/speech contract Dart calls', () {
    expect(SpeechChannel.channelName, 'mixtape/speech');
    expect(transcriber, contains('"${SpeechChannel.channelName}"'));
    expect(transcriber, contains('case "transcribeFile"'));
  });

  test('the transcriber uses SFSpeechRecognizer on the file, en-US then device', () {
    expect(transcriber, contains('SFSpeechRecognizer'));
    expect(transcriber, contains('SFSpeechURLRecognitionRequest'));
    expect(transcriber, contains('requestAuthorization'));
    expect(transcriber, contains('Locale(identifier: "en-US")'));
    expect(transcriber, contains('Locale.current'));
    // One result only: a recognition task reports partials and can report an
    // error after a final result, and a FlutterResult may be called once.
    expect(transcriber, contains('hasResolved'));
    expect(transcriber, contains('isFinal'));
  });

  test('the transcriber answers with the codes Dart maps', () {
    for (final code in const [
      'PERMISSION_DENIED',
      'RECOGNIZER_UNAVAILABLE',
      'RECOGNITION_FAILED',
      'FILE_NOT_FOUND',
    ]) {
      expect(transcriber, contains('code: "$code"'), reason: code);
    }
  });

  test('the audio session channel activates for recording, and refuses over playback', () {
    expect(VoiceCaptureService.audioSessionChannel, 'mixtape/audio_session');
    expect(appDelegate, contains('"${VoiceCaptureService.audioSessionChannel}"'));
    expect(transcriber, contains('case "activate"'));
    expect(transcriber, contains('.playAndRecord'));
    expect(transcriber, contains('.defaultToSpeaker'));
    expect(transcriber, contains('.allowBluetooth'));
    expect(transcriber, contains('setActive(true'));
    // Recording over a live MusicKit queue would tear the app's own playback
    // session down; Dart asks the listener to pause instead.
    expect(transcriber, contains('PLAYBACK_ACTIVE'));
    expect(transcriber, contains('ApplicationMusicPlayer.shared'));
    expect(transcriber, contains('playbackStatus'));
  });

  test('the AppDelegate retains both bridges so their channels stay alive', () {
    expect(appDelegate, contains('SpeechTranscriber('));
    expect(appDelegate, contains('speechTranscriber'));
    expect(appDelegate, contains('AudioSessionBridge'));
  });

  test('nothing native logs a transcript, a clip path or anything else', () {
    for (final source in [transcriber, appDelegate]) {
      expect(source, isNot(contains('NSLog')));
      expect(source, isNot(contains('print(')));
      expect(source, isNot(contains('debugPrint')));
    }
  });

  test('Info.plist explains the microphone and the recogniser', () {
    expect(plist, contains('<key>NSMicrophoneUsageDescription</key>'));
    expect(
      plist,
      contains('<string>Mixtape listens while you describe the mix you want.</string>'),
    );
    expect(plist, contains('<key>NSSpeechRecognitionUsageDescription</key>'));
    expect(
      plist,
      contains('<string>Used only if the server transcription is unavailable.</string>'),
    );
  });

  test('SpeechTranscriber.swift is in the Runner target, like the dock', () {
    // A Swift file outside Sources compiles nowhere and the channel is simply
    // never registered — the failure the pbxproj lesson exists to prevent.
    expect(project, contains('SpeechTranscriber.swift'));
    final fileRefs =
        RegExp(r'([0-9A-F]{24}) /\* SpeechTranscriber\.swift \*/ = \{isa = PBXFileReference')
            .allMatches(project);
    expect(fileRefs, hasLength(1), reason: 'exactly one file reference');

    final buildFile = RegExp(
      r'([0-9A-F]{24}) /\* SpeechTranscriber\.swift in Sources \*/ = \{isa = PBXBuildFile',
    ).firstMatch(project);
    expect(buildFile, isNotNull, reason: 'a build file entry exists');

    final sources = RegExp(
      r'/\* Sources \*/ = \{[\s\S]*?buildActionMask[\s\S]*?files = \([\s\S]*?\);',
    ).allMatches(project).map((m) => m.group(0)!).toList();
    expect(
      sources.any((phase) => phase.contains(buildFile!.group(1)!)),
      isTrue,
      reason: 'the build file is in a Sources phase',
    );
    expect(
      sources.any((phase) => phase.contains('ShellDock.swift in Sources')),
      isTrue,
      reason: 'the same phase the dock is compiled in',
    );
  });
}
