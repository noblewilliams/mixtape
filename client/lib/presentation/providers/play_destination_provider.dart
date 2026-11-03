import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/settings/play_destination_store.dart';

export '../../data/settings/play_destination_store.dart';

/// The keychain-backed store; tests override it with the in-memory one.
final playDestinationStoreProvider = Provider<PlayDestinationStore>(
  (ref) => SecurePlayDestinationStore(),
);

/// The Play button's remembered destination. Starts on the app's own player
/// and adopts the stored choice once it is read; a store that cannot be read
/// simply leaves the default.
class PlayDestinationNotifier extends Notifier<PlayDestination> {
  bool _chosen = false;

  @override
  PlayDestination build() {
    _chosen = false;
    unawaited(_load());
    return PlayDestination.here;
  }

  Future<void> _load() async {
    final store = ref.read(playDestinationStoreProvider);
    try {
      final stored = await store.read();
      // A choice made while the read was in flight wins over the old value.
      if (!ref.mounted || _chosen || stored == null) return;
      state = stored;
    } catch (_) {
      // A device that cannot remember plays here.
    }
  }

  /// Makes [destination] the default, here and on the device.
  Future<void> choose(PlayDestination destination) async {
    _chosen = true;
    state = destination;
    try {
      await ref.read(playDestinationStoreProvider).write(destination);
    } catch (_) {
      // Remembering is a nicety; this session still uses the choice.
    }
  }
}

final playDestinationProvider =
    NotifierProvider<PlayDestinationNotifier, PlayDestination>(
      PlayDestinationNotifier.new,
    );
