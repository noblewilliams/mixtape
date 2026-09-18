import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/musickit/musickit_bridge.dart';
import 'package:mixtape/data/playback/listening_meter.dart';
import 'package:mixtape/data/playback/playback_controller.dart';
import 'package:mixtape/data/playback/player_bridge.dart';
import 'package:mixtape/data/shell/mini_player_state.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/playback_provider.dart';
import 'package:mixtape/presentation/screens/playback_screen.dart';
import 'package:mixtape/presentation/screens/queue_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/mix_energy_summary.dart';
import 'package:mixtape/presentation/widgets/now_playing_scrubber.dart';
import 'package:mixtape/presentation/widgets/foundation/cassette_tile.dart';

import '../data/playback/playback_controller_test.dart' show FakeApi;
import '../helpers/auth_ui_snapshot.dart';

/// Every action the screen asked the native player for, in order.
class RecordingBridge extends AppPlayerBridge {
  final actions = <String>[];
  final seconds = <double?>[];
  final events = StreamController<PlayerSample>.broadcast();

  @override
  Stream<PlayerSample> get samples => events.stream;

  @override
  Future<void> start(List<String> ids) async => actions.add('start');

  @override
  Future<void> command(String action, {double? seconds}) async {
    actions.add(action);
    this.seconds.add(seconds);
  }
}

class FakeMusicKit extends MusicKitBridge {
  FakeMusicKit({this.fail = false});
  final bool fail;
  final played = <List<String>>[];

  @override
  Future<bool> playQueue(List<String> appleIds) async {
    if (fail) throw MusicKitException('nope');
    played.add(appleIds);
    return true;
  }
}

class _Observer extends NavigatorObserver {
  Route<dynamic>? lastPushed;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    lastPushed = route;
    super.didPush(route, previousRoute);
  }
}

QueueTrack _track(int position) => QueueTrack(
  position: position,
  trackId: 'track-$position',
  appleId: '10$position',
  title: position == 4 ? 'Low Tide, Late' : 'Song $position',
  artist: position == 4 ? 'Harbour Lights' : 'Someone',
  durationMs: 235000,
);

final _queue = [for (var i = 0; i < 12; i++) _track(i)];

PlaybackController _player(
  RecordingBridge bridge, {
  String? sessionId = 'mix-1',
  List<QueueTrack>? tracks,
  int? unavailableIndex,
  String error = '',
  String status = 'playing',
}) {
  final player = PlaybackController(FakeApi(), bridge)
    ..sessionId = sessionId
    ..version = 4
    ..title = 'A slow way into Sunday'
    ..tracks = tracks ?? _queue
    ..unavailableIndex = unavailableIndex
    ..error = error
    ..sample = PlayerSample(index: 4, positionMs: 84000, status: status);
  addTearDown(() async {
    player.dispose();
    await bridge.events.close();
  });
  return player;
}

Future<void> _pump(
  WidgetTester tester,
  PlaybackController player, {
  Brightness brightness = Brightness.dark,
  Size size = const Size(390, 844),
  double textScale = 1,
  MusicKitBridge? musicKit,
  Map<String, dynamic> energy = const {},
  _Observer? observer,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        playbackProvider.overrideWithValue(player),
        musicKitBridgeProvider.overrideWithValue(musicKit ?? FakeMusicKit()),
        mixEnergyProvider.overrideWith((ref, key) async => energy),
      ],
      child: RepaintBoundary(
        key: authSnapshotKey,
        child: MaterialApp(
          theme: brightness == Brightness.dark
              ? MixtapeTheme.dark()
              : MixtapeTheme.light(),
          navigatorObservers: observer == null ? const [] : [observer],
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: const PlaybackScreen(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  // The app's own root push is not what any of these tests are asking about.
  observer?.lastPushed = null;
}

const _keys = <String, Key>{
  'Previous song': PlaybackScreen.previousKey,
  'Play': PlaybackScreen.playPauseKey,
  'Pause': PlaybackScreen.playPauseKey,
  'Next song': PlaybackScreen.nextKey,
  'Shape': PlaybackScreen.shapeKey,
  'Up next': PlaybackScreen.upNextKey,
  'Send to Music': PlaybackScreen.sendToMusicKey,
};

Finder _action(String label) => find.byKey(_keys[label]!);

void main() {
  testWidgets('the song, its artwork and the mix are one quiet stack', (
    tester,
  ) async {
    final bridge = RecordingBridge();
    await loadAuthSnapshotFonts(tester);
    await _pump(tester, _player(bridge));

    expect(find.text('Low Tide, Late'), findsOneWidget);
    expect(find.text('Harbour Lights'), findsOneWidget);
    // The artwork placeholder: no picture on this track yet.
    expect(find.text(PlaybackScreen.artworkPlaceholder), findsOneWidget);
    // The mix is one line, not a container.
    expect(find.text('A slow way into Sunday · 5 of 12'), findsOneWidget);
    expect(
      tester.widget<CassetteTile>(find.byType(CassetteTile)).width,
      PlaybackScreen.mixLineCassetteWidth,
    );
    expect(find.byType(NowPlayingScrubber), findsOneWidget);
    expect(find.text('1:24'), findsOneWidget);
    expect(find.text('-2:31'), findsOneWidget);
    expect(find.byType(AppBar), findsNothing);
    expect(find.byKey(PlaybackScreen.dragHandleKey), findsOneWidget);
    // Opening Now Playing looks at the player; it never touches it.
    expect(bridge.actions, isEmpty);
    await captureAuthSnapshot(tester, 'player-native-dark');
  });

  testWidgets('the sheet keeps its dark ground under a light system theme', (
    tester,
  ) async {
    final bridge = RecordingBridge();
    await loadAuthSnapshotFonts(tester);
    await _pump(tester, _player(bridge), brightness: Brightness.light);

    expect(find.text('Low Tide, Late'), findsOneWidget);
    expect(bridge.actions, isEmpty);
    await captureAuthSnapshot(tester, 'player-native-light');
  });

  testWidgets('trouble observing the player is a line, not a dead end', (
    tester,
  ) async {
    final bridge = RecordingBridge();
    await _pump(
      tester,
      _player(bridge, error: 'Playback observation is unavailable.'),
    );

    expect(find.byKey(PlaybackScreen.errorLineKey), findsOneWidget);
    expect(find.text('Playback observation is unavailable.'), findsOneWidget);
    // The song is still playing, and still playable.
    expect(find.text('Low Tide, Late'), findsOneWidget);
    expect(find.text('Connect Apple Music'), findsNothing);
    await tester.tap(_action('Pause'));
    await tester.pump();
    expect(bridge.actions, ['pause']);
  });

  testWidgets('transport and the scrubber drive the player', (tester) async {
    final bridge = RecordingBridge();
    final player = _player(bridge);
    await _pump(tester, player);

    await tester.tap(_action('Previous song'));
    await tester.pump();
    await tester.tap(_action('Pause'));
    await tester.pump();
    await tester.tap(_action('Next song'));
    await tester.pump();
    expect(bridge.actions, ['previous', 'pause', 'next']);

    final bar = tester.getRect(find.byKey(NowPlayingScrubber.barKey));
    await tester.dragFrom(
      Offset(bar.left + 1, bar.center.dy),
      Offset(bar.width / 2, 0),
    );
    await tester.pump();
    expect(bridge.actions.last, 'seek');
    expect(bridge.seconds.last, closeTo(117.5, 4));
  });

  testWidgets('a paused player offers Play', (tester) async {
    final bridge = RecordingBridge();
    await _pump(tester, _player(bridge, status: 'paused'));
    await tester.tap(_action('Play'));
    await tester.pump();
    expect(bridge.actions, ['resume']);
  });

  testWidgets('an unavailable track says so and leaves only Next', (
    tester,
  ) async {
    final bridge = RecordingBridge();
    final observer = _Observer();
    await _pump(
      tester,
      _player(bridge, unavailableIndex: 4),
      observer: observer,
      energy: const {'energyArc': 'rise', 'energyJourney': {'status': 'follows'}},
    );

    expect(find.text(MiniPlayerState.unavailableLine), findsOneWidget);
    expect(find.text('Harbour Lights'), findsNothing);

    for (final label in const [
      'Previous song',
      'Pause',
      'Shape',
      'Up next',
      'Send to Music',
    ]) {
      await tester.tap(_action(label), warnIfMissed: false);
      await tester.pump();
    }
    final bar = tester.getRect(find.byKey(NowPlayingScrubber.barKey));
    await tester.dragFrom(
      Offset(bar.left + 1, bar.center.dy),
      Offset(bar.width / 2, 0),
    );
    await tester.pump();
    expect(bridge.actions, isEmpty);
    expect(observer.lastPushed, isNull);

    await tester.tap(_action('Next song'));
    await tester.pump();
    expect(bridge.actions, ['next']);
  });

  testWidgets('every transport and action control is one VoiceOver can '
      'activate', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      _player(RecordingBridge()),
      energy: const {
        'energyArc': 'rise',
        'energyJourney': {'status': 'follows'},
      },
    );

    for (final label in const [
      'Previous song',
      'Pause',
      'Next song',
      'Up next',
      'Send to Music',
    ]) {
      final data = tester.getSemantics(_action(label)).getSemanticsData();
      expect(
        data.hasAction(SemanticsAction.tap),
        isTrue,
        reason: '$label: a node with no tap action cannot be activated by '
            'VoiceOver',
      );
      expect(data.flagsCollection.isButton, isTrue);
    }

    handle.dispose();
  });

  testWidgets('a disabled transport control offers VoiceOver no action', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, _player(RecordingBridge(), unavailableIndex: 4));

    for (final label in const [
      'Previous song',
      'Pause',
      'Shape',
      'Up next',
      'Send to Music',
    ]) {
      expect(
        tester.getSemantics(_action(label)).getSemanticsData().hasAction(
          SemanticsAction.tap,
        ),
        isFalse,
        reason: '$label is disabled here and must offer no action',
      );
    }
    // Next is the one way out of an unavailable track and stays live.
    expect(
      tester.getSemantics(_action('Next song')).getSemanticsData().hasAction(
        SemanticsAction.tap,
      ),
      isTrue,
    );

    handle.dispose();
  });

  testWidgets('Send to Music hands the queue over and says what that means', (
    tester,
  ) async {
    final bridge = RecordingBridge();
    final musicKit = FakeMusicKit();
    await _pump(tester, _player(bridge), musicKit: musicKit);

    await tester.tap(_action('Send to Music'));
    await tester.pumpAndSettle();
    expect(musicKit.played.single, [for (final t in _queue) t.appleId]);
    expect(find.text(PlaybackScreen.sentToMusicMessage), findsOneWidget);
  });

  testWidgets('a failed handoff keeps the mix and says so', (tester) async {
    final bridge = RecordingBridge();
    await _pump(tester, _player(bridge), musicKit: FakeMusicKit(fail: true));

    await tester.tap(_action('Send to Music'));
    await tester.pumpAndSettle();
    expect(find.text(PlaybackScreen.sendFailedMessage), findsOneWidget);
  });

  testWidgets('Up next pushes the arrangement for the playing mix', (
    tester,
  ) async {
    final bridge = RecordingBridge();
    final observer = _Observer();
    await _pump(tester, _player(bridge), observer: observer);

    await tester.tap(_action('Up next'));
    final route = observer.lastPushed;
    expect(route, isA<MaterialPageRoute<void>>());
    final pushed = (route! as MaterialPageRoute<void>).builder(
      tester.element(find.byType(PlaybackScreen)),
    );
    expect(pushed, isA<QueueScreen>());
    expect((pushed as QueueScreen).sessionId, 'mix-1');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Shape opens the mix shape', (tester) async {
    final bridge = RecordingBridge();
    await _pump(
      tester,
      _player(bridge),
      energy: const {
        'energyArc': 'rise',
        'energyJourney': {'status': 'follows'},
      },
    );
    await tester.tap(_action('Shape'));
    await tester.pumpAndSettle();
    expect(find.text('Build gradually'), findsOneWidget);
  });

  testWidgets('Shape rests when the mix has no shape', (tester) async {
    final bridge = RecordingBridge();
    await _pump(tester, _player(bridge));
    await tester.tap(_action('Shape'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('More holds Repeat song and Listening preferences', (
    tester,
  ) async {
    final bridge = RecordingBridge();
    await _pump(tester, _player(bridge));

    await tester.tap(find.byKey(PlaybackScreen.moreKey));
    await tester.pumpAndSettle();
    expect(find.text('Repeat song'), findsOneWidget);
    expect(find.text('Listening preferences'), findsOneWidget);

    await tester.tap(find.text('Repeat song'));
    await tester.pumpAndSettle();
    expect(bridge.actions, ['seek', 'resume']);

    await tester.tap(find.byKey(PlaybackScreen.moreKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Listening preferences'));
    await tester.pumpAndSettle();
    expect(find.text('Learn from my listening in Mixtape'), findsOneWidget);
  });

  testWidgets('More can stop the player, and cancels while it is busy', (
    tester,
  ) async {
    final bridge = RecordingBridge();
    final player = _player(bridge);
    await _pump(tester, player);

    await tester.tap(find.byKey(PlaybackScreen.moreKey));
    await tester.pumpAndSettle();
    expect(find.text('Stop'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(bridge.actions, ['stop']);

    player
      ..busy = true
      ..notifyListeners();
    await tester.pump();
    await tester.tap(find.byKey(PlaybackScreen.moreKey));
    await tester.pumpAndSettle();
    // The sheet has a Cancel of its own, so the entry is found by its key.
    expect(
      find.descendant(
        of: find.byKey(PlaybackScreen.stopActionKey),
        matching: find.text('Cancel'),
      ),
      findsOneWidget,
    );
    expect(find.text('Stop'), findsNothing);
  });

  testWidgets('nothing connected keeps the Connect Apple Music path', (
    tester,
  ) async {
    final bridge = RecordingBridge();
    await _pump(
      tester,
      _player(
        bridge,
        tracks: const [],
        error:
            'Apple Music access was not granted. Your mix is unchanged.',
      ),
    );

    expect(
      find.text('Apple Music access was not granted. Your mix is unchanged.'),
      findsOneWidget,
    );
    expect(find.text('Connect Apple Music'), findsOneWidget);
    expect(find.byType(NowPlayingScrubber), findsNothing);
  });

  testWidgets('200% text on a 320 pt phone still reaches every control', (
    tester,
  ) async {
    final bridge = RecordingBridge();
    await _pump(
      tester,
      _player(bridge),
      brightness: Brightness.light,
      size: const Size(320, 568),
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(_action('Send to Music'), 120);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
