import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/playlists/playlist_context_models.dart';
import 'package:mixtape/data/playlists/playlist_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/new_mix_inspiration_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';
import 'package:mixtape/presentation/providers/playlist_context_provider.dart';
import 'package:mixtape/presentation/providers/playlist_providers.dart';
import 'package:mixtape/presentation/screens/home_screen.dart';
import 'package:mixtape/presentation/screens/playlist_detail_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import '../helpers/auth_ui_snapshot.dart';
import '../helpers/fake_listening_api.dart';
import '../presentation/providers/playlist_context_provider_test.dart'
    show FakeContextApi, TestAuth;
import '../presentation/providers/playlist_taste_provider_test.dart'
    show ReadApi, WriteApi;
import 'home_screen_test.dart' show FakeDjApi;

const chosen = PlaylistSummary(
  id: 'exact-playlist',
  name: 'Night Bus Notes',
  source: 'apple',
  kind: 'user',
  entryCount: 12,
  inLibrary: true,
  capability: 'copy_only',
);

class RecordingDj extends FakeDjApi {
  int creates = 0;
  String? prompt;
  InitialPlaylistSeed? seed;
  @override
  Future<SessionDetail> createSession(
    String prompt, {
    InitialPlaylistSeed? playlistSeed,
  }) async {
    creates++;
    this.prompt = prompt;
    seed = playlistSeed;
    throw ApiException(503, '');
  }
}

class BrowseApi extends ReadApi {
  @override
  Future<PlaylistPage> list({
    PlaylistStatus status = PlaylistStatus.active,
    String? query,
    int limit = 30,
    String? cursor,
  }) async => const PlaylistPage(playlists: [chosen]);
}

ProviderContainer makeContainer(RecordingDj dj) {
  final playlists = BrowseApi()
    ..read = () async => const PlaylistDetail(playlist: chosen, entries: []);
  return ProviderContainer(
    overrides: [
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      authProvider.overrideWith(TestAuth.new),
      djApiProvider.overrideWithValue(dj),
      listeningApiProvider.overrideWithValue(FakeListeningApi()),
      playlistApiProvider.overrideWithValue(playlists),
      playlistContextApiProvider.overrideWithValue(FakeContextApi()),
    ],
  );
}

/// The snapshot theme (seeded colours, the synthetic font) plus the design
/// tokens every native widget reads off the ambient theme.
ThemeData nativeSnapshotTheme(Brightness brightness) =>
    authSnapshotTheme(brightness).copyWith(
      extensions: [
        brightness == Brightness.dark
            ? MixtapeTokens.dark
            : MixtapeTokens.light,
      ],
    );

void main() {
  testWidgets(
    'browse handoff keeps Home draft, sends exact selection only on submit, and retains failure',
    (tester) async {
      final dj = RecordingDj()..onListSessions = () async => [];
      final container = makeContainer(dj);
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: MixtapeTheme.light(),
            home: const HomeScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('prompt-field')),
        '  A softer night drive  ',
      );
      Navigator.of(tester.element(find.byType(HomeScreen))).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              const PlaylistDetailScreen(playlistId: 'exact-playlist'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Make a mix inspired by this'));
      await tester.pumpAndSettle();
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('prompt-field')))
            .controller!
            .text,
        '  A softer night drive  ',
      );
      expect(find.text('Inspired by Night Bus Notes'), findsOneWidget);
      expect(dj.creates, 0);
      await tester.tap(find.text('Inspired by Night Bus Notes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use different songs'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('playlist-choice-exact-playlist')));
      await tester.pumpAndSettle();
      expect(dj.creates, 0);
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();
      expect(dj.creates, 1);
      expect(dj.prompt, 'A softer night drive');
      expect(dj.seed!.playlistId, 'exact-playlist');
      expect(dj.seed!.excludeSourceTracks, true);
      expect(find.text('Inspired by Night Bus Notes'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('prompt-field')))
            .controller!
            .text,
        '  A softer night drive  ',
      );
      await tester.tap(find.byTooltip('Detach playlist inspiration'));
      await tester.pumpAndSettle();
      expect(container.read(newMixInspirationProvider), isNull);
      expect(dj.creates, 1);
      expect(find.text('+ Playlist'), findsNothing);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets('captures attached Home and taste detail ${brightness.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await loadAuthSnapshotFonts(tester);
      if (const String.fromEnvironment('AUTH_UI_SNAPSHOT_DIR').isNotEmpty) {
        final titleFont = File('/System/Library/Fonts/Noteworthy.ttc');
        if (titleFont.existsSync()) {
          final loader = FontLoader('Noteworthy')
            ..addFont(
              Future.value(ByteData.sublistView(titleFont.readAsBytesSync())),
            );
          await tester.runAsync(loader.load);
        }
      }
      final dj = RecordingDj()
        ..onListSessions = () async => [
          DjSession(
            id: 'night',
            title: 'Night Bus Notes',
            status: 'active',
            queueVersion: 1,
            updatedAt: DateTime.now().subtract(const Duration(hours: 2)),
          ),
        ];
      final playlists = BrowseApi()
        ..read = () async =>
            const PlaylistDetail(playlist: chosen, entries: []);
      final container = ProviderContainer(
        overrides: [
          tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
          authProvider.overrideWith(TestAuth.new),
          djApiProvider.overrideWithValue(dj),
          listeningApiProvider.overrideWithValue(FakeListeningApi()),
          playlistApiProvider.overrideWithValue(playlists),
          playlistContextApiProvider.overrideWithValue(WriteApi()),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: RepaintBoundary(
            key: authSnapshotKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: nativeSnapshotTheme(brightness),
              home: const HomeScreen(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      container.read(newMixInspirationProvider.notifier).select(chosen);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('prompt-field')),
        'A softer night drive',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('prompt-field')))
            .controller!
            .text,
        'A softer night drive',
      );
      await captureAuthSnapshot(
        tester,
        'native-home-attached-${brightness.name}',
      );
      Navigator.of(tester.element(find.byType(HomeScreen))).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              const PlaylistDetailScreen(playlistId: 'exact-playlist'),
        ),
      );
      await tester.pumpAndSettle();
      await captureAuthSnapshot(
        tester,
        'native-playlist-detail-${brightness.name}',
      );
      await tester.tap(find.text('I chose these songs'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await captureAuthSnapshot(
        tester,
        'native-playlist-taste-${brightness.name}',
      );
    });
  }
}
