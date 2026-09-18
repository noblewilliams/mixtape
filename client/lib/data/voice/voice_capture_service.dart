import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

/// Where the composer's mic is in its cycle.
enum VoiceCaptureState {
  idle,

  /// Recording; the composer shows the level meter and "Listening…".
  listening,

  /// A clip is recorded and on its way to a transcriber.
  transcribing,

  /// The last attempt ended in an error the composer has shown.
  failed,
}

/// Why a recording could not start, or produced nothing.
enum VoiceCaptureFailure {
  /// The microphone is not ours to use.
  permissionDenied,

  /// Music is playing: recording would take the playback session away.
  playbackActive,

  /// No recorder, no audio session, no input — nothing to record with.
  unavailable,

  /// Recorded, but too little to be anyone speaking.
  noAudio,
}

class VoiceCaptureException implements Exception {
  const VoiceCaptureException(this.failure);

  final VoiceCaptureFailure failure;

  @override
  String toString() => 'VoiceCaptureException(${failure.name})';
}

/// The slice of `record`'s `AudioRecorder` this service uses, so the state
/// machine can be driven by a fake in tests.
abstract class VoiceRecorder {
  Future<bool> hasPermission();
  Future<void> start(RecordConfig config, {required String path});
  Future<String?> stop();
  Stream<Amplitude> onAmplitudeChanged(Duration interval);
  Future<void> dispose();
}

/// The real recorder.
class RecordVoiceRecorder implements VoiceRecorder {
  RecordVoiceRecorder() : _recorder = AudioRecorder() {
    // We activate the iOS session ourselves over `mixtape/audio_session`,
    // before the recorder would, so the activation can refuse over live
    // playback instead of silently taking the session.
    if (!kIsWeb && Platform.isIOS) _recorder.ios?.manageAudioSession(false);
  }

  final AudioRecorder _recorder;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<void> start(RecordConfig config, {required String path}) =>
      _recorder.start(config, path: path);

  @override
  Future<String?> stop() => _recorder.stop();

  @override
  Stream<Amplitude> onAmplitudeChanged(Duration interval) =>
      _recorder.onAmplitudeChanged(interval);

  @override
  Future<void> dispose() => _recorder.dispose();
}

/// Records one spoken idea to a temp file and reports its level while it does.
///
/// The clip is a recording of a listener's voice: it lives in the app's own
/// temporary directory, is never logged, and is deleted on every path out of
/// here — cancelled, too short, transcribed, or disposed mid-recording.
class VoiceCaptureService {
  VoiceCaptureService({
    VoiceRecorder Function()? recorderFactory,
    MethodChannel audioSession = const MethodChannel(audioSessionChannel),
    Directory? clipDirectory,
    bool? manageAudioSession,
  })  : _recorderFactory = recorderFactory ?? RecordVoiceRecorder.new,
        _audioSession = audioSession,
        _clipDirectory = clipDirectory ?? Directory.systemTemp,
        _manageAudioSession =
            manageAudioSession ?? (!kIsWeb && Platform.isIOS);

  static const String audioSessionChannel = 'mixtape/audio_session';

  /// The route's own floor. A shorter clip is a mic that never opened, and is
  /// not worth a round trip.
  static const int minimumClipBytes = 1024;

  /// Quiet enough to read as silence on the meter. Anything below is 0.
  static const double amplitudeFloorDb = -50;

  /// Fast enough for the meter to look alive, slow enough to be cheap.
  static const Duration amplitudeInterval = Duration(milliseconds: 120);

  /// Mono AAC-LC: what Whisper and `SFSpeechRecognizer` both read, at the size
  /// a phone can upload over a cell connection.
  static const RecordConfig recordConfig = RecordConfig(
    encoder: AudioEncoder.aacLc,
    sampleRate: 44100,
    numChannels: 1,
  );

  final VoiceRecorder Function() _recorderFactory;
  final MethodChannel _audioSession;
  final Directory _clipDirectory;
  final bool _manageAudioSession;

  final _states = StreamController<VoiceCaptureState>.broadcast();
  final _amplitude = StreamController<double>.broadcast();

  VoiceRecorder? _recorder;
  StreamSubscription<Amplitude>? _levels;
  bool _sessionActive = false;
  File? _clip;
  VoiceCaptureState _state = VoiceCaptureState.idle;

  VoiceCaptureState get state => _state;

  /// Every transition after the first, for the composer to follow.
  Stream<VoiceCaptureState> get states => _states.stream;

  /// Input level, 0–1, while listening. Nothing is emitted otherwise.
  Stream<double> get amplitude => _amplitude.stream;

  /// Ask for the microphone, take the audio session, and start recording.
  ///
  /// Throws [VoiceCaptureException]; a second call while already listening
  /// does nothing.
  Future<void> start() async {
    if (_state == VoiceCaptureState.listening) return;

    final recorder = _recorder ??= _recorderFactory();

    if (!await recorder.hasPermission()) {
      _moveTo(VoiceCaptureState.failed);
      throw const VoiceCaptureException(VoiceCaptureFailure.permissionDenied);
    }

    await _activateAudioSession();

    final clip = File(
      '${_clipDirectory.path}/mixtape-idea-'
      '${DateTime.now().millisecondsSinceEpoch}.m4a',
    );
    try {
      await recorder.start(recordConfig, path: clip.path);
    } catch (_) {
      // A recorder that failed to start can be in any state at all; the next
      // attempt gets a new one rather than inheriting this one — and the
      // session goes back, since nothing here is recording after all.
      await _disposeRecorder();
      await _deactivateAudioSession();
      _moveTo(VoiceCaptureState.failed);
      throw const VoiceCaptureException(VoiceCaptureFailure.unavailable);
    }

    _clip = clip;
    _levels = recorder
        .onAmplitudeChanged(amplitudeInterval)
        .listen((level) => _amplitude.add(normalise(level.current)));
    _moveTo(VoiceCaptureState.listening);
  }

  /// Stop recording and hand the clip over for transcription.
  ///
  /// Throws [VoiceCaptureFailure.noAudio] — having deleted the clip — when
  /// nothing worth transcribing was recorded.
  Future<File> stop() async {
    final clip = _clip;
    _clip = null;
    await _stopLevels();
    var stopped = true;
    try {
      await _recorder?.stop();
    } catch (_) {
      // A recorder that will not stop has no clip to give: whatever is on
      // disk is a partial file nobody should transcribe.
      stopped = false;
    }
    await _deactivateAudioSession();

    if (!stopped ||
        clip == null ||
        !clip.existsSync() ||
        clip.lengthSync() < minimumClipBytes) {
      if (clip != null) await discard(clip);
      _moveTo(VoiceCaptureState.failed);
      throw const VoiceCaptureException(VoiceCaptureFailure.noAudio);
    }

    _moveTo(VoiceCaptureState.transcribing);
    return clip;
  }

  /// Stop recording and throw the clip away.
  Future<void> cancel() async {
    if (_state != VoiceCaptureState.listening) return;
    final clip = _clip;
    _clip = null;
    await _stopLevels();
    try {
      await _recorder?.stop();
    } catch (_) {
      // Already stopped, or a recorder that died: the clip still goes.
    }
    await _deactivateAudioSession();
    if (clip != null) await discard(clip);
    _moveTo(VoiceCaptureState.idle);
  }

  /// Delete a clip handed over by [stop]. Safe to call twice.
  Future<void> discard(File clip) async {
    try {
      if (clip.existsSync()) await clip.delete();
    } catch (_) {
      // A clip we cannot delete is one iOS will take with the temp directory.
    }
  }

  /// The attempt ended in an error the composer is showing.
  void markFailed() => _moveTo(VoiceCaptureState.failed);

  /// Back to idle, once the transcript landed or the error was shown.
  void settle() => _moveTo(VoiceCaptureState.idle);

  Future<void> dispose() async {
    final clip = _clip;
    _clip = null;
    await _stopLevels();
    await _disposeRecorder();
    await _deactivateAudioSession();
    if (clip != null) await discard(clip);
    _state = VoiceCaptureState.idle;
    await _states.close();
    await _amplitude.close();
  }

  /// dBFS to 0–1 against [amplitudeFloorDb].
  @visibleForTesting
  static double normalise(double decibels) =>
      ((decibels - amplitudeFloorDb) / -amplitudeFloorDb).clamp(0.0, 1.0);

  Future<void> _activateAudioSession() async {
    if (!_manageAudioSession) return;
    try {
      await _audioSession.invokeMethod<bool>('activate');
      _sessionActive = true;
    } on PlatformException catch (error) {
      _moveTo(VoiceCaptureState.failed);
      throw VoiceCaptureException(
        error.code == 'PLAYBACK_ACTIVE'
            ? VoiceCaptureFailure.playbackActive
            : VoiceCaptureFailure.unavailable,
      );
    } on MissingPluginException {
      // No host handler: nothing to activate, and nothing to refuse either.
    }
  }

  /// Hand `.playAndRecord` back. Until this runs, our own MusicKit playback
  /// and every other app are stuck behind a recording category that is no
  /// longer recording anything.
  Future<void> _deactivateAudioSession() async {
    if (!_sessionActive) return;
    _sessionActive = false;
    try {
      await _audioSession.invokeMethod<bool>('deactivate');
    } catch (_) {
      // Best effort: a session we cannot hand back is one iOS reclaims when
      // the app is next backgrounded.
    }
  }

  Future<void> _stopLevels() async {
    await _levels?.cancel();
    _levels = null;
  }

  Future<void> _disposeRecorder() async {
    final recorder = _recorder;
    _recorder = null;
    try {
      await recorder?.dispose();
    } catch (_) {
      // Nothing left to do about a recorder that will not close.
    }
  }

  void _moveTo(VoiceCaptureState next) {
    if (_state == next) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }
}
