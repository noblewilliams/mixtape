/// Mix-ready pushes (spec 2026-11-21 durable mix turns → Device
/// registration, iOS client).
///
/// The server pushes "Your mix is ready" (or a failed turn's "Oops") through
/// APNs. This side only hands it the device token: `PUT /push/devices` on
/// every launch with permission (Apple can rotate tokens), `DELETE
/// /push/devices/:token` at sign-out while the bearer is still good. No
/// Firebase: [MethodPushChannel] is `mixtape/push` (PushChannel.swift).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';

/// The OS notification permission, as `mixtape/push` reports it.
/// Provisional and ephemeral count as [authorized].
enum PushStatus {
  notDetermined,
  authorized,
  denied;

  /// Anything this build does not know reads as [denied]: never ask, never
  /// register.
  static PushStatus parse(Object? name) => switch (name) {
    'notDetermined' => notDetermined,
    'authorized' => authorized,
    _ => denied,
  };
}

/// A tapped push: which mix, which turn, and whether it landed.
@immutable
class PushTap {
  const PushTap({
    required this.sessionId,
    required this.turnId,
    required this.kind,
  });

  final String sessionId;
  final String turnId;

  /// `ready` or `failed`.
  final String kind;

  /// The turn did not land: the mix opens with the listener's words back in
  /// the composer.
  bool get failed => kind == 'failed';

  /// The payload's own keys (`sessionId`, `turnId`, `kind`); null when it is
  /// not one of ours.
  static PushTap? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final sessionId = raw['sessionId'];
    if (sessionId is! String || sessionId.isEmpty) return null;
    final turnId = raw['turnId'];
    final kind = raw['kind'];
    return PushTap(
      sessionId: sessionId,
      turnId: turnId is String ? turnId : '',
      kind: kind is String ? kind : 'ready',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PushTap &&
      other.sessionId == sessionId &&
      other.turnId == turnId &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(sessionId, turnId, kind);
}

/// `mixtape/push`, so tests can stand in for the platform.
abstract class PushChannel {
  Future<PushStatus> status();

  /// The system prompt (alert, sound, badge); the status it leaves.
  Future<PushStatus> requestAuthorization();

  /// Registers with APNs; the device token as lowercase hex. Throws when iOS
  /// refuses.
  Future<String> register();

  /// "1.2.0 (15)": the build that registered, for the device row.
  Future<String?> appVersion();

  /// The APNs a token from this build belongs to, `sandbox` or
  /// `production`, as the signing profile says; null when unknown.
  Future<String?> environment();

  /// The mix the listener is looking at (null for none): a push for it is
  /// not shown while the app is in the foreground.
  Future<void> setVisibleSession(String? sessionId);

  /// The tap that launched the app, handed over once.
  Future<PushTap?> initialTap();

  /// Taps while the app is running.
  Stream<PushTap> get taps;
}

/// Off iOS, and in tests: never allowed, nothing to register.
class NoPushChannel implements PushChannel {
  const NoPushChannel();

  @override
  Future<PushStatus> status() async => PushStatus.denied;

  @override
  Future<PushStatus> requestAuthorization() async => PushStatus.denied;

  @override
  Future<String> register() async =>
      throw UnsupportedError('no push on this platform');

  @override
  Future<String?> appVersion() async => null;

  @override
  Future<String?> environment() async => null;

  @override
  Future<void> setVisibleSession(String? sessionId) async {}

  @override
  Future<PushTap?> initialTap() async => null;

  @override
  Stream<PushTap> get taps => const Stream.empty();
}

/// [PushChannel] over the platform channel. One per app: a channel has one
/// handler.
class MethodPushChannel implements PushChannel {
  MethodPushChannel._();

  static final MethodPushChannel instance = MethodPushChannel._();

  static const String channelName = 'mixtape/push';
  static const MethodChannel _channel = MethodChannel(channelName);

  final StreamController<PushTap> _taps = StreamController.broadcast();
  bool _handling = false;

  /// Installed lazily, at the first use, so nothing touches the binding at
  /// import.
  void _handle() {
    if (_handling) return;
    _handling = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onTap') throw MissingPluginException();
      final tap = PushTap.fromMap(call.arguments);
      // True only once someone holds it: otherwise native keeps it for
      // [initialTap].
      if (tap == null || !_taps.hasListener) return false;
      _taps.add(tap);
      return true;
    });
  }

  @override
  Future<PushStatus> status() async =>
      PushStatus.parse(await _channel.invokeMethod<String>('status'));

  @override
  Future<PushStatus> requestAuthorization() async => PushStatus.parse(
    await _channel.invokeMethod<String>('requestAuthorization'),
  );

  @override
  Future<String> register() async {
    final token = await _channel.invokeMethod<String>('register');
    if (token == null || token.isEmpty) {
      throw PlatformException(code: 'register_failed');
    }
    return token;
  }

  @override
  Future<String?> appVersion() => _channel.invokeMethod<String>('appVersion');

  @override
  Future<String?> environment() => _channel.invokeMethod<String>('environment');

  @override
  Future<void> setVisibleSession(String? sessionId) async {
    try {
      await _channel.invokeMethod<void>('setVisibleSession', {
        'sessionId': sessionId,
      });
    } catch (_) {}
  }

  @override
  Future<PushTap?> initialTap() async {
    _handle();
    return PushTap.fromMap(await _channel.invokeMethod<Object?>('initialTap'));
  }

  @override
  Stream<PushTap> get taps {
    _handle();
    return _taps.stream;
  }
}

/// The device's push registration for whoever is signed in. Never fails
/// anything: a registration that does not go through is tried again at the
/// next launch, and the listener is never told.
class PushService {
  PushService({
    required PushChannel channel,
    required ApiClient api,
    String? environment,
  }) : _channel = channel,
       _api = api,
       _environment = environment;

  /// Which APNs a token from this build belongs to when the platform cannot
  /// say: a debug or profile build is signed `aps-environment: development`
  /// (Runner.entitlements), a release one `production`
  /// (RunnerRelease.entitlements). The platform's answer wins, since it reads
  /// the signing profile (`flutter run --release` is development-signed).
  static String get buildEnvironment => kReleaseMode ? 'production' : 'sandbox';

  final PushChannel _channel;
  final ApiClient _api;

  /// Set only by tests; otherwise asked of the platform.
  final String? _environment;

  /// The token the server holds for this session, once a PUT went through.
  String? _token;
  Future<void>? _registering;
  bool _disposed = false;

  /// Sign-out has begun: nothing more is sent for this session.
  bool _leaving = false;

  Future<PushStatus> status() async {
    try {
      return await _channel.status();
    } catch (_) {
      return PushStatus.denied;
    }
  }

  /// At launch and at every sign-in: registers only when the listener has
  /// already said yes. Never asks.
  Future<void> registerIfAuthorized() async {
    if (await status() != PushStatus.authorized) return;
    await _register();
  }

  /// The permission pop-up's yes: shows the system prompt if iOS has not
  /// asked yet, and registers on a yes. A listener who said no is never
  /// asked again (the status comes back as it is).
  Future<PushStatus> requestAndRegister() async {
    var current = await status();
    if (current == PushStatus.notDetermined) {
      try {
        current = await _channel.requestAuthorization();
      } catch (_) {
        current = PushStatus.denied;
      }
    }
    if (current == PushStatus.authorized) await _register();
    return current;
  }

  /// At sign-out, before the bearer goes: the device stops receiving this
  /// listener's mixes. A registration still in flight lands first, so the
  /// DELETE is the last word.
  Future<void> unregister() {
    _leaving = true;
    return _delete();
  }

  /// You → "Mix ready notifications" off: the server forgets this phone,
  /// and iOS's own setting is untouched. Unlike [unregister] the session
  /// goes on, so turning it back on ([requestAndRegister]) registers again.
  Future<void> turnOff() => _delete();

  Future<void> _delete() async {
    try {
      await _registering;
      var token = _token;
      if (token == null) {
        // Not registered this launch (offline, say), but the server may
        // still hold this phone from an earlier one.
        if (await status() != PushStatus.authorized) return;
        token = await _channel.register();
      }
      _token = null;
      await _api.deleteJson('/push/devices/${Uri.encodeComponent(token)}');
    } catch (_) {}
  }

  /// The tap that launched the app, once.
  Future<PushTap?> initialTap() async {
    try {
      return await _channel.initialTap();
    } catch (_) {
      return null;
    }
  }

  Stream<PushTap> get taps => _channel.taps;

  void dispose() => _disposed = true;

  Future<void> _register() =>
      _registering ??= _send().whenComplete(() => _registering = null);

  Future<void> _send() async {
    try {
      final token = await _channel.register();
      String? version;
      try {
        version = await _channel.appVersion();
      } catch (_) {}
      var environment = _environment;
      if (environment == null) {
        try {
          environment = await _channel.environment();
        } catch (_) {}
      }
      if (environment != 'sandbox' && environment != 'production') {
        environment = buildEnvironment;
      }
      if (_disposed || _leaving) return;
      await _api.putJson('/push/devices', {
        'provider': 'apns',
        'platform': 'ios',
        'token': token,
        'environment': environment,
        'appVersion': ?version,
      });
      _token = token;
    } catch (_) {}
  }
}
