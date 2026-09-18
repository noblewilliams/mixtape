import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/playlists/playlist_api.dart';
import 'package:mixtape/data/playlists/playlist_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/playlist_providers.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/playlist_inspiration.dart';
import '../../helpers/auth_ui_snapshot.dart';

class _SignedIn extends AuthNotifier {
  @override
  AuthStatus build() => AuthStatus.signedIn;
}

class _Browse implements PlaylistApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  Future<PlaylistPage> list({
    PlaylistStatus status = PlaylistStatus.active,
    String? query,
    int limit = 30,
    String? cursor,
  }) async => const PlaylistPage(
    playlists: [
      PlaylistSummary(
        id: 'apple-id',
        name: 'Night Bus Notes',
        source: 'apple',
        kind: 'user',
        entryCount: 12,
        inLibrary: true,
        capability: 'copy_only',
      ),
      PlaylistSummary(
        id: 'spotify-id',
        name: 'Night Bus Notes',
        source: 'spotify_export',
        kind: 'user',
        entryCount: 20,
        inLibrary: true,
        capability: 'copy_only',
      ),
    ],
  );
}

const Key _composerField = Key('host-composer');

/// The picker is a sheet now, so what geometry has to protect is no longer a
/// floating panel's position: the sheet must stay on screen and keep its own
/// controls above the keyboard, and the composer it was opened from must be
/// reachable again the moment it closes.
void main() {
  for (final brightness in Brightness.values) {
    for (final large in [false, true]) {
      for (final keyboardInitiallyOpen in [true, false]) {
        testWidgets(
          'picker sheet clears the keyboard ${brightness.name} ${large ? '320 large text' : '390'} with keyboard ${keyboardInitiallyOpen ? 'already open' : 'opened later'}',
          (tester) async {
            final size = large ? const Size(320, 568) : const Size(390, 844);
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            tester.view.viewInsets = FakeViewPadding(
              bottom: keyboardInitiallyOpen ? 260 : 0,
            );
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            addTearDown(tester.view.resetViewInsets);
            await loadAuthSnapshotFonts(tester);
            PlaylistInspirationChoice? choice;
            await tester.pumpWidget(
              ProviderScope(
                overrides: [
                  authProvider.overrideWith(_SignedIn.new),
                  playlistApiProvider.overrideWithValue(_Browse()),
                ],
                child: RepaintBoundary(
                  key: authSnapshotKey,
                  child: MaterialApp(
                    debugShowCheckedModeBanner: false,
                    theme: brightness == Brightness.dark
                        ? MixtapeTheme.dark()
                        : MixtapeTheme.light(),
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(
                        context,
                      ).copyWith(textScaler: TextScaler.linear(large ? 2 : 1)),
                      child: child!,
                    ),
                    home: Consumer(
                      builder: (context, ref, _) => Scaffold(
                        appBar: AppBar(title: const Text('Night Bus Notes')),
                        body: Column(
                          children: [
                            const Expanded(child: SizedBox()),
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const TextField(
                                    key: _composerField,
                                    decoration: InputDecoration(
                                      hintText: 'A softer ending',
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        showPlaylistInspirationPicker(
                                          context,
                                          ref,
                                        ).then((value) => choice = value),
                                    child: const Text('Playlist'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tester.tap(find.text('Playlist'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            if (!keyboardInitiallyOpen) {
              tester.view.viewInsets = const FakeViewPadding(bottom: 260);
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
            }

            final sheet = tester.getRect(find.byKey(PlaylistPicker.sheetKey));
            expect(sheet.top, greaterThanOrEqualTo(0));
            expect(sheet.left, greaterThanOrEqualTo(0));
            expect(sheet.right, lessThanOrEqualTo(size.width));
            expect(
              sheet.bottom,
              lessThanOrEqualTo(size.height - 260 + 0.5),
              reason: 'The sheet must sit above the keyboard.',
            );
            // Its own controls come with it: search at the top of the sheet,
            // the exclude toggle at its foot, both still on screen.
            final search = tester.getRect(find.byKey(PlaylistPicker.searchKey));
            expect(search.bottom, lessThanOrEqualTo(sheet.bottom));
            final exclude = tester.getRect(
              find.byKey(PlaylistPicker.excludeKey),
            );
            expect(exclude.bottom, lessThanOrEqualTo(sheet.bottom + 0.5));
            expect(exclude.top, greaterThanOrEqualTo(sheet.top - 0.5));
            await captureAuthSnapshot(
              tester,
              'native-picker-${brightness.name}-${large ? 'large' : 'normal'}-${keyboardInitiallyOpen ? 'open' : 'later'}',
            );

            final option = find.byKey(PlaylistPicker.rowKey('spotify-id'));
            await tester.scrollUntilVisible(
              option,
              80,
              scrollable: find.descendant(
                of: find.byKey(PlaylistPicker.listKey),
                matching: find.byType(Scrollable),
              ),
            );
            await tester.pumpAndSettle();
            // Whatever is left of the row inside the list's viewport is
            // enough to choose it.
            final visible = tester
                .getRect(option)
                .intersect(tester.getRect(find.byKey(PlaylistPicker.listKey)));
            expect(visible.height, greaterThan(0));
            await tester.tapAt(visible.center);
            await tester.pumpAndSettle();
            expect(choice?.seed.playlistId, 'spotify-id');

            // The composer the picker was opened from is back, above the
            // keyboard, and takes a tap.
            final composer = tester.getRect(find.byKey(_composerField));
            expect(composer.bottom, lessThanOrEqualTo(size.height - 260));
            await tester.tap(find.byKey(_composerField));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
