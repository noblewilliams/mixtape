import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/playback/playback_api.dart';
import '../../data/playback/player_bridge.dart';
import '../../data/playback/playback_controller.dart';
import 'auth_provider.dart';

final appPlayerBridgeProvider = Provider((ref) => AppPlayerBridge());
final playbackProvider = Provider<PlaybackController>((ref) {
  ref.watch(authProvider);
  final controller = PlaybackController(
    PlaybackApi(ref.watch(apiClientProvider)),
    ref.watch(appPlayerBridgeProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});
