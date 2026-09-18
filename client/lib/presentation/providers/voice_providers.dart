import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/voice/speech_channel.dart';
import '../../data/voice/transcription_api.dart';
import '../../data/voice/voice_capture_service.dart';
import 'auth_provider.dart';

/// What the composer shows when voice input does not produce a transcript.
enum VoiceInputFailure {
  /// The microphone is denied: only Settings can change that.
  permissionDenied,

  /// Music is playing through our own MusicKit session.
  playbackActive,

  /// Nothing worth transcribing was recorded.
  noAudio,

  /// The session is gone: the transcript needs a signed-in listener.
  unauthorized,

  /// Recorded, but neither transcriber could read it.
  failed,
}

/// A voice-input failure and the one sentence the composer shows for it.
class VoiceInputException implements Exception {
  const VoiceInputException(this.failure, this.message);

  final VoiceInputFailure failure;
  final String message;

  @override
  String toString() => 'VoiceInputException(${failure.name}): $message';
}

/// Speak an idea, get text back.
///
/// The server transcriber is the good one and goes first. Apple's on-device
/// recogniser is tried only where the server could not answer at all — the
/// route is off, upstream failed, it timed out, or the clip never left the
/// device — and never where the server looked at the clip and refused it.
///
/// The clip is deleted on every path out, including every failure.
class TranscribeRecording {
  const TranscribeRecording({
    required VoiceCaptureService capture,
    required Future<String> Function(File clip) server,
    required Future<String> Function(String path) onDevice,
    Future<void> Function()? onSessionExpired,
  })  : _capture = capture,
        _server = server,
        _onDevice = onDevice,
        _onSessionExpired = onSessionExpired;

  static const String permissionDeniedCopy =
      'Allow the microphone in Settings to speak your idea.';
  static const String playbackActiveCopy =
      'Pause the music to speak your idea.';
  static const String noAudioCopy =
      'No audio captured. Hold the button a little longer.';
  static const String tooLongCopy =
      'That was too long to transcribe. Try a shorter idea.';
  static const String failedCopy =
      'Could not hear that. Type your idea instead.';
  static const String unauthorizedCopy =
      'Sign in again to speak your idea.';

  final VoiceCaptureService _capture;
  final Future<String> Function(File clip) _server;
  final Future<String> Function(String path) _onDevice;
  final Future<void> Function()? _onSessionExpired;

  /// Start listening. Throws [VoiceInputException] if the mic never opens.
  Future<void> begin() async {
    try {
      await _capture.start();
    } on VoiceCaptureException catch (error) {
      throw _from(error.failure);
    }
  }

  /// Stop listening and return the transcript.
  Future<String> finish() async {
    final File clip;
    try {
      clip = await _capture.stop();
    } on VoiceCaptureException catch (error) {
      // The clip is already gone: `stop` deletes what it will not hand over.
      throw _from(error.failure);
    }

    try {
      final text = await _server(clip);
      await _settle(clip);
      return text;
    } on TranscriptionException catch (error) {
      if (!_worthRetryingOnDevice(error.failure)) {
        await _fail(clip);
        // A 401 is not a transcription problem: the session is over, and the
        // rest of the app finds out the same way it does everywhere else.
        if (error.failure == TranscriptionFailure.unauthorized) {
          await _onSessionExpired?.call();
        }
        throw _fromServer(error.failure);
      }
    } catch (_) {
      // An unexpected throw from the upload is still a server that did not
      // answer; the device gets its turn.
    }

    try {
      final text = await _onDevice(clip.path);
      await _settle(clip);
      return text;
    } catch (_) {
      await _fail(clip);
      throw const VoiceInputException(VoiceInputFailure.failed, failedCopy);
    }
  }

  /// Stop listening and throw the clip away without transcribing it.
  Future<void> abandon() => _capture.cancel();

  static bool _worthRetryingOnDevice(TranscriptionFailure failure) =>
      switch (failure) {
        TranscriptionFailure.notConfigured ||
        TranscriptionFailure.upstream ||
        TranscriptionFailure.timeout ||
        TranscriptionFailure.network =>
          true,
        // The server read the clip and refused it, or refused us: asking a
        // weaker transcriber the same question wastes the listener's time.
        TranscriptionFailure.tooShort ||
        TranscriptionFailure.tooLarge ||
        TranscriptionFailure.unauthorized =>
          false,
      };

  Future<void> _settle(File clip) async {
    await _capture.discard(clip);
    _capture.settle();
  }

  Future<void> _fail(File clip) async {
    await _capture.discard(clip);
    _capture.markFailed();
  }

  static VoiceInputException _from(VoiceCaptureFailure failure) =>
      switch (failure) {
        VoiceCaptureFailure.permissionDenied => const VoiceInputException(
            VoiceInputFailure.permissionDenied,
            permissionDeniedCopy,
          ),
        VoiceCaptureFailure.playbackActive => const VoiceInputException(
            VoiceInputFailure.playbackActive,
            playbackActiveCopy,
          ),
        VoiceCaptureFailure.noAudio =>
          const VoiceInputException(VoiceInputFailure.noAudio, noAudioCopy),
        VoiceCaptureFailure.unavailable =>
          const VoiceInputException(VoiceInputFailure.failed, failedCopy),
      };

  static VoiceInputException _fromServer(TranscriptionFailure failure) =>
      switch (failure) {
        TranscriptionFailure.tooShort =>
          const VoiceInputException(VoiceInputFailure.noAudio, noAudioCopy),
        TranscriptionFailure.tooLarge =>
          const VoiceInputException(VoiceInputFailure.failed, tooLongCopy),
        TranscriptionFailure.unauthorized => const VoiceInputException(
            VoiceInputFailure.unauthorized,
            unauthorizedCopy,
          ),
        _ => const VoiceInputException(VoiceInputFailure.failed, failedCopy),
      };
}

/// The recorder. One per app: it owns the microphone and the audio session.
final voiceCaptureServiceProvider = Provider<VoiceCaptureService>((ref) {
  final service = VoiceCaptureService();
  ref.onDispose(service.dispose);
  return service;
});

/// The on-device fallback. Stateless, and a no-op off iOS.
final speechChannelProvider = Provider<SpeechChannel>((ref) => SpeechChannel());

/// The server transcriber, user-scoped: it carries a session token, so a
/// sign-out disposes it and the next sign-in builds a new one.
final transcriptionApiProvider = Provider<TranscriptionApi>((ref) {
  ref.watch(authProvider);
  final api = TranscriptionApi(ref.watch(apiClientProvider));
  ref.onDispose(api.close);
  return api;
});

/// Speak an idea into the composer.
final transcribeRecordingProvider = Provider<TranscribeRecording>((ref) {
  final api = ref.watch(transcriptionApiProvider);
  final speech = ref.watch(speechChannelProvider);
  return TranscribeRecording(
    capture: ref.watch(voiceCaptureServiceProvider),
    server: api.transcribe,
    onDevice: speech.transcribeFile,
    onSessionExpired: () async {
      if (ref.read(authProvider) != AuthStatus.signedIn) return;
      try {
        await ref.read(authProvider.notifier).signOut();
      } catch (_) {
        // The composer still shows the expired-session line; a local
        // sign-out that fails must not turn into a second error.
      }
    },
  );
});
