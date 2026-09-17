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

  Future<void> start(
    String id,
    int mixVersion,
    String mixTitle,
    List<QueueTrack> queue,
  ) async {
    if (busy) return;
    busy = true;
    error = '';
    unavailableIndex = null;
    _startFailed = false;
    _notify();
    final generation = ++_generation;
    await initialize();
    if (_disposed || generation != _generation) return;
    meter.finish('listen');
    sessionId = id;
    version = mixVersion;
    title = mixTitle;
    tracks = List.unmodifiable(queue.where((t) => t.appleId != null));
    playbackId = playbackUuid();
    sequence = 0;
    sample = const PlayerSample(index: null, positionMs: 0, status: 'waiting');
    _notify();
    try {
      await bridge.start(tracks.map((t) => t.appleId!).toList());
    } catch (e) {
      if (generation == _generation) _startFailed = true;
      if (e is PlatformException && e.details is Map) {
        unavailableIndex = (e.details as Map)['index'] as int?;
      }
      if (generation == _generation) {
        error =
            'Apple Music could not play this song. Check access and your subscription. Your mix is unchanged.';
      }
    } finally {
      if (!_disposed && generation == _generation) {
        busy = false;
        _notify();
      }
    }
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
      await start(sessionId!, version, title, tracks);
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
