// The shared mix handoff (plan task 5.3): the copy the arrangement and the
// conversation both toast, the Apple/Spotify gating both rows obey, the save
// alert both open, and the share sheet's popover anchor. The two screen
// suites still cover how each screen wires these up; this covers the unit
// itself, so a copy change has exactly one place to break.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/musickit/musickit_bridge.dart';
import 'package:mixtape/data/playback/playback_controller.dart';
import 'package:mixtape/data/settings/author_store.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/playback_provider.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/label_chip.dart';
import 'package:mixtape/presentation/widgets/foundation/tape_button.dart';
import 'package:mixtape/presentation/widgets/foundation/text_action.dart';
import 'package:mixtape/presentation/widgets/mix_handoff.dart';

import '../../data/playback/playback_controller_test.dart' as playback
    show FakeApi, FakeBridge;
import '../../screens/queue_screen_test.dart' show FakeBridge, FakeDjApi;

QueueTrack _track(
  int position, {
  String? appleId = 'apple',
  String? spotifyId,
}) => QueueTrack(
  position: position,
  trackId: 't$position',
  appleId: appleId,
  spotifyId: spotifyId,
  title: 'Title $position',
  artist: 'Artist $position',
  durationMs: 180000,
);

/// A screen stand-in: the mixin's host, with the toasts captured instead of
/// shown so a test can read the exact string the shared builders produced.
class _Host extends ConsumerStatefulWidget {
  const _Host({required this.queue, this.defaultName = 'Road Trip'});

  final List<QueueTrack> queue;
  final String defaultName;

  @override
  ConsumerState<_Host> createState() => _HostState();
}

class _HostState extends ConsumerState<_Host> with MixHandoff<_Host> {
  final List<String> snacks = [];

  @override
  String get mixSessionId => 's1';

  @override
  void showMixSnack(String message) => snacks.add(message);

  @override
  Widget build(BuildContext context) {
    // As both screens do, so the alert can read the account name non-blocking.
    ref.watch(accountNameProvider);
    return Scaffold(
      body: Center(
        child: TextButton(
          key: const Key('open-save'),
          onPressed: () => createPlaylist(
            queue: widget.queue,
            defaultName: widget.defaultName,
            keys: MixHandoffKeys.arrangement,
          ),
          child: const Text('Create playlist'),
        ),
      ),
    );
  }
}

ProviderContainer _container({
  FakeDjApi? api,
  FakeBridge? bridge,
  AuthorStore? authorStore,
  String? accountName,
}) => ProviderContainer(
  overrides: [
    djApiProvider.overrideWithValue(api ?? FakeDjApi()),
    musicKitBridgeProvider.overrideWithValue(bridge ?? FakeBridge()),
    authorStoreProvider.overrideWithValue(authorStore ?? InMemoryAuthorStore()),
    accountNameProvider.overrideWith((ref) async => accountName),
  ],
);

Future<_HostState> _pumpHost(
  WidgetTester tester,
  ProviderContainer container, {
  required List<QueueTrack> queue,
  String defaultName = 'Road Trip',
}) async {
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: _Host(queue: queue, defaultName: defaultName)),
    ),
  );
  await tester.pumpAndSettle();
  return tester.state<_HostState>(find.byType(_Host));
}

/// The row on its own: the design tokens it reads off the theme, and the
/// player it listens to for the Playing state.
Future<void> _pumpRow(
  WidgetTester tester, {
  required List<QueueTrack> queue,
  bool enabled = true,
  MixHandoffKeys keys = MixHandoffKeys.arrangement,
}) async {
  final container = ProviderContainer(
    overrides: [
      playbackProvider.overrideWithValue(
        PlaybackController(playback.FakeApi(), playback.FakeBridge()),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(extensions: const [MixtapeTokens.light]),
        home: Scaffold(
          body: MixActionsRow(
            keys: keys,
            queue: queue,
            enabled: enabled,
            padding: EdgeInsets.zero,
            isPlayingThisMix: () => false,
            onPlayNow: () {},
            onCreatePlaylist: () {},
            onSendToMusic: () {},
            onShare: (_) {},
            saving: false,
            sendingToMusic: false,
            sharing: false,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('handoff copy', () {
    test('a clean play names Apple Music and nothing else', () {
      expect(mixPlaySuccessMessage(0), 'Playing in Apple Music');
    });

    test('skipped songs are counted, and singular at one', () {
      expect(
        mixPlaySuccessMessage(1),
        'Playing in Apple Music · 1 song skipped (not in Apple Music)',
      );
      expect(
        mixPlaySuccessMessage(3),
        'Playing in Apple Music · 3 songs skipped (not in Apple Music)',
      );
    });

    test("a refused play carries Apple's own reason", () {
      expect(
        mixPlayFailureMessage('not authorized'),
        "Couldn't play — not authorized",
      );
    });

    test('a save reports what landed, and the failures only when there are any', () {
      expect(mixSaveSuccessMessage(12, 0), 'Saved 12 songs to Apple Music');
      expect(
        mixSaveSuccessMessage(10, 2),
        'Saved 10 songs to Apple Music (2 failed)',
      );
    });

    test("a refused save carries Apple's own reason", () {
      expect(
        mixSaveFailureMessage('not authorized'),
        "Couldn't save the playlist — not authorized",
      );
    });

    test('a share counts the songs and names the tool', () {
      expect(
        mixShareSuccessMessage(1),
        'Shared 1 song · TuneMyMusic makes the playlist in Spotify',
      );
      expect(
        mixShareSuccessMessage(9),
        'Shared 9 songs · TuneMyMusic makes the playlist in Spotify',
      );
    });

    test('the share sheet opens the transfer tool the web rail uses', () {
      expect(mixTransferToolUrl.toString(), 'https://www.tunemymusic.com/transfer');
    });
  });

  group('gating', () {
    test('a mix with Apple matches refuses nothing', () {
      expect(mixActionsDisabledReason([_track(0), _track(1)]), isNull);
    });

    test('a partial match still plays: the skip count says the rest', () {
      expect(
        mixActionsDisabledReason([_track(0), _track(1, appleId: null)]),
        isNull,
      );
    });

    test('a mix Apple Music cannot match at all says so', () {
      expect(
        mixActionsDisabledReason([_track(0, appleId: null)]),
        "these tracks aren't in Apple Music",
      );
    });

    test('an arrangement that does not exist yet needs no reason', () {
      expect(mixActionsDisabledReason(const []), isNull);
    });

    test('the transfer handoff appears only with a Spotify id present', () {
      expect(mixHasSpotifyActions([_track(0)]), isFalse);
      expect(
        mixHasSpotifyActions([_track(0), _track(1, spotifyId: 'sp1')]),
        isTrue,
      );
    });

    test('Play and Create survive a mix with no ids of either kind', () {
      expect(mixHasAppleActions(const []), isTrue);
      expect(mixHasAppleActions([_track(0, appleId: null)]), isTrue);
    });

    test('only a Spotify-only mix trades them for the transfer tool', () {
      expect(
        mixHasAppleActions([_track(0, appleId: null, spotifyId: 'sp0')]),
        isFalse,
      );
      // One Apple match among them is enough to keep the pair.
      expect(
        mixHasAppleActions([_track(0), _track(1, appleId: null, spotifyId: 'sp1')]),
        isTrue,
      );
    });
  });

  group('the share sheet anchor', () {
    testWidgets('points at the button, in global coordinates', (tester) async {
      late Rect origin;
      late BuildContext screenContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (outer) {
              screenContext = outer;
              return Center(
                child: SizedBox(
                  width: 120,
                  height: 44,
                  child: Builder(
                    builder: (buttonContext) {
                      // Read after layout, from a post-frame callback.
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        origin = mixShareOrigin(buttonContext, screenContext);
                      });
                      return const SizedBox.shrink();
                    },
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();

      expect(origin.width, 120);
      expect(origin.height, 44);
      expect(origin.isEmpty, isFalse);
    });

    testWidgets('falls back to the whole screen when the button has no size', (
      tester,
    ) async {
      late Rect origin;
      late BuildContext screenContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (outer) {
              screenContext = outer;
              return SizedBox.shrink(
                child: Builder(
                  builder: (buttonContext) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      origin = mixShareOrigin(buttonContext, screenContext);
                    });
                    return const SizedBox.shrink();
                  },
                ),
              );
            },
          ),
        ),
      );
      await tester.pump();

      expect(origin, Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio);
      expect(origin.isEmpty, isFalse, reason: 'share_plus throws on an empty rect');
    });
  });

  group('the save alert', () {
    testWidgets('prefills the mix title and the remembered author', (tester) async {
      final host = await _pumpHost(
        tester,
        _container(authorStore: InMemoryAuthorStore('Noble'), accountName: 'Ada'),
        queue: [_track(0)],
        defaultName: 'Late drive',
      );
      await tester.tap(find.byKey(const Key('open-save')));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<TextField>(find.byKey(MixHandoffKeys.arrangement.nameField))
            .controller!
            .text,
        'Late drive',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(MixHandoffKeys.arrangement.authorField))
            .controller!
            .text,
        'Noble',
        reason: 'the name typed on this device beats the account name',
      );
      expect(host.snacks, isEmpty);
    });

    testWidgets('an author typed here rides the save and is remembered', (
      tester,
    ) async {
      final store = InMemoryAuthorStore();
      final bridge = FakeBridge();
      final host = await _pumpHost(
        tester,
        _container(bridge: bridge, authorStore: store),
        queue: [_track(0), _track(1)],
      );

      await tester.tap(find.byKey(const Key('open-save')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(MixHandoffKeys.arrangement.authorField),
        '  Noble  ',
      );
      await tester.tap(find.byKey(MixHandoffKeys.arrangement.saveConfirm));
      await tester.pumpAndSettle();

      expect(bridge.createCalls.single.author, 'Noble');
      expect(bridge.createCalls.single.ids, ['apple', 'apple']);
      expect(await store.read(), 'Noble');
      expect(host.snacks, ['Saved 2 songs to Apple Music']);
    });

    testWidgets('no author at all falls back to the app name and stores nothing', (
      tester,
    ) async {
      final store = InMemoryAuthorStore();
      final bridge = FakeBridge();
      await _pumpHost(
        tester,
        _container(bridge: bridge, authorStore: store),
        queue: [_track(0)],
      );

      await tester.tap(find.byKey(const Key('open-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(MixHandoffKeys.arrangement.saveConfirm));
      await tester.pumpAndSettle();

      expect(bridge.createCalls.single.author, 'mixtape');
      expect(await store.read(), isNull);
    });

    testWidgets('a whitespace-only name falls back to the mix title', (tester) async {
      final bridge = FakeBridge();
      await _pumpHost(
        tester,
        _container(bridge: bridge),
        queue: [_track(0)],
        defaultName: 'Late drive',
      );

      await tester.tap(find.byKey(const Key('open-save')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(MixHandoffKeys.arrangement.nameField),
        '   ',
      );
      await tester.tap(find.byKey(MixHandoffKeys.arrangement.saveConfirm));
      await tester.pumpAndSettle();

      expect(bridge.createCalls.single.name, 'Late drive');
    });

    testWidgets('a second Save tap while the first is in flight creates nothing new', (
      tester,
    ) async {
      final completer = Completer<({int added, int failed})>();
      final bridge = FakeBridge()..onCreatePlaylist = (_, _) => completer.future;
      await _pumpHost(tester, _container(bridge: bridge), queue: [_track(0)]);

      await tester.tap(find.byKey(const Key('open-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(MixHandoffKeys.arrangement.saveConfirm));
      await tester.pump();
      await tester.tap(find.byKey(MixHandoffKeys.arrangement.saveConfirm));
      await tester.pump();

      expect(bridge.createCalls, hasLength(1));
      completer.complete((added: 1, failed: 0));
      await tester.pumpAndSettle();
    });

    testWidgets('a refused save closes the alert and reports the reason', (
      tester,
    ) async {
      final bridge = FakeBridge()
        ..onCreatePlaylist = (_, _) async => throw MusicKitException('not authorized');
      final host = await _pumpHost(
        tester,
        _container(bridge: bridge),
        queue: [_track(0)],
      );

      await tester.tap(find.byKey(const Key('open-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(MixHandoffKeys.arrangement.saveConfirm));
      await tester.pumpAndSettle();

      expect(find.byKey(MixHandoffKeys.arrangement.nameField), findsNothing);
      expect(host.snacks, ["Couldn't save the playlist — not authorized"]);
    });

    testWidgets('a save that added nothing posts no taste signal', (tester) async {
      final api = FakeDjApi();
      final bridge = FakeBridge()
        ..onCreatePlaylist = (_, _) async => (added: 0, failed: 2);
      final host = await _pumpHost(
        tester,
        _container(api: api, bridge: bridge),
        queue: [_track(0), _track(1)],
      );

      await tester.tap(find.byKey(const Key('open-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(MixHandoffKeys.arrangement.saveConfirm));
      await tester.pumpAndSettle();

      expect(api.postedEvents, isEmpty);
      expect(host.snacks, ['Saved 0 songs to Apple Music (2 failed)']);
    });

    testWidgets('a successful save posts exactly one saved_playlist event', (
      tester,
    ) async {
      final api = FakeDjApi();
      await _pumpHost(tester, _container(api: api), queue: [_track(0)]);

      await tester.tap(find.byKey(const Key('open-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(MixHandoffKeys.arrangement.saveConfirm));
      await tester.pumpAndSettle();

      expect(api.postedEvents.map((e) => (e.sessionId, e.type)), [
        ('s1', 'saved_playlist'),
      ]);
    });

    testWidgets('an unexpected throw leaves the alert usable rather than stuck', (
      tester,
    ) async {
      // The two known outcomes pop the alert themselves; anything else
      // (an offline store, a programming error) leaves it open, and the
      // listener must still be able to retry or cancel.
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: MixSaveDialog(
            keys: MixHandoffKeys.arrangement,
            defaultName: 'Late drive',
            defaultAuthor: '',
            onConfirm: (_, _) async {
              attempts++;
              throw StateError('boom');
            },
          ),
        ),
      );
      final keys = MixHandoffKeys.arrangement;

      await tester.tap(find.byKey(keys.saveConfirm));
      await tester.pumpAndSettle();
      // Reported to the app's error handler rather than lost as an
      // unhandled async error the discarded future would swallow.
      expect(tester.takeException(), isStateError);
      expect(attempts, 1);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        tester.widget<FilledButton>(find.byKey(keys.saveConfirm)).onPressed,
        isNotNull,
      );
      expect(tester.widget<TextField>(find.byKey(keys.nameField)).enabled, isTrue);
      expect(
        tester.widget<TextButton>(find.widgetWithText(TextButton, 'Cancel')).onPressed,
        isNotNull,
      );

      // And a retry is possible rather than dead.
      await tester.tap(find.byKey(keys.saveConfirm));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(tester.takeException(), isStateError);
    });

    testWidgets('each screen keeps its own keys and alert title', (tester) async {
      expect(
        MixHandoffKeys.arrangement.saveConfirm,
        isNot(MixHandoffKeys.conversation.saveConfirm),
      );
      expect(MixHandoffKeys.arrangement.saveDialogTitle, 'Save as playlist');
      expect(MixHandoffKeys.conversation.saveDialogTitle, 'Create playlist');

      await _pumpHost(tester, _container(), queue: [_track(0)]);
      await tester.tap(find.byKey(const Key('open-save')));
      await tester.pumpAndSettle();
      expect(find.text('Save as playlist'), findsOneWidget);
    });
  });

  group('the actions row', () {
    testWidgets('an Apple mix draws Play now, Create playlist and Send to Music', (
      tester,
    ) async {
      await _pumpRow(tester, queue: [_track(0), _track(1)]);

      final keys = MixHandoffKeys.arrangement;
      expect(tester.widget<TapeButton>(find.byKey(keys.playNow)).label, 'Play now');
      expect(
        tester.widget<LabelChip>(find.byKey(keys.createPlaylist)).onPressed,
        isNotNull,
      );
      expect(
        tester.widget<TextAction>(find.byKey(keys.sendToMusic)).onPressed,
        isNotNull,
      );
      expect(find.byKey(keys.share), findsNothing);
      expect(find.byKey(keys.reason), findsNothing);
      expect(find.byKey(keys.appleNeeded), findsNothing);
    });

    testWidgets('a Spotify-only mix trades them for the transfer tool and says why', (
      tester,
    ) async {
      await _pumpRow(
        tester,
        queue: [_track(0, appleId: null, spotifyId: 'sp0')],
      );

      final keys = MixHandoffKeys.arrangement;
      expect(find.byKey(keys.playNow), findsNothing);
      expect(find.byKey(keys.createPlaylist), findsNothing);
      expect(find.byKey(keys.sendToMusic), findsNothing);
      expect(
        tester.widget<TapeButton>(find.byKey(keys.share)).label,
        'Send to a transfer tool',
      );
      expect(
        tester.widget<Text>(find.byKey(keys.appleNeeded)).data,
        'Play now and Create playlist need Apple Music',
      );
    });

    testWidgets('a mix with no Apple match keeps the actions, inert, beside the reason', (
      tester,
    ) async {
      await _pumpRow(tester, queue: [_track(0, appleId: null)]);

      final keys = MixHandoffKeys.arrangement;
      expect(tester.widget<TapeButton>(find.byKey(keys.playNow)).onPressed, isNull);
      expect(
        tester.widget<LabelChip>(find.byKey(keys.createPlaylist)).onPressed,
        isNull,
      );
      expect(
        tester.widget<TextAction>(find.byKey(keys.sendToMusic)).onPressed,
        isNull,
      );
      expect(
        tester.widget<Text>(find.byKey(keys.reason)).data,
        "these tracks aren't in Apple Music",
      );
      expect(find.byKey(keys.appleNeeded), findsNothing);
    });

    testWidgets('a busy host makes the whole row inert in place', (tester) async {
      await _pumpRow(
        tester,
        queue: [_track(0), _track(1, spotifyId: 'sp1')],
        enabled: false,
      );

      final keys = MixHandoffKeys.arrangement;
      expect(tester.widget<TapeButton>(find.byKey(keys.playNow)).onPressed, isNull);
      expect(tester.widget<TapeButton>(find.byKey(keys.share)).onPressed, isNull);
      expect(find.byKey(keys.reason), findsNothing);
    });

    testWidgets('the conversation draws the same row under its own keys', (
      tester,
    ) async {
      await _pumpRow(
        tester,
        queue: [_track(0)],
        keys: MixHandoffKeys.conversation,
      );

      expect(find.byKey(MixHandoffKeys.conversation.playNow), findsOneWidget);
      expect(find.byKey(MixHandoffKeys.arrangement.playNow), findsNothing);
    });
  });
}
