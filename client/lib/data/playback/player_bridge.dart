import 'package:flutter/services.dart';
import 'listening_meter.dart';

class AppPlayerBridge {
  Future<bool> authorize() async =>
      await _channel.invokeMethod<bool>('authorize') ?? false;
  static const _channel = MethodChannel('mixtape/player');
  Stream<PlayerSample> get samples => const EventChannel(
    'mixtape/player-events',
  ).receiveBroadcastStream().map((e) => PlayerSample.fromMap(e as Map));
  Future<void> start(List<String> ids) =>
      _channel.invokeMethod('start', {'appleIds': ids});
  Future<void> command(String action, {double? seconds}) => _channel
      .invokeMethod(action, seconds == null ? null : {'seconds': seconds});
}
