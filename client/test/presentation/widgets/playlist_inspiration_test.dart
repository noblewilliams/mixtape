import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/playlists/playlist_api.dart';
import 'package:mixtape/data/playlists/playlist_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/playlist_providers.dart';
import 'package:mixtape/presentation/widgets/playlist_inspiration.dart';

class SignedIn extends AuthNotifier {
  @override
  AuthStatus build() => AuthStatus.signedIn;
}

PlaylistSummary playlist(String id, String source) => PlaylistSummary(
  id: id,
  name: 'Night Bus Notes',
  source: source,
  kind: 'user',
  entryCount: 12,
  inLibrary: true,
  capability: 'copy_only',
);

class BrowseApi implements PlaylistApi {
  final queries = <String?>[];
  @override
  Future<PlaylistPage> list({
    PlaylistStatus status = PlaylistStatus.active,
    String? query,
    int limit = 30,
    String? cursor,
  }) async {
    queries.add(query);
    return PlaylistPage(
      playlists: [
        playlist(
          cursor == null ? 'apple-id' : 'spotify-id',
          cursor == null ? 'apple' : 'spotify_export',
        ),
      ],
      nextCursor: cursor == null ? 'next' : null,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'picker pages duplicate names by exact ID and preserves exclusion choice',
    (tester) async {
      final api = BrowseApi();
      PlaylistInspirationChoice? choice;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith(SignedIn.new),
            playlistApiProvider.overrideWithValue(api),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    choice = await showPlaylistInspirationPicker(context, ref);
                  },
                  child: const Text('Pick'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Pick'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use different songs'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Load more'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('playlist-choice-spotify-id')));
      await tester.pumpAndSettle();
      expect(choice!.seed.playlistId, 'spotify-id');
      expect(choice!.seed.excludeSourceTracks, true);
    },
  );
  testWidgets('outside dismiss returns cancel and search only reads', (
    tester,
  ) async {
    final api = BrowseApi();
    var completed = false;
    PlaylistInspirationChoice? choice;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(SignedIn.new),
          playlistApiProvider.overrideWithValue(api),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  choice = await showPlaylistInspirationPicker(context, ref);
                  completed = true;
                },
                child: const Text('Pick'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Pick'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('playlist-search')), 'Night');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(api.queries.last, 'Night');
    await tester.tapAt(const Offset(790, 590));
    await tester.pumpAndSettle();
    expect(completed, true);
    expect(choice, isNull);
  });
  testWidgets('picker fits narrow large text with keyboard visible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(SignedIn.new),
          playlistApiProvider.overrideWithValue(BrowseApi()),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(2),
              viewInsets: const EdgeInsets.only(bottom: 250),
            ),
            child: child!,
          ),
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: TextButton(
                onPressed: () => showPlaylistInspirationPicker(
                  context,
                  ref,
                  anchor: const Rect.fromLTWH(16, 540, 100, 48),
                ),
                child: const Text('Pick'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Pick'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final picker = tester.getRect(find.byType(Dialog));
    expect(picker.right, lessThanOrEqualTo(320));
    expect(find.byKey(const Key('playlist-search')), findsOneWidget);
  });
  testWidgets('unknown attachment disables writes but keeps reload available', (
    tester,
  ) async {
    var picks = 0;
    var reloads = 0;
    var detaches = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaylistInspirationAttachment(
            name: 'Night Bus Notes',
            disabled: true,
            onPick: () => picks++,
            onDetach: () => detaches++,
            onReload: () => reloads++,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Inspired by Night Bus Notes'));
    await tester.tap(find.byTooltip('Detach playlist inspiration'));
    await tester.tap(find.text('Reload inspiration'));
    expect(picks, 0);
    expect(detaches, 0);
    expect(reloads, 1);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
