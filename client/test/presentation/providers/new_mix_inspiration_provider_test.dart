import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/playlists/playlist_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/new_mix_inspiration_provider.dart';
import 'playlist_context_provider_test.dart' show TestAuth;

void main() {
  test(
    'draft stores exact selection without requests and clears across auth',
    () async {
      final container = ProviderContainer(
        overrides: [authProvider.overrideWith(TestAuth.new)],
      );
      addTearDown(container.dispose);
      container.listen(newMixInspirationProvider, (_, _) {});
      final notifier = container.read(newMixInspirationProvider.notifier);
      const playlist = PlaylistSummary(
        id: 'exact',
        name: 'Night Bus Notes',
        kind: 'user',
        entryCount: 12,
        inLibrary: true,
        capability: 'copy_only',
      );
      notifier.select(playlist, excludeSourceTracks: true);
      expect(
        container.read(newMixInspirationProvider)!.seed.playlistId,
        'exact',
      );
      expect(
        container.read(newMixInspirationProvider)!.seed.excludeSourceTracks,
        true,
      );
      (container.read(authProvider.notifier) as TestAuth).set(
        AuthStatus.signedOut,
      );
      await container.pump();
      expect(container.read(newMixInspirationProvider), isNull);
      notifier.select(playlist);
      expect(container.read(newMixInspirationProvider), isNull);
    },
  );
}
