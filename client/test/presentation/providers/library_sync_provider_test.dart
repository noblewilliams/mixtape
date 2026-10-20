import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/library/library_sync_service.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';

import '../../helpers/fake_bridge.dart';
import '../../helpers/fake_listening_api.dart';
import '../../helpers/onboarding_harness.dart';

void main() {
  test('SyncRunning carries the song count across progress updates', () async {
    final service = LibrarySyncService(
      bridge: FakeBridge(List.generate(5, song)),
      api: await apiWith(
        MockClient(
          (req) async => req.url.path == '/ingest/library'
              ? http.Response('{"ingested": 0}', 200)
              : emptyPlaylistSyncResponse(req),
        ),
      ),
      chunkSize: 2,
    );
    final container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.session)),
        librarySyncServiceProvider.overrideWithValue(service),
        listeningApiProvider.overrideWithValue(FakeListeningApi()),
      ],
    );
    addTearDown(container.dispose);

    final running = <SyncRunning>[];
    container.listen<SyncState>(librarySyncProvider, (_, next) {
      if (next is SyncRunning) running.add(next);
    }, fireImmediately: true);

    await container.read(librarySyncProvider.notifier).sync();

    expect(container.read(librarySyncProvider), isA<SyncDone>());
    // Every page reports its songs, then its progress; the progress state
    // keeps the count rather than resetting it to 0.
    final afterFirstPage = running.where((s) => s.progress > 0).toList();
    expect(afterFirstPage, isNotEmpty);
    expect(afterFirstPage.first.songs, 2);
    expect(afterFirstPage.map((s) => s.songs), containsAllInOrder([2, 4, 5]));
    // Never goes back once a page has landed.
    for (var i = 1; i < afterFirstPage.length; i++) {
      expect(
        afterFirstPage[i].songs,
        greaterThanOrEqualTo(afterFirstPage[i - 1].songs),
      );
    }
    // The playlist stage, after the songs, still says 5.
    expect(afterFirstPage.last.songs, 5);
  });
}
