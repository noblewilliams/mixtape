import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/musickit/musickit_bridge.dart';
import 'package:mixtape/data/onboarding/funnel_once_store.dart';
import 'package:mixtape/data/onboarding/service_preference_store.dart';
import 'package:mixtape/data/playback/playback_controller.dart';
import 'package:mixtape/data/settings/author_store.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/device_providers.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/music_platform_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';
import 'package:mixtape/presentation/providers/pending_share_save_provider.dart';
import 'package:mixtape/presentation/providers/playback_provider.dart';
import 'package:mixtape/presentation/screens/chat_screen.dart';
import 'package:mixtape/presentation/screens/shared_mix_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/mix_handoff.dart';
import 'package:mixtape/presentation/widgets/spotify_handoff_sheets.dart';
import 'package:mixtape/presentation/widgets/tape_header.dart';
import 'package:mixtape/presentation/widgets/track_row.dart';

import '../data/playback/playback_controller_test.dart'
    as playback
    show FakeApi, FakeBridge;
import '../helpers/fake_clipboard_writer.dart';
import '../helpers/fake_listening_api.dart';
import '../helpers/onboarding_harness.dart' show FakeLinkOpener;

const _token = 'AbCdEfGhIjKlMnOpQrStUv';
const _keys = MixHandoffKeys.shared;

SharedMix _mix({
  String? sharerName = 'Ada',
  bool isOwner = false,
  String? sessionId,
}) => SharedMix(
  token: _token,
  title: 'Late drive, windows down',
  caseColor: '#bc5734',
  sharerName: sharerName,
  sharedAt: DateTime(2026, 11, 13),
  isOwner: isOwner,
  sessionId: sessionId,
  tracks: const [
    SharedMixTrack(
      title: 'Midnight City',
      artist: 'M83',
      durationMs: 240000,
      appleId: 'a1',
    ),
    SharedMixTrack(title: 'Nightcall', artist: 'Kavinsky', durationMs: 240000),
    SharedMixTrack(
      title: 'Electric Feel',
      artist: 'MGMT',
      durationMs: 120000,
      appleId: 'a3',
    ),
  ],
);

/// The share calls, plus a record of anything that would count as the
/// listener's evidence. Everything else fails loudly.
class _ShareApi implements DjApi, DjSharedMixes {
  Future<SharedMix> Function(String token) onGet = (_) async => _mix();
  final gets = <String>[];
  final saved = <String>[];
  final removed = <String>[];
  final events = <String>[];
  final receipts = <String>[];
  Object? removeError;

  @override
  Future<SharedMix> getSharedMix(String token) {
    gets.add(token);
    return onGet(token);
  }

  @override
  Future<void> saveSharedMix(String token) async => saved.add(token);

  @override
  Future<void> removeSharedMix(String token) async {
    removed.add(token);
    final error = removeError;
    if (error != null) throw error;
  }

  @override
  Future<void> postSessionEvent(String sessionId, String type) async =>
      events.add('$sessionId:$type');

  @override
  Future<void> recordPlaylistCreation(String sessionId, String id) async =>
      receipts.add(sessionId);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _MusicKit implements MusicKitBridge {
  final played = <List<String>>[];

  @override
  Future<bool> playQueue(List<String> appleIds) async {
    played.add(appleIds);
    return true;
  }

  @override
  Future<({int added, int failed})> createPlaylist(
    String name,
    List<String> appleIds, {
    String? author,
    String? description,
    void Function(String libraryId)? onCreated,
  }) async {
    onCreated?.call('lib1');
    return (added: appleIds.length, failed: 0);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _PlayerBridge extends playback.FakeBridge {
  final ids = <List<String>>[];

  @override
  Future<void> start(List<String> ids) {
    this.ids.add(ids);
    return super.start(ids);
  }
}

class _Auth extends AuthNotifier {
  _Auth(this._initial);
  final AuthStatus _initial;

  @override
  AuthStatus build() => _initial;

  void set(AuthStatus next) => state = next;
}

class _Harness {
  _Harness({
    MusicPlatform? platform = MusicPlatform.apple,
    AuthStatus auth = AuthStatus.session,
  }) {
    FlutterSecureStorage.setMockInitialValues({});
    player = PlaybackController(playbackApi, playerBridge);
    container = ProviderContainer(
      overrides: [
        djApiProvider.overrideWithValue(api),
        authProvider.overrideWith(() => _Auth(auth)),
        tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
        musicPlatformStoreProvider.overrideWithValue(
          InMemoryMusicPlatformStore(platform),
        ),
        musicKitBridgeProvider.overrideWithValue(musicKit),
        playbackProvider.overrideWithValue(player),
        authorStoreProvider.overrideWithValue(InMemoryAuthorStore()),
        accountNameProvider.overrideWith((ref) async => null),
        // No service on record unless the device knows the platform.
        listeningApiProvider.overrideWithValue(
          FakeListeningApi(
            onboarding: onboardingState(chosenService: platform?.name),
          ),
        ),
        servicePreferenceStoreProvider.overrideWithValue(
          InMemoryServicePreferenceStore(),
        ),
        funnelOnceStoreProvider.overrideWithValue(InMemoryFunnelOnceStore()),
        linkOpenerProvider.overrideWithValue(links.call),
        linkProbeProvider.overrideWithValue((_) async => false),
        clipboardWriterProvider.overrideWithValue(clipboard),
        pendingShareStoreProvider.overrideWithValue(pending),
      ],
    );
    addTearDown(container.dispose);
  }

  final api = _ShareApi();
  final musicKit = _MusicKit();
  final playbackApi = playback.FakeApi();
  final playerBridge = _PlayerBridge();
  final links = FakeLinkOpener();
  final clipboard = FakeClipboardWriter();
  final pending = InMemoryPendingShareStore();
  late final PlaybackController player;
  late final ProviderContainer container;

  Future<void> pump(
    WidgetTester tester, {
    bool fromMixes = false,
    bool settle = true,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: MixtapeTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  key: const Key('open'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          SharedMixScreen(token: _token, fromMixes: fromMixes),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
  }
}

void main() {
  testWidgets('loading holds Back and an inert bar until the mix arrives', (
    tester,
  ) async {
    final h = _Harness();
    final gate = Completer<SharedMix>();
    h.api.onGet = (_) => gate.future;
    await h.pump(tester, settle: false);
    expect(find.byKey(SharedMixScreen.loadingKey), findsOneWidget);
    expect(find.byKey(SharedMixScreen.backKey), findsOneWidget);
    // The bar is in place from the first frame, and inert.
    await tester.tap(find.byKey(_keys.playNow), warnIfMissed: false);
    await tester.pump();
    expect(h.playerBridge.ids, isEmpty);
    gate.complete(_mix());
    await tester.pumpAndSettle();
    expect(find.byKey(SharedMixScreen.loadingKey), findsNothing);
    expect(find.text('Late drive, windows down'), findsWidgets);
  });

  group('loaded, read-only', () {
    testWidgets('title, From Ada, the count and the songs; no editing', (
      tester,
    ) async {
      final h = _Harness();
      await h.pump(tester);
      expect(find.byKey(TapeHeader.titleKey), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(TapeHeader.bylineKey)).data,
        'From Ada',
      );
      expect(
        tester.widget<Text>(find.byKey(TapeHeader.metaKey)).data,
        '3 songs · 10 min',
      );
      expect(find.byType(TrackRow), findsNWidgets(3));
      expect(find.text('Midnight City'), findsOneWidget);
      // No composer, no swipe, no grips, no ⋯ menu.
      expect(find.byType(TextField), findsNothing);
      expect(find.byType(EditableText), findsNothing);
      expect(find.byType(Dismissible), findsNothing);
      expect(find.byKey(TrackRow.gripKey('$_token:0')), findsNothing);
      expect(find.byIcon(Icons.more_horiz), findsNothing);
      expect(find.byKey(SharedMixScreen.backKey), findsOneWidget);
    });

    testWidgets('a sender with no name reads From a friend', (tester) async {
      final h = _Harness();
      h.api.onGet = (_) async => _mix(sharerName: null);
      await h.pump(tester);
      expect(
        tester.widget<Text>(find.byKey(TapeHeader.bylineKey)).data,
        'From a friend',
      );
    });

    testWidgets('Apple Music: Play and Create playlist', (tester) async {
      final h = _Harness();
      await h.pump(tester);
      expect(find.byKey(_keys.playNow), findsOneWidget);
      expect(find.byKey(_keys.createPlaylist), findsOneWidget);
      expect(find.byKey(_keys.spotifyPlaylist), findsNothing);
    });

    testWidgets('Play plays the Apple ids in order and records nothing', (
      tester,
    ) async {
      final h = _Harness();
      await h.pump(tester);
      await tester.tap(find.byKey(_keys.playNow));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(h.playerBridge.ids, [
        ['a1', 'a3'],
      ]);
      expect(h.player.sessionId, 'shared:$_token');
      expect(h.player.caseColor, '#bc5734');
      expect(h.player.recording, isFalse);
      expect(h.api.events, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Play falling back to the Music app posts no event', (
      tester,
    ) async {
      final h = _Harness();
      h.playerBridge.failStart = true;
      await h.pump(tester);
      await tester.tap(find.byKey(_keys.playNow));
      await tester.pumpAndSettle();
      expect(h.musicKit.played, [
        ['a1', 'a3'],
      ]);
      expect(h.api.events, isEmpty);
      expect(h.player.sessionId, isNull);
    });

    testWidgets('Create playlist saves the Apple ids, with no receipt', (
      tester,
    ) async {
      final h = _Harness();
      await h.pump(tester);
      await tester.tap(find.byKey(_keys.createPlaylist));
      await tester.pumpAndSettle();
      expect(find.byKey(_keys.nameField), findsOneWidget);
      await tester.tap(find.byKey(_keys.saveConfirm));
      await tester.pumpAndSettle();
      expect(h.api.receipts, isEmpty);
      expect(h.api.events, isEmpty);
      expect(find.text(mixSaveSuccessMessage(2, 0)), findsOneWidget);
    });

    testWidgets('Spotify: one Create playlist with the mark', (tester) async {
      final h = _Harness(platform: MusicPlatform.spotify);
      await h.pump(tester);
      expect(find.byKey(_keys.playNow), findsNothing);
      expect(find.byKey(_keys.createPlaylist), findsNothing);
      expect(find.byKey(_keys.spotifyPlaylist), findsOneWidget);
      await tester.tap(find.byKey(_keys.spotifyPlaylist));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(SpotifyHandoffSheet.goKey));
      await tester.pumpAndSettle();
      expect(h.clipboard.copies.single, contains('M83 - Midnight City'));
      expect(h.links.opened, contains(mixTransferToolUrl));
      // Every row opens in Spotify.
      expect(find.byKey(TrackRow.spotifyKey('$_token:1')), findsOneWidget);
    });

    testWidgets('no platform yet: the Apple pair, and the first tap asks', (
      tester,
    ) async {
      final h = _Harness(platform: null);
      await h.pump(tester);
      expect(find.byKey(_keys.playNow), findsOneWidget);
      expect(find.byKey(_keys.createPlaylist), findsOneWidget);
      await tester.tap(find.byKey(_keys.playNow));
      await tester.pumpAndSettle();
      expect(find.text(WhereYouListenSheet.headline), findsOneWidget);
      expect(h.playerBridge.ids, isEmpty);
      await tester.tap(find.byKey(WhereYouListenSheet.appleKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(h.container.read(musicPlatformProvider), MusicPlatform.apple);
      expect(h.playerBridge.ids, [
        ['a1', 'a3'],
      ]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('no platform yet: answering Spotify swaps the bar', (
      tester,
    ) async {
      final h = _Harness(platform: null);
      await h.pump(tester);
      await tester.tap(find.byKey(_keys.createPlaylist));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(WhereYouListenSheet.spotifyKey));
      await tester.pumpAndSettle();
      expect(find.byKey(_keys.spotifyPlaylist), findsOneWidget);
      expect(find.byKey(_keys.playNow), findsNothing);
      expect(find.byKey(_keys.nameField), findsNothing);
    });
  });

  group('saving to Mixes', () {
    testWidgets('with a session it saves once', (tester) async {
      final h = _Harness();
      await h.pump(tester);
      expect(h.api.saved, [_token]);
      // A rebuild does not save again.
      h.container
          .read(musicPlatformProvider.notifier)
          .choose(MusicPlatform.spotify);
      await tester.pumpAndSettle();
      expect(h.api.saved, [_token]);
    });

    testWidgets('opened from Mixes it is already saved', (tester) async {
      final h = _Harness();
      await h.pump(tester, fromMixes: true);
      expect(h.api.saved, isEmpty);
    });

    testWidgets('with no session nothing is saved; the token waits', (
      tester,
    ) async {
      final h = _Harness(auth: AuthStatus.noSession);
      await h.pump(tester);
      expect(h.api.saved, isEmpty);
      expect((await h.pending.read())?.token, _token);
    });

    testWidgets('the waiting token saves once a session appears', (
      tester,
    ) async {
      final h = _Harness(auth: AuthStatus.noSession);
      // As the app's root does.
      h.container.listen(pendingShareSaveProvider, (_, _) {});
      await h.pump(tester);
      (h.container.read(authProvider.notifier) as _Auth).set(
        AuthStatus.session,
      );
      await tester.pumpAndSettle();
      expect(h.api.saved, [_token]);
      expect(await h.pending.read(), isNull);
    });

    testWidgets("the owner's own link opens their conversation, unsaved", (
      tester,
    ) async {
      final h = _Harness();
      h.api.onGet = (_) async => _mix(isOwner: true, sessionId: 's9');
      await h.pump(tester, settle: false);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(SharedMixScreen), findsNothing);
      final chat = tester.widget<ChatScreen>(find.byType(ChatScreen));
      expect(chat.sessionId, 's9');
      expect(h.api.saved, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('gone', () {
    testWidgets('an old link never saved: the line and Back only', (
      tester,
    ) async {
      final h = _Harness();
      h.api.onGet = (_) async =>
          throw const SharedMixGoneException(SharedMixGoneReason.notFound);
      await h.pump(tester);
      expect(find.text("This mix isn't shared anymore."), findsOneWidget);
      expect(find.byKey(SharedMixScreen.removeKey), findsNothing);
      expect(find.byKey(SharedMixScreen.backKey), findsOneWidget);
      expect(find.byKey(_keys.playNow), findsNothing);
      expect(h.api.saved, isEmpty);
    });

    testWidgets('a saved one offers Remove, which drops it and goes back', (
      tester,
    ) async {
      final h = _Harness();
      h.api.onGet = (_) async =>
          throw const SharedMixGoneException(SharedMixGoneReason.revoked);
      await h.pump(tester, fromMixes: true);
      await tester.tap(find.byKey(SharedMixScreen.removeKey));
      await tester.pumpAndSettle();
      expect(h.api.removed, [_token]);
      expect(find.byType(SharedMixScreen), findsNothing);
    });

    testWidgets('a Remove that fails stays and says so', (tester) async {
      final h = _Harness();
      h.api.onGet = (_) async =>
          throw const SharedMixGoneException(SharedMixGoneReason.revoked);
      h.api.removeError = Exception('offline');
      await h.pump(tester, fromMixes: true);
      await tester.tap(find.byKey(SharedMixScreen.removeKey));
      await tester.pumpAndSettle();
      expect(find.byType(SharedMixScreen), findsOneWidget);
      expect(find.text(SharedMixScreen.removeFailedMessage), findsOneWidget);
    });
  });

  testWidgets('a failed load offers Try again', (tester) async {
    final h = _Harness();
    var calls = 0;
    h.api.onGet = (_) async {
      calls++;
      if (calls == 1) throw Exception('offline');
      return _mix();
    };
    await h.pump(tester);
    expect(find.byKey(SharedMixScreen.retryKey), findsOneWidget);
    await tester.tap(find.byKey(SharedMixScreen.retryKey));
    await tester.pumpAndSettle();
    expect(find.byKey(TapeHeader.bylineKey), findsOneWidget);
    expect(h.api.saved, [_token]);
  });
}
