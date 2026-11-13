import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../api/api_client.dart';
import '../dj/dj_models.dart';
import 'listening_meter.dart';
import 'playback_api.dart';
import 'player_bridge.dart';

String playbackUuid() {
  final r = Random.secure();
  final b = List.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 15) | 64;
  b[8] = (b[8] & 63) | 128;
  final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// How a [PlaybackController.start] ended, for whoever asked it to start.
enum PlaybackStart {
  /// The app's own player is playing the mix.
  started,

  /// A later start, a stop or disposal overtook this one (or another start
  /// was already in hand): nothing to act on.
  superseded,

  /// The app's player cannot play it: access refused, a song it cannot find,
  /// a native failure. [PlaybackController.failureCode] says which.
  unavailable,

  /// Apple says this account cannot play catalogue music.
  subscriptionRequired,
}

/// The line the player shows for a native failure code. One per cause, so
/// the listener reads what actually went wrong (decision 4 of
/// `docs/superpowers/specs/2026-11-09-one-platform-play-design.md`).
///
/// Lines about access or a start Apple Music would not make begin with
/// "Apple Music": `PlaybackScreen.connectErrorMark` reads that as the
/// Connect Apple Music state.
String playbackFailureLine(String code) => switch (code) {
  'authorization_required' || 'authorization_denied' =>
    'Apple Music access was not granted. Your mix is unchanged.',
  'subscription_required' => 'Playing needs an Apple Music subscription.',
  'song_unavailable' => 'This song cannot play here. Your mix is unchanged.',
  'empty_queue' => 'None of these songs can play here. Your mix is unchanged.',
  _ => 'Apple Music did not start playing. Try again.',
};

/// The player's session id for a shared mix (spec 2026-11-13 shared-mixes):
/// `shared:<token>`. Not a session of the listener's, so nothing that reads
/// a session (its shape, its tape) applies to it.
const sharedPlaybackPrefix = 'shared:';

/// Whether the player's [id] is a shared mix rather than one of the
/// listener's own.
bool isSharedPlayback(String? id) =>
    id != null && id.startsWith(sharedPlaybackPrefix);

final _playbackStorageWrites = <String, Future<void>>{};

class PlaybackController extends ChangeNotifier {
  PlaybackController(this.api, this.bridge, {FlutterSecureStorage? storage})
    : storage = storage ?? const FlutterSecureStorage() {
    meter = ListeningMeter(_record);
  }
  final PlaybackApi api;
  final AppPlayerBridge bridge;
  final FlutterSecureStorage storage;
  late final ListeningMeter meter;
  final clock = Stopwatch()..start();
  String? sessionId, owner;
  String title = '', playbackId = '', error = '';

  /// The tape colour (hex) the starter knew the mix by, for a mix the
  /// listener's own list does not carry: a shared mix's, which would
  /// otherwise fall back to a colour hashed from its id. Null for the
  /// listener's own mixes, whose colour comes from their list.
  String? caseColor;

  /// The native `PlatformException.code` of the last failed start, intact
  /// (`authorization_denied` when the access prompt was refused); null after
  /// a start that worked.
  String? failureCode;
  int? unavailableIndex;
  int version = 0, sequence = 0, _generation = 0;
  List<QueueTrack> tracks = [];
  PlayerSample sample = const PlayerSample(
    index: null,
    positionMs: 0,
    status: 'stopped',
  );
  Map<String, dynamic>? preferences;
  String? _clearId;
  int? _clearRevision;
  bool _startFailed = false;
  bool _recording = true;

  /// Whether the mix on the player counts as listening evidence. A shared
  /// mix does not: it is someone else's, and the listener did not ask for it
  /// (as the web's `record: false`).
  bool get recording => _recording;
  bool busy = false, _disposed = false, _sending = false;
  List<Map<String, dynamic>> _pending = [];
  StreamSubscription<PlayerSample>? _subscription;
  Timer? _retry;
  Future<void>? _initializing;
  Future<void> _storageTail = Future.value();
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    try {
      final prefs = await api.preferences();
      if (_disposed) return;
      preferences = prefs;
      owner = prefs['userId'] as String?;
      if (owner != null) {
        await _playbackStorageWrites['playback.$owner'];
        final raw = await storage.read(key: 'playback.$owner');
        if (_disposed) return;
        final saved = raw == null ? null : jsonDecode(raw);
        if (prefs['enabled'] == true &&
            saved is Map &&
            saved['revision'] == prefs['revision']) {
          _pending = (saved['events'] as List)
              .cast<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .where(
                (e) =>
                    DateTime.tryParse(e['occurredAt'] as String)?.isAfter(
                      DateTime.now().subtract(const Duration(days: 7)),
                    ) ??
                    false,
              )
              .take(100)
              .toList();
        }
      }
      _persist();
      unawaited(_flush());
    } catch (_) {
      /* No consent confirmed: playback works without collection. */
    }
    if (_disposed) return;
    _subscription = bridge.samples.listen(
      (value) {
        sample = value;
        if (!busy && preferences?['enabled'] == true) {
          meter.sample(value, clock.elapsedMilliseconds);
        }
        _notify();
      },
      onError: (_) {
        if (!_disposed) {
          meter.seek();
          error = 'Playback observation is unavailable.';
          _notify();
        }
      },
    );
    _notify();
  }

  void _persist() {
    final key = owner == null ? null : 'playback.$owner';
    if (key == null) return;
    final value = _pending.isEmpty
        ? null
        : jsonEncode({
            'revision': preferences?['revision'],
            'events': _pending,
          });
    _storageTail = (_playbackStorageWrites[key] ?? Future<void>.value())
        .catchError((_) {})
        .then((_) async {
          if (value == null) {
            await storage.delete(key: key);
          } else {
            await storage.write(key: key, value: value);
          }
        })
        .catchError((_) {});
    _playbackStorageWrites[key] = _storageTail;
    final write = _storageTail;
    unawaited(
      write.then((_) {
        if (identical(_playbackStorageWrites[key], write)) {
          _playbackStorageWrites.remove(key);
        }
      }),
    );
  }

  void _record(int index, int ms, String kind) {
    if (_disposed ||
        !_recording ||
        preferences?['enabled'] != true ||
        index >= tracks.length) {
      return;
    }
    final track = tracks[index];
    if (kind == 'skip' && qualifies('listen', ms, track.durationMs ?? 0)) {
      kind = 'listen';
    }
    if (!qualifies(kind, ms, track.durationMs ?? 0)) return;
    _pending.add({
      'playbackId': playbackId,
      'sequence': sequence++,
      'sessionId': sessionId,
      'version': version,
      'position': track.position,
      'trackId': track.trackId,
      'source': 'apple_native',
      'kind': kind,
      'observedMs': ms,
      'occurredAt': DateTime.now().toUtc().toIso8601String(),
    });
    if (_pending.length > 100) _pending.removeAt(0);
    _persist();
    unawaited(_flush());
  }

  Future<void> _flush() async {
    if (_sending ||
        _disposed ||
        preferences?['enabled'] != true ||
        _pending.isEmpty) {
      return;
    }
    _sending = true;
    final events = _pending.take(20).toList();
    final revision = preferences!['revision'] as int;
    try {
      await api.send(revision, events);
      if (!_disposed && preferences?['revision'] == revision) {
        final ids = events
            .map((e) => '${e['playbackId']}:${e['sequence']}')
            .toSet();
        _pending.removeWhere(
          (e) => ids.contains('${e['playbackId']}:${e['sequence']}'),
        );
        _persist();
      }
    } on ApiException catch (e) {
      if ([400, 401, 404, 409].contains(e.statusCode)) {
        _pending = [];
        _persist();
        if (e.statusCode == 409) {
          meter.reset();
          preferences = null;
          _notify();
        }
      }
    } catch (_) {
    } finally {
      _sending = false;
      if (!_disposed && _pending.isNotEmpty) {
        _retry?.cancel();
        _retry = Timer(const Duration(seconds: 30), () => unawaited(_flush()));
      }
    }
  }

  /// Starts [queue] on the app's own player.
  ///
  /// Asks for Apple Music access itself when the native side reports it was
  /// never granted (the system prompt shows on the Play tap; once decided,
  /// `MusicAuthorization.request` answers without prompting), then tries
  /// once more. Every other native failure keeps its code in [failureCode].
  ///
  /// [record] false plays without collecting listening evidence (a shared
  /// mix); the mix it replaces still records the listen it was on.
  /// [caseColor] is the mix's tape colour when only the starter knows it
  /// (a shared mix); see [PlaybackController.caseColor].
  Future<PlaybackStart> start(
    String id,
    int mixVersion,
    String mixTitle,
    List<QueueTrack> queue, {
    bool record = true,
    String? caseColor,
  }) async {
    if (busy) return PlaybackStart.superseded;
    busy = true;
    error = '';
    failureCode = null;
    unavailableIndex = null;
    _startFailed = false;
    _notify();
    final generation = ++_generation;
    await initialize();
    if (_disposed || generation != _generation) return PlaybackStart.superseded;
    meter.finish('listen');
    _recording = record;
    this.caseColor = caseColor;
    sessionId = id;
    version = mixVersion;
    title = mixTitle;
    tracks = List.unmodifiable(queue.where((t) => t.appleId != null));
    playbackId = playbackUuid();
    sequence = 0;
    sample = const PlayerSample(index: null, positionMs: 0, status: 'waiting');
    _notify();
    final ids = tracks.map((t) => t.appleId!).toList();
    String? code;
    try {
      try {
        await bridge.start(ids);
      } on PlatformException catch (e) {
        if (e.code != 'authorization_required') rethrow;
        bool allowed;
        try {
          allowed = await bridge.authorize();
        } catch (_) {
          allowed = false;
        }
        if (_disposed || generation != _generation) {
          return PlaybackStart.superseded;
        }
        if (!allowed) {
          code = 'authorization_denied';
        } else {
          await bridge.start(ids);
        }
      }
    } catch (e) {
      code = e is PlatformException ? e.code : 'playback_failed';
      if (e is PlatformException && e.details is Map) {
        unavailableIndex = (e.details as Map)['index'] as int?;
      }
    } finally {
      if (!_disposed && generation == _generation) {
        if (code != null) {
          _startFailed = true;
          failureCode = code;
          error = playbackFailureLine(code);
        }
        busy = false;
        _notify();
      }
    }
    if (_disposed || generation != _generation) return PlaybackStart.superseded;
    return switch (code) {
      null => PlaybackStart.started,
      'subscription_required' => PlaybackStart.subscriptionRequired,
      _ => PlaybackStart.unavailable,
    };
  }

  /// Forgets a mix the app's player could not start, once it has gone to the
  /// Music app instead: no mini-player, no Now Playing left holding a
  /// failure for a mix that is playing somewhere else.
  void release() {
    if (busy) return;
    ++_generation;
    meter.reset();
    sessionId = null;
    caseColor = null;
    tracks = [];
    title = '';
    error = '';
    failureCode = null;
    unavailableIndex = null;
    _startFailed = false;
    sample = const PlayerSample(index: null, positionMs: 0, status: 'stopped');
    _notify();
  }

  Future<void> command(String action, {double? seconds}) async {
    if (busy) return;
    if (_startFailed) {
      if (action == 'next' || action == 'resume') {
        await start(
          sessionId!,
          version,
          title,
          action == 'next'
              ? tracks
                    .skip((unavailableIndex ?? sample.index ?? 0) + 1)
                    .toList()
              : tracks,
          record: _recording,
          caseColor: caseColor,
        );
      }
      return;
    }
    busy = true;
    error = '';
    _notify();
    try {
      if (action == 'next') meter.intent = 'skip';
      if (action == 'repeat') {
        meter.intent = 'repeat';
        await bridge.command('seek', seconds: 0);
        await bridge.command('resume');
      } else {
        if (action == 'seek') meter.seek();
        await bridge.command(action, seconds: seconds);
      }
    } catch (_) {
      meter.intent = null;
      error = 'Playback was interrupted. Try again when you are ready.';
    } finally {
      if (!_disposed) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> reconnect() async {
    if (busy || sessionId == null) return;
    final generation = ++_generation;
    busy = true;
    error = '';
    _notify();
    try {
      final allowed = await bridge.authorize();
      if (_disposed || generation != _generation) return;
      if (!allowed) {
        error = 'Apple Music access was not granted. Your mix is unchanged.';
        return;
      }
      busy = false;
      await start(
        sessionId!,
        version,
        title,
        tracks,
        record: _recording,
        caseColor: caseColor,
      );
    } catch (_) {
      if (generation == _generation) {
        error = 'Apple Music access was not granted. Your mix is unchanged.';
      }
    } finally {
      if (!_disposed && generation == _generation) {
        busy = false;
        _notify();
      }
    }
  }

  Future<void> stop() async {
    if (busy) _startFailed = true;
    ++_generation;
    meter.finish('listen');
    busy = false;
    sample = PlayerSample(
      index: sample.index,
      positionMs: sample.positionMs,
      status: 'stopped',
    );
    _notify();
    try {
      await bridge.command('stop');
    } catch (_) {
      if (!_disposed) {
        error = 'Could not stop playback. Try again.';
        _notify();
      }
    }
  }

  Future<void> setLearning(bool enabled) async {
    meter.reset();
    _pending = [];
    _persist();
    preferences = null;
    _notify();
    final prefs = await api.save(enabled);
    if (!_disposed) {
      preferences = prefs;
      _notify();
    }
  }

  Future<void> clear(String requestId) async {
    if (_clearId != requestId) {
      final prefs = preferences ?? await api.preferences();
      _clearId = requestId;
      _clearRevision = prefs['revision'] as int;
    }
    meter.reset();
    _pending = [];
    _persist();
    preferences = null;
    _notify();
    try {
      final prefs = await api.clear(requestId, _clearRevision!);
      if (!_disposed) {
        preferences = prefs;
        _clearId = null;
        _notify();
      }
    } on ApiException catch (e) {
      if (e.statusCode == 409) {
        _clearId = null;
        final prefs = await api.preferences();
        if (!_disposed) {
          preferences = prefs;
          _notify();
        }
      }
      rethrow;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    meter.reset();
    _retry?.cancel();
    unawaited(_subscription?.cancel());
    _pending = [];
    _persist();
    unawaited(bridge.command('stop').catchError((_) {}));
    super.dispose();
  }
}
