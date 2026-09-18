import 'dart:async';

import 'package:flutter/services.dart';

/// Why Apple's on-device recogniser could not transcribe a clip.
enum SpeechFailure {
  /// Speech recognition is denied, restricted or unasked-for on this device.
  permissionDenied,

  /// No recogniser (no host handler at all, or none for any locale we tried).
  unavailable,

  /// The recogniser ran and produced nothing usable.
  failed,
}

class SpeechException implements Exception {
  const SpeechException(this.failure);

  final SpeechFailure failure;

  @override
  String toString() => 'SpeechException(${failure.name})';
}

/// The fallback transcriber: `SFSpeechRecognizer` reading a recorded clip off
/// disk, over the `mixtape/speech` channel.
///
/// The transcript is a listener's own words, so it is returned and never
/// logged — here or on the native side.
class SpeechChannel {
  SpeechChannel({
    MethodChannel channel = const MethodChannel(channelName),
    this.timeout = const Duration(seconds: 30),
  }) : _channel = channel;

  static const String channelName = 'mixtape/speech';

  final MethodChannel _channel;

  /// The recogniser reports no progress on a file it cannot make sense of, so
  /// the wait is bounded here rather than left to the host.
  final Duration timeout;

  /// The transcript of the clip at [path], trimmed.
  ///
  /// Throws [SpeechException] for every other outcome, including a blank
  /// transcript: an empty field is not an answer the composer can show.
  Future<String> transcribeFile(String path) async {
    try {
      final text = await _channel
          .invokeMethod<String>('transcribeFile', path)
          .timeout(timeout);
      final trimmed = text?.trim() ?? '';
      if (trimmed.isEmpty) throw const SpeechException(SpeechFailure.failed);
      return trimmed;
    } on PlatformException catch (error) {
      throw SpeechException(_failureFor(error.code));
    } on MissingPluginException {
      // Android, or an iOS build without the transcriber registered.
      throw const SpeechException(SpeechFailure.unavailable);
    } on TimeoutException {
      throw const SpeechException(SpeechFailure.failed);
    }
  }

  static SpeechFailure _failureFor(String code) => switch (code) {
        'PERMISSION_DENIED' ||
        'PERMISSION_RESTRICTED' ||
        'PERMISSION_NOT_DETERMINED' =>
          SpeechFailure.permissionDenied,
        'RECOGNIZER_UNAVAILABLE' => SpeechFailure.unavailable,
        _ => SpeechFailure.failed,
      };
}
