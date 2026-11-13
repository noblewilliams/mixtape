import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'voice_capture_service.dart';

/// Why live dictation could not start or finish.
enum DictationFailure {
  /// Speech recognition is denied or restricted: the recorded path still
  /// works, without words as they are spoken.
  speechDenied,

  /// The microphone is not ours to use.
  micDenied,

  /// Music is playing through our own MusicKit session.
  playbackActive,

  /// No recogniser here (off iOS, or none for any locale).
  unavailable,

  /// Anything else the recogniser or the audio engine reported.
  failed,
}

class DictationException implements Exception {
  const DictationException(this.failure);

  final DictationFailure failure;

  @override
  String toString() => 'DictationException(${failure.name})';
}

/// What a dictation left behind: the recorded clip, for the server's better
/// pass, and the words the recogniser heard live.
class DictationResult {
  const DictationResult({required this.path, required this.text});

  final String? path;
  final String text;
}

/// Words while they are spoken (device smoke, 2026-11-13).
///
/// The slice of [LiveDictation] the composer's use case drives, so a test can
/// stand in for the device.
abstract class LiveTranscriber {
  /// The recogniser's running transcript, replaced (not appended) each time.
  Stream<String> get partials;

  /// Input level, 0–1, for the meter.
  Stream<double> get levels;

  /// Open the microphone and start hearing. Throws [DictationException].
  Future<void> start({List<String> vocabulary = const []});

  /// Stop hearing; the clip and the last words. Throws [DictationException].
  Future<DictationResult> stop();

  /// Stop hearing and throw the clip away.
  Future<void> cancel();

  /// Delete a clip [stop] handed back.
  Future<void> discard(String? path);
}

/// Apple's recogniser fed from the microphone as the listener speaks, over
/// `mixtape/dictation` (start, stop, cancel) and `mixtape/dictation/events`
/// (`{type: partial, text}` and `{type: level, value}`). The same audio is
/// written to a clip so the server can make a better pass once it ends.
///
/// The words are a listener's own and the clip is their voice: neither is
/// logged, here or natively, and the clip is deleted on every path out.
class LiveDictation implements LiveTranscriber {
  LiveDictation({
    MethodChannel methods = const MethodChannel(channelName),
    EventChannel events = const EventChannel(eventsName),
    MethodChannel audioSession = const MethodChannel(
      VoiceCaptureService.audioSessionChannel,
    ),
    Directory? clipDirectory,
    bool? available,
  }) : _methods = methods,
       _events = events,
       _audioSession = audioSession,
       _clipDirectory = clipDirectory ?? Directory.systemTemp,
       _available = available ?? (!kIsWeb && Platform.isIOS);

  static const String channelName = 'mixtape/dictation';
  static const String eventsName = 'mixtape/dictation/events';

  final MethodChannel _methods;
  final EventChannel _events;
  final MethodChannel _audioSession;
  final Directory _clipDirectory;
  final bool _available;

  final _partials = StreamController<String>.broadcast();
  final _levels = StreamController<double>.broadcast();
  StreamSubscription<Object?>? _subscription;

  @override
  Stream<String> get partials => _partials.stream;

  @override
  Stream<double> get levels => _levels.stream;

  @override
  Future<void> start({List<String> vocabulary = const []}) async {
    if (!_available) throw const DictationException(DictationFailure.unavailable);
    await _activate();
    _subscription ??= _events.receiveBroadcastStream().listen(
      _onEvent,
      // A broken event stream costs the live words, not the dictation: the
      // clip still records and the server still answers.
      onError: (Object _) {},
    );
    final path =
        '${_clipDirectory.path}/mixtape-dictation-'
        '${DateTime.now().microsecondsSinceEpoch}.m4a';
    try {
      await _methods.invokeMethod<void>('start', {
        'path': path,
        'contextualStrings': vocabulary,
      });
    } on PlatformException catch (error) {
      await _deactivate();
      throw DictationException(_failureFor(error.code));
    } on MissingPluginException {
      await _deactivate();
      throw const DictationException(DictationFailure.unavailable);
    }
  }

  @override
  Future<DictationResult> stop() async {
    try {
      final answer = await _methods.invokeMapMethod<String, Object?>('stop');
      final path = answer?['path'];
      final text = answer?['text'];
      return DictationResult(
        path: path is String && path.isNotEmpty ? path : null,
        text: text is String ? text.trim() : '',
      );
    } on PlatformException {
      throw const DictationException(DictationFailure.failed);
    } on MissingPluginException {
      throw const DictationException(DictationFailure.unavailable);
    } finally {
      await _deactivate();
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _methods.invokeMethod<void>('cancel');
    } catch (_) {
      // Nothing to give back if the host never started.
    }
    await _deactivate();
  }

  @override
  Future<void> discard(String? path) async {
    if (path == null) return;
    try {
      final clip = File(path);
      if (clip.existsSync()) await clip.delete();
    } catch (_) {
      // The temp directory is the OS's to clear if we cannot.
    }
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    await _partials.close();
    await _levels.close();
  }

  void _onEvent(Object? event) {
    if (event is! Map) return;
    switch (event['type']) {
      case 'partial':
        final text = event['text'];
        if (text is String && !_partials.isClosed) _partials.add(text);
      case 'level':
        final value = event['value'];
        if (value is num && !_levels.isClosed) {
          _levels.add(value.toDouble().clamp(0.0, 1.0));
        }
    }
  }

  Future<void> _activate() async {
    try {
      await _audioSession.invokeMethod<bool>('activate');
    } on PlatformException catch (error) {
      if (error.code == 'PLAYBACK_ACTIVE') {
        throw const DictationException(DictationFailure.playbackActive);
      }
      throw const DictationException(DictationFailure.unavailable);
    } on MissingPluginException {
      // No host session to manage: nothing to refuse either.
    }
  }

  Future<void> _deactivate() async {
    try {
      await _audioSession.invokeMethod<bool>('deactivate');
    } catch (_) {
      // Best effort, as the recorder's own hand-back is.
    }
  }

  static DictationFailure _failureFor(String code) => switch (code) {
    'SPEECH_DENIED' => DictationFailure.speechDenied,
    'MIC_DENIED' => DictationFailure.micDenied,
    'UNAVAILABLE' => DictationFailure.unavailable,
    _ => DictationFailure.failed,
  };
}
