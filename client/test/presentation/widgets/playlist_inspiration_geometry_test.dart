import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/playlists/playlist_api.dart';
import 'package:mixtape/data/playlists/playlist_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/playlist_providers.dart';
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

void main() {
  for (final brightness in Brightness.values) {
    for (final large in [false, true]) {
      for (final keyboardInitiallyOpen in [true, false]) {
        testWidgets(
          'picker protects composer ${brightness.name} ${large ? '320 large text' : '390'} with keyboard ${keyboardInitiallyOpen ? 'already open' : 'opened later'}',
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
            final composer = GlobalKey();
            Rect? protected;
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
                    theme: authSnapshotTheme(brightness),
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
                              key: composer,
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const TextField(
                                    decoration: InputDecoration(
                                      hintText: 'A softer ending',
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () {
                                      final box =
                                          composer.currentContext!
                                                  .findRenderObject()!
                                              as RenderBox;
                                      protected =
                                          box.localToGlobal(Offset.zero) &
                                          box.size;
                                      showPlaylistInspirationPicker(
                                        context,
                                        ref,
                                        anchor: protected,
                                        anchorResolver: () {
                                          final current =
                                              composer.currentContext!
                                                      .findRenderObject()!
                                                  as RenderBox;
                                          return current.localToGlobal(
                                                Offset.zero,
                                              ) &
                                              current.size;
                                        },
                                      ).then((value) => choice = value);
                                    },
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
              final box =
                  composer.currentContext!.findRenderObject()! as RenderBox;
              protected = box.localToGlobal(Offset.zero) & box.size;
              expect(tester.takeException(), isNull);
            }
            final panel = find
                .descendant(
                  of: find.byType(Dialog),
                  matching: find.byType(Material),
                )
                .first;
            final bounds = tester.getRect(panel);
            expect(
              bounds.bottom,
              lessThanOrEqualTo(protected!.top),
              reason:
                  'The floating panel must not cover the protected composer.',
            );
            expect(bounds.top, greaterThanOrEqualTo(0));
            expect(bounds.left, greaterThanOrEqualTo(0));
            expect(bounds.right, lessThanOrEqualTo(size.width));
            expect(bounds.bottom, lessThanOrEqualTo(size.height - 260));
            await captureAuthSnapshot(
              tester,
              'native-picker-${brightness.name}-${large ? 'large' : 'normal'}-${keyboardInitiallyOpen ? 'open' : 'later'}',
            );
            final option = find.byKey(const Key('playlist-choice-spotify-id'));
            final scrollable = find
                .descendant(
                  of: find.byType(Dialog),
                  matching: find.byType(Scrollable),
                )
                .first;
            await tester.scrollUntilVisible(option, 80, scrollable: scrollable);
            await tester.pumpAndSettle();
            final visible = tester.getRect(option).intersect(bounds);
            expect(visible.height, greaterThan(0));
            await tester.tapAt(visible.center);
            await tester.pumpAndSettle();
            expect(choice?.seed.playlistId, 'spotify-id');
          },
        );
      }
    }
  }
}
