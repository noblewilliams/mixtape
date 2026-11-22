import 'dart:async';

import 'package:mixtape/data/push/push_service.dart';

/// `mixtape/push` as the test says it is: the OS permission, the device
/// token, and taps the test sends as if the listener had tapped a push.
class FakePushChannel implements PushChannel {
  FakePushChannel({
    this.current = PushStatus.authorized,
    this.afterRequest = PushStatus.authorized,
    this.token =
        'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90',
    this.version = '1.2.0 (15)',
    this.launchTap,
  });

  PushStatus current;

  /// What the system prompt answers.
  PushStatus afterRequest;
  String token;
  String version;

  /// The tap that launched the app, handed over once.
  PushTap? launchTap;

  /// Thrown by [register] instead of answering.
  Object? registerError;

  /// Every call, in order.
  final List<String> calls = [];

  /// What [setVisibleSession] was told, in order.
  final List<String?> visible = [];

  final StreamController<PushTap> _taps = StreamController.broadcast();

  void tap(PushTap tap) => _taps.add(tap);

  @override
  Stream<PushTap> get taps => _taps.stream;

  @override
  Future<PushStatus> status() async {
    calls.add('status');
    return current;
  }

  @override
  Future<PushStatus> requestAuthorization() async {
    calls.add('requestAuthorization');
    current = afterRequest;
    return current;
  }

  @override
  Future<String> register() async {
    calls.add('register');
    final error = registerError;
    if (error != null) throw error;
    return token;
  }

  @override
  Future<String?> appVersion() async => version;

  /// What the signing profile says; null for unknown.
  String? apsEnvironment;

  @override
  Future<String?> environment() async => apsEnvironment;

  @override
  Future<void> setVisibleSession(String? sessionId) async {
    visible.add(sessionId);
  }

  @override
  Future<PushTap?> initialTap() async {
    final tap = launchTap;
    launchTap = null;
    return tap;
  }
}
