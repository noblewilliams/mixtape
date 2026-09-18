import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/voice/speech_channel.dart';
import '../../data/voice/transcription_api.dart';
import '../../data/voice/voice_capture_service.dart';
import 'auth_provider.dart';
import 'onboarding_provider.dart';

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
  }) : _capture = capture,
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
  static const String unauthorizedCopy = 'Sign in again to speak your idea.';

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
        TranscriptionFailure.network => true,
        // The server read the clip and refused it, or refused us: asking a
        // weaker transcriber the same question wastes the listener's time.
        TranscriptionFailure.tooShort ||
        TranscriptionFailure.tooLarge ||
        TranscriptionFailure.unauthorized => false,
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
        VoiceCaptureFailure.noAudio => const VoiceInputException(
          VoiceInputFailure.noAudio,
          noAudioCopy,
        ),
        VoiceCaptureFailure.unavailable => const VoiceInputException(
          VoiceInputFailure.failed,
          failedCopy,
        ),
      };

  static VoiceInputException _fromServer(TranscriptionFailure failure) =>
      switch (failure) {
        TranscriptionFailure.tooShort => const VoiceInputException(
          VoiceInputFailure.noAudio,
          noAudioCopy,
        ),
        TranscriptionFailure.tooLarge => const VoiceInputException(
          VoiceInputFailure.failed,
          tooLongCopy,
        ),
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

/// Where the composer's voice input is, for the mic, the meter and the
/// failure line under the field.
enum VoiceComposerState {
  idle,

  /// Recording: the field shows the meter and "Listening…".
  listening,

  /// Stopped, waiting on a transcript; the meter is frozen.
  transcribing,

  /// The last attempt failed and the composer is showing why.
  failed,
}

/// The composer's half of voice input.
///
/// Owns nothing but the state the field draws from: the recorder and the
/// transcriber live behind the three callbacks, so Home and a conversation
/// share one microphone and a test can drive this by hand.
class VoiceComposerController extends ChangeNotifier {
  VoiceComposerController({
    required Future<void> Function() onStart,
    required Future<String> Function() onStop,
    required Future<void> Function() onCancel,
    Stream<double>? amplitude,
    Future<bool> Function()? probeSettings,
    Future<void> Function()? onOpenSettings,
  }) : _onStart = onStart,
       _onStop = onStop,
       _onCancel = onCancel,
       _amplitude = amplitude,
       _probeSettings = probeSettings,
       _onOpenSettings = onOpenSettings;

  /// The live wiring: one recorder, one transcriber, the device's Settings.
  factory VoiceComposerController.of(
    TranscribeRecording recorder, {
    Stream<double>? amplitude,
    Future<bool> Function(Uri uri)? probe,
    Future<bool> Function(Uri uri)? open,
  }) {
    Future<T> settings<T>(Future<T> Function(Uri uri)? call, T fallback) async {
      if (call == null) return fallback;
      try {
        return await call(appSettings);
      } catch (_) {
        // A device that will not answer about its own Settings has none to
        // offer: the composer simply drops the action.
        return fallback;
      }
    }

    return VoiceComposerController(
      onStart: recorder.begin,
      onStop: recorder.finish,
      onCancel: recorder.abandon,
      amplitude: amplitude,
      probeSettings: () => settings(probe, false),
      onOpenSettings: () async {
        await settings(open, false);
      },
    );
  }

  /// iOS' own deep link to this app's Settings pane.
  static final Uri appSettings = Uri(scheme: 'app-settings');

  final Future<void> Function() _onStart;
  final Future<String> Function() _onStop;
  final Future<void> Function() _onCancel;
  final Stream<double>? _amplitude;
  final Future<bool> Function()? _probeSettings;
  final Future<void> Function()? _onOpenSettings;

  StreamSubscription<double>? _levels;
  VoiceComposerState _state = VoiceComposerState.idle;
  double _level = 0;
  VoiceInputException? _failure;
  bool _settingsAvailable = false;
  bool _disposed = false;

  VoiceComposerState get state => _state;

  /// Input level, 0–1. Held where it was while a transcript is on its way.
  double get level => _level;

  /// The last failure, with the one sentence the composer shows.
  VoiceInputException? get failure => _failure;

  /// The microphone is open or a transcript is on its way.
  bool get busy =>
      _state == VoiceComposerState.listening ||
      _state == VoiceComposerState.transcribing;

  /// Whether this device can open Settings for a denied microphone.
  bool get settingsAvailable => _settingsAvailable;

  /// Open the microphone. Failures land in [failure] rather than throwing:
  /// the composer shows them under the field.
  Future<void> start() async {
    if (busy) return;
    _failure = null;
    _settingsAvailable = false;
    _level = 0;
    _notify();
    try {
      await _onStart();
    } on VoiceInputException catch (error) {
      _fail(error);
      return;
    } catch (_) {
      _fail(_unknown);
      return;
    }
    if (_disposed) {
      unawaited(_onCancel());
      return;
    }
    _state = VoiceComposerState.listening;
    _levels = _amplitude?.listen((level) {
      if (_state != VoiceComposerState.listening) return;
      _level = level.clamp(0.0, 1.0);
      _notify();
    });
    _notify();
  }

  /// Stop recording and hand back the transcript, or null if there is none.
  Future<String?> stop() async {
    if (_state != VoiceComposerState.listening) return null;
    _state = VoiceComposerState.transcribing;
    _notify();
    final String text;
    try {
      text = (await _onStop()).trim();
    } on VoiceInputException catch (error) {
      _fail(error);
      return null;
    } catch (_) {
      _fail(_unknown);
      return null;
    }
    if (text.isEmpty) {
      _fail(
        const VoiceInputException(
          VoiceInputFailure.noAudio,
          TranscribeRecording.noAudioCopy,
        ),
      );
      return null;
    }
    _stopLevels();
    _state = VoiceComposerState.idle;
    _level = 0;
    _notify();
    return text;
  }

  /// Give the microphone back without transcribing — leaving the screen.
  Future<void> cancel() async {
    if (!busy) return;
    _state = VoiceComposerState.idle;
    _level = 0;
    _stopLevels();
    _notify();
    await _onCancel();
  }

  /// Open this app's Settings pane, where the microphone can be allowed.
  Future<void> openSettings() async => _onOpenSettings?.call();

  /// The composer dismissed the failure line.
  void clearFailure() {
    if (_failure == null && _state != VoiceComposerState.failed) return;
    _failure = null;
    _settingsAvailable = false;
    if (_state == VoiceComposerState.failed) _state = VoiceComposerState.idle;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _stopLevels();
    if (busy) {
      _state = VoiceComposerState.idle;
      unawaited(_onCancel());
    }
    super.dispose();
  }

  static const VoiceInputException _unknown = VoiceInputException(
    VoiceInputFailure.failed,
    TranscribeRecording.failedCopy,
  );

  void _fail(VoiceInputException error) {
    _failure = error;
    _state = VoiceComposerState.failed;
    _level = 0;
    _settingsAvailable = false;
    _stopLevels();
    _notify();
    if (error.failure != VoiceInputFailure.permissionDenied) return;
    unawaited(() async {
      final available = await (_probeSettings?.call() ?? Future.value(false));
      if (_disposed || _failure != error) return;
      _settingsAvailable = available;
      _notify();
    }());
  }

  /// Stop reading the microphone's level. Deliberately not awaited: a
  /// cancelled subscription is not worth holding a transition behind.
  void _stopLevels() {
    final levels = _levels;
    _levels = null;
    unawaited(levels?.cancel() ?? Future<void>.value());
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}

/// The composer's voice state. One per app: the microphone is not shareable,
/// and Home and a conversation are never listening at the same time.
final voiceComposerControllerProvider = Provider<VoiceComposerController>((
  ref,
) {
  final controller = VoiceComposerController.of(
    ref.watch(transcribeRecordingProvider),
    amplitude: ref.watch(voiceCaptureServiceProvider).amplitude,
    probe: ref.watch(linkProbeProvider),
    open: ref.watch(linkOpenerProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});
