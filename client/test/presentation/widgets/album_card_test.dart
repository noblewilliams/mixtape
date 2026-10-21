// The album card, its runners-up and the passed-over row (album picks plan
// Task 12; frames A2 to A8 of `docs/mockups/2026-10-20-album-picks-states.html`,
// locked by `docs/mockups/approved/2026-10-20-album-picks.md`).
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/data/musickit/musickit_bridge.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/album_card.dart';
import 'package:mixtape/presentation/widgets/foundation/status_word.dart';
import 'package:mixtape/presentation/widgets/foundation/tape_button.dart';
import 'package:mixtape/presentation/widgets/foundation/text_action.dart';

AlbumPick album({
  String id = 'a1',
  String title = 'Low Tide Hours',
  String artist = 'Mara Ilesanmi',
  String type = 'album',
  int? releaseYear = 2019,
  int? trackCount = 11,
  int? durationMs = 44 * 60000,
  bool newToThem = false,
  bool saved = false,
  String? appleId = '1440833098',
  int version = 1,
  String reason = 'Slow and warm, and you already know three of its songs.',
}) => AlbumPick(
  id: id,
  title: title,
  artist: artist,
  type: type,
  releaseYear: releaseYear,
  trackCount: trackCount,
  durationMs: durationMs,
  newToThem: newToThem,
  reason: reason,
  savedForLater: saved,
  version: version,
  appleId: appleId,
  artwork: const AlbumArtwork(
    url: 'https://is1-ssl.mzstatic.com/image/thumb/a/{w}x{h}bb.jpg',
    bgColor: '1a2b3c',
  ),
);

class _Bridge implements MusicKitBridge {
  final List<String> albums = [];
  MusicKitException? failWith;

  @override
  Future<bool> playAlbum(String appleAlbumId) async {
    if (failWith != null) throw failWith!;
    albums.add(appleAlbumId);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Onboarding extends OnboardingNotifier {
  _Onboarding(this.service);
  final String? service;

  @override
  Future<OnboardingState> build() async => OnboardingState(
    userId: 'u1',
    sources: const [],
    hasLibrary: true,
    chosenService: service,
    markedRequestedAt: null,
    interviewCompletedAt: null,
    importCompletedAt: null,
  );
}

/// The listener's saved state as the notifier would hold it, so the chip
/// round-trips through a rebuild exactly as it does on the screen.
class _Harness extends StatefulWidget {
  const _Harness({
    required this.pick,
    required this.runnersUp,
    required this.toggles,
    required this.picks,
    this.failToggle = false,
  });

  final bool failToggle;
  final AlbumPick pick;
  final List<AlbumPick> runnersUp;
  final List<bool> toggles;
  final List<String> picks;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late AlbumPick pick = widget.pick;

  @override
  void didUpdateWidget(_Harness old) {
    super.didUpdateWidget(old);
    pick = widget.pick;
  }

  @override
  Widget build(BuildContext context) => AlbumCard(
    pick: pick,
    runnersUp: widget.runnersUp,
    onToggleListenLater: () async {
      // A failed write: the notifier reverts its optimistic flip, so the
      // card sees the pick unchanged.
      if (widget.failToggle) return false;
      final next = !pick.savedForLater;
      widget.toggles.add(next);
      setState(() => pick = pick.copyWith(savedForLater: next));
      return true;
    },
    // "Pick this" makes the runner-up the pick, as the notifier does.
    onPick: (id) {
      widget.picks.add(id);
      setState(() => pick = widget.runnersUp.firstWhere((a) => a.id == id));
    },
  );
}

Future<
  ({_Bridge bridge, List<Uri> opened, List<bool> toggles, List<String> picks})
>
_pump(
  WidgetTester tester, {
  AlbumPick? pick,
  List<AlbumPick> runnersUp = const [],
  String? service = 'apple',
  double textScale = 1,
  bool reducedMotion = false,
  Brightness brightness = Brightness.light,
  bool failToggle = false,
  ValueNotifier<bool>? cardShown,
}) async {
  final shown = cardShown ?? ValueNotifier(true);
  final bridge = _Bridge();
  final opened = <Uri>[];
  final toggles = <bool>[];
  final picks = <String>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        musicKitBridgeProvider.overrideWithValue(bridge),
        onboardingProvider.overrideWith(() => _Onboarding(service)),
        linkOpenerProvider.overrideWithValue((uri) async {
          opened.add(uri);
          return true;
        }),
      ],
      child: MaterialApp(
        theme: brightness == Brightness.dark
            ? MixtapeTheme.dark()
            : MixtapeTheme.light(),
        builder: (context, inner) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            disableAnimations: reducedMotion,
          ),
          child: inner!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ValueListenableBuilder<bool>(
              valueListenable: shown,
              builder: (context, show, _) => show
                  ? _Harness(
                      pick: pick ?? album(),
                      runnersUp: runnersUp,
                      toggles: toggles,
                      picks: picks,
                      failToggle: failToggle,
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (bridge: bridge, opened: opened, toggles: toggles, picks: picks);
}

String _meta(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(AlbumCard.metaKey)).textSpan!.toPlainText();

void main() {
  group('formatting', () {
    test('length reads in minutes, then hours and minutes', () {
      expect(albumLengthLabel(44 * 60000), '44 min');
      expect(albumLengthLabel(72 * 60000), '1 h 12 min');
      expect(albumLengthLabel(120 * 60000), '2 h');
      expect(albumSpokenLength(44 * 60000), '44 minutes');
      expect(albumSpokenLength(72 * 60000), '1 hour 12 minutes');
      expect(albumSpokenLength(61 * 60000), '1 hour 1 minute');
    });

    test('the meta line omits absent parts', () {
      expect(albumMetaLine(album()), 'Album · 2019 · 11 songs · 44 min');
      expect(
        albumMetaLine(
          album(releaseYear: null, trackCount: null, durationMs: null),
        ),
        'Album',
      );
      expect(
        albumMetaLine(album(type: 'ep', trackCount: 1)),
        'EP · 2019 · 1 song · 44 min',
      );
    });
  });

  testWidgets('the pick: cover, title, artist, meta line and why', (
    tester,
  ) async {
    await _pump(tester);

    expect(find.text('Low Tide Hours'), findsOneWidget);
    expect(find.text('Mara Ilesanmi'), findsOneWidget);
    expect(_meta(tester), 'Album · 2019 · 11 songs · 44 min');
    expect(
      find.text('Slow and warm, and you already know three of its songs.'),
      findsOneWidget,
    );
    expect(find.text('New to you'), findsNothing);
    expect(
      tester.getSize(find.byKey(AlbumCard.coverKey)),
      const Size(112, 112),
    );
    expect(find.widgetWithText(TapeButton, 'Play now'), findsOneWidget);
    expect(find.text('Listen later'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.bookmark), findsOneWidget);
  });

  testWidgets('new to you: the plum mark ends the meta line, no icon', (
    tester,
  ) async {
    await _pump(tester, pick: album(newToThem: true, type: 'live'));

    expect(_meta(tester), startsWith('Live · 2019 · 11 songs · 44 min'));
    final mark = tester.widget<StatusWord>(find.byType(StatusWord));
    expect(mark.label, 'New to you');
    expect(mark.kind, StatusKind.accent);
    expect(mark.icon, isFalse);
    // The meta line wraps rather than truncating, so the mark is never cut.
    final meta = tester.widget<Text>(find.byKey(AlbumCard.metaKey));
    expect(meta.overflow, isNot(TextOverflow.ellipsis));
    expect(meta.maxLines, isNull);
  });

  testWidgets('a meta line with no year, count or length is just the type', (
    tester,
  ) async {
    await _pump(
      tester,
      pick: album(releaseYear: null, trackCount: null, durationMs: null),
    );
    expect(_meta(tester), 'Album');
  });

  testWidgets('Play now hands the album to the Music app', (tester) async {
    final h = await _pump(tester);
    await tester.tap(find.byKey(AlbumCard.playKey));
    await tester.pumpAndSettle();
    expect(h.bridge.albums, ['1440833098']);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a failed hand-off says so', (tester) async {
    final h = await _pump(tester);
    h.bridge.failWith = MusicKitException('not authorized');
    await tester.tap(find.byKey(AlbumCard.playKey));
    await tester.pump();
    expect(find.textContaining('not authorized'), findsOneWidget);
  });

  testWidgets('Play now is disabled without an Apple id', (tester) async {
    await _pump(tester, pick: album(appleId: null));
    final button = tester.widget<TapeButton>(
      find.descendant(
        of: find.byKey(AlbumCard.playKey),
        matching: find.byType(TapeButton),
      ),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('saving fills the chip and offers Undo; Undo unsaves', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final h = await _pump(tester);

    await tester.tap(find.byKey(AlbumCard.laterKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(h.toggles, [true]);
    expect(find.text('Saved for later'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.bookmark_fill), findsOneWidget);
    expect(find.text('On your Listen later shelf.'), findsOneWidget);
    final node = tester.getSemantics(find.byKey(AlbumCard.laterKey));
    expect(node.label, 'Saved for later');
    expect(node.flagsCollection.isToggled, isTrue);

    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(h.toggles, [true, false]);
    expect(find.text('Listen later'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('a failed save shows no toast and the chip stays unsaved', (
    tester,
  ) async {
    await _pump(tester, failToggle: true);
    await tester.tap(find.byKey(AlbumCard.laterKey));
    await tester.pumpAndSettle();
    expect(find.text('On your Listen later shelf.'), findsNothing);
    expect(find.text('Listen later'), findsOneWidget);
    expect(find.byIcon(CupertinoIcons.bookmark), findsOneWidget);
  });

  testWidgets('Undo after the pick changed does nothing', (tester) async {
    final h = await _pump(
      tester,
      runnersUp: [album(id: 'b', title: 'Harbour Lights')],
    );
    await tester.tap(find.byKey(AlbumCard.laterKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(h.toggles, [true]);

    await tester.tap(find.byKey(AlbumCard.runnersKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(AlbumCard.pickKey('b')));
    await tester.pump();
    expect(find.text('Harbour Lights'), findsWidgets);

    await tester.tap(find.text('Undo'));
    await tester.pump();
    // Neither B saved by mistake nor A toggled behind the listener's back.
    expect(h.toggles, [true]);
    expect(find.text('Listen later'), findsOneWidget);
  });

  testWidgets('Undo after the card is gone does not throw', (tester) async {
    final shown = ValueNotifier(true);
    final h = await _pump(tester, cardShown: shown);
    await tester.tap(find.byKey(AlbumCard.laterKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    shown.value = false;
    await tester.pump();
    expect(find.byType(AlbumCard), findsNothing);

    await tester.tap(find.text('Undo'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(h.toggles, [true]);
  });

  testWidgets('the toast leaves after four seconds', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(AlbumCard.laterKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('On your Listen later shelf.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('On your Listen later shelf.'), findsNothing);
  });

  testWidgets('unsaving shows no toast', (tester) async {
    final h = await _pump(tester, pick: album(saved: true));
    expect(find.text('Saved for later'), findsOneWidget);

    await tester.tap(find.byKey(AlbumCard.laterKey));
    await tester.pumpAndSettle();

    expect(h.toggles, [false]);
    expect(find.text('Listen later'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets(
    'a Spotify-only listener gets Open in Spotify in place of Play now',
    (tester) async {
      final h = await _pump(tester, service: 'spotify');

      expect(find.byKey(AlbumCard.playKey), findsNothing);
      final link = tester.widget<TextAction>(find.byKey(AlbumCard.spotifyKey));
      expect(link.label, 'Open in Spotify');
      expect(link.underline, isTrue);
      expect(find.text('Listen later'), findsOneWidget);

      await tester.tap(find.byKey(AlbumCard.spotifyKey));
      await tester.pumpAndSettle();
      expect(
        h.opened.single.toString(),
        'https://open.spotify.com/search/Mara%20Ilesanmi%20Low%20Tide%20Hours',
      );
    },
  );

  testWidgets('a slash in a name stays inside the Spotify search', (
    tester,
  ) async {
    final h = await _pump(
      tester,
      service: 'spotify',
      pick: album(artist: 'AC/DC', title: 'Back in Black'),
    );
    await tester.tap(find.byKey(AlbumCard.spotifyKey));
    await tester.pumpAndSettle();
    expect(
      h.opened.single.toString(),
      'https://open.spotify.com/search/AC%2FDC%20Back%20in%20Black',
    );
    expect(h.opened.single.pathSegments, ['search', 'AC/DC Back in Black']);
  });

  group('runners-up', () {
    final runners = [
      album(
        id: 'r1',
        title: 'Nightshift Radio',
        artist: 'The Quiet Parade',
        type: 'ep',
        releaseYear: 2016,
        newToThem: true,
      ),
      album(id: 'r2', title: 'Slow Rooms', releaseYear: 2014),
    ];

    testWidgets('closed, then open with Pick this', (tester) async {
      final h = await _pump(tester, runnersUp: runners);

      expect(find.text('Two more it considered'), findsOneWidget);
      expect(find.text('Nightshift Radio'), findsNothing);
      expect(
        tester.getSize(find.byKey(AlbumCard.runnersKey)).height,
        greaterThanOrEqualTo(44),
      );

      await tester.tap(find.byKey(AlbumCard.runnersKey));
      await tester.pumpAndSettle();

      expect(find.text('Nightshift Radio'), findsOneWidget);
      expect(find.text('The Quiet Parade · EP · 2016'), findsOneWidget);
      expect(find.text('Mara Ilesanmi · Album · 2014'), findsOneWidget);
      // The mark on the runner that is new to them, and only there.
      expect(
        find.descendant(
          of: find.byKey(AlbumCard.runnerKey('r1')),
          matching: find.byType(StatusWord),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(AlbumCard.runnerKey('r2')),
          matching: find.byType(StatusWord),
        ),
        findsNothing,
      );
      final rotation = tester.widget<AnimatedRotation>(
        find.descendant(
          of: find.byKey(AlbumCard.runnersKey),
          matching: find.byType(AnimatedRotation),
        ),
      );
      expect(rotation.turns, 0.5);

      await tester.tap(find.byKey(AlbumCard.pickKey('r2')));
      expect(h.picks, ['r2']);
    });

    testWidgets(
      'a runner-up row reads title, artist and mark with Pick this as its action',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await _pump(tester, runnersUp: runners);
        await tester.tap(find.byKey(AlbumCard.runnersKey));
        await tester.pumpAndSettle();

        final node = tester.getSemantics(find.byKey(AlbumCard.runnerKey('r1')));
        expect(
          node.label,
          'Nightshift Radio, The Quiet Parade, EP, 2016, new to you',
        );
        expect(node.getSemanticsData().customSemanticsActionIds, isNotEmpty);
        semantics.dispose();
      },
    );

    testWidgets('one runner-up says one', (tester) async {
      await _pump(tester, runnersUp: [runners.first]);
      expect(find.text('One more it considered'), findsOneWidget);
    });

    testWidgets('no runners-up, no row', (tester) async {
      await _pump(tester);
      expect(find.byKey(AlbumCard.runnersKey), findsNothing);
    });

    testWidgets('the height change is 200 ms, zero under reduced motion', (
      tester,
    ) async {
      await _pump(tester, runnersUp: runners);
      expect(
        tester.widget<AnimatedSize>(find.byType(AnimatedSize)).duration,
        const Duration(milliseconds: 200),
      );

      await _pump(tester, runnersUp: runners, reducedMotion: true);
      expect(
        tester.widget<AnimatedSize>(find.byType(AnimatedSize)).duration,
        Duration.zero,
      );
      expect(
        tester.widget<AnimatedRotation>(find.byType(AnimatedRotation)).duration,
        Duration.zero,
      );
    });
  });

  testWidgets('the passed-over row: muted, in words, with Go back', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final back = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Scaffold(
          body: PassedOverRow(album: album(version: 3), onGoBack: back.add),
        ),
      ),
    );

    expect(find.text('Low Tide Hours'), findsOneWidget);
    expect(find.text('Passed over'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(PassedOverRow.coverKey)),
      const Size(40, 40),
    );
    final node = tester.getSemantics(find.byKey(PassedOverRow.keyFor(3)));
    expect(node.label, 'Low Tide Hours, passed over');
    expect(node.getSemanticsData().customSemanticsActionIds, isNotEmpty);

    await tester.tap(find.byKey(PassedOverRow.goBackKey(3)));
    expect(back, [3]);
    semantics.dispose();
  });

  testWidgets('at 1.5x text the cover drops to 60 pt and the actions wrap', (
    tester,
  ) async {
    await _pump(tester, textScale: 1.5);
    expect(tester.getSize(find.byKey(AlbumCard.coverKey)), const Size(60, 60));
    expect(find.byKey(AlbumCard.actionsKey), findsOneWidget);
    expect(tester.widget(find.byKey(AlbumCard.actionsKey)), isA<Wrap>());
    // The meta line sits below the cover row, not beside the cover.
    final cover = tester.getRect(find.byKey(AlbumCard.coverKey));
    final meta = tester.getRect(find.byKey(AlbumCard.metaKey));
    expect(meta.top, greaterThanOrEqualTo(cover.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('dark builds on the theme tokens', (tester) async {
    await _pump(
      tester,
      brightness: Brightness.dark,
      pick: album(newToThem: true, saved: true),
    );
    expect(find.text('Saved for later'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('VoiceOver reads the card as one item ending with the mark', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester);
    var node = tester.getSemantics(find.byKey(AlbumCard.cardKey));
    expect(
      node.label,
      'Low Tide Hours, by Mara Ilesanmi, album, 2019, 11 songs, 44 minutes',
    );
    expect(
      node.hint,
      'Slow and warm, and you already know three of its songs.',
    );

    await _pump(tester, pick: album(newToThem: true, type: 'ep'));
    node = tester.getSemantics(find.byKey(AlbumCard.cardKey));
    expect(
      node.label,
      'Low Tide Hours, by Mara Ilesanmi, EP, 2019, 11 songs, 44 minutes, new to you',
    );
    semantics.dispose();
  });
}
