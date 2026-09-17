import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/playlists/playlist_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/new_mix_inspiration_provider.dart';
import 'package:mixtape/presentation/providers/playlist_context_provider.dart';
import 'package:mixtape/presentation/providers/playlist_providers.dart';
import 'package:mixtape/presentation/providers/shell_providers.dart';
import 'package:mixtape/presentation/screens/playlist_detail_screen.dart';
import '../presentation/providers/playlist_taste_provider_test.dart'
    show TestAuth, ReadApi, WriteApi, summary;

void main() {
  testWidgets(
    'inspiration passes exact playlist without confirming; taste requires modal',
    (tester) async {
      final reads = ReadApi();
      final writes = WriteApi();
      var current = summary();
      reads.read = () async => PlaylistDetail(
        playlist: current,
        entries: const [],
        nextEntryCursor: 'keep-page',
      );
      writes.write = (_) async {
        current = summary(origin: 'user_confirmed');
      };
      PlaylistSummary? inspired;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith(TestAuth.new),
            playlistApiProvider.overrideWithValue(reads),
            playlistContextApiProvider.overrideWithValue(writes),
          ],
          child: MaterialApp(
            home: PlaylistDetailScreen(
              playlistId: 'p',
              onInspire: (playlist) => inspired = playlist,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Make a mix inspired by this'));
      expect(inspired!.id, 'p');
      expect(writes.writes, 0);
      await tester.tap(find.text('I chose these songs'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(writes.writes, 0);
      await tester.tap(find.text('I chose these songs'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(writes.writes, 1);
      expect(find.text('Remove confirmation'), findsOneWidget);
    },
  );
  testWidgets(
    'browse inspiration returns to existing root with local draft attached, '
    'and switches the shell to the Home tab that holds the composer',
    (tester) async {
      final reads = ReadApi();
      final writes = WriteApi();
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith(TestAuth.new),
            playlistApiProvider.overrideWithValue(reads),
            playlistContextApiProvider.overrideWithValue(writes),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                container = ProviderScope.containerOf(context);
                return Scaffold(
                  body: Column(
                    children: [
                      Text(
                        ref.watch(newMixInspirationProvider)?.playlist.id ??
                            'No attachment',
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                const PlaylistDetailScreen(playlistId: 'p'),
                          ),
                        ),
                        child: const Text('Browse'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );
      container.read(selectedTabProvider.notifier).selectTab(AppTab.library);
      await tester.tap(find.text('Browse'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Make a mix inspired by this'));
      await tester.pumpAndSettle();
      expect(find.byType(PlaylistDetailScreen), findsNothing);
      expect(find.text('p'), findsOneWidget);
      expect(find.byType(Scaffold), findsOneWidget);
      expect(writes.writes, 0);
      // The composer that takes the attachment is Home's.
      expect(container.read(selectedTabProvider), AppTab.home.index);
    },
  );
}
