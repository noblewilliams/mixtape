import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/playlists/playlist_api.dart';
import 'package:mixtape/data/playlists/playlist_context_models.dart';
import 'package:mixtape/data/playlists/playlist_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/playlist_providers.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/status_word.dart';
import 'package:mixtape/presentation/widgets/playlist_inspiration.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_menu.dart';

class SignedIn extends AuthNotifier {
  @override
  AuthStatus build() => AuthStatus.signedIn;
}

PlaylistSummary playlist(
  String id,
  String source, {
  String name = 'Night Bus Notes',
  int entryCount = 12,
}) => PlaylistSummary(
  id: id,
  name: name,
  source: source,
  kind: 'user',
  entryCount: entryCount,
  inLibrary: true,
  capability: 'copy_only',
);

class BrowseApi implements PlaylistApi {
  BrowseApi({this.pages});

  /// Overrides the two-page default with a fixed first page.
  final List<PlaylistSummary>? pages;
  final queries = <String?>[];
  final cursors = <String?>[];

  @override
  Future<PlaylistPage> list({
    PlaylistStatus status = PlaylistStatus.active,
    String? query,
    int limit = 30,
    String? cursor,
  }) async {
    queries.add(query);
    cursors.add(cursor);
    if (pages != null) return PlaylistPage(playlists: pages!);
    return PlaylistPage(
      playlists: [
        for (var i = 0; i < 8; i++)
          playlist(
            cursor == null ? 'apple-$i' : 'spotify-$i',
            cursor == null ? 'apple' : 'spotify_export',
          ),
      ],
      nextCursor: cursor == null ? 'next' : null,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A host that opens the picker and remembers what it answered.
class PickerHost extends StatelessWidget {
  const PickerHost({
    super.key,
    required this.onChoice,
    this.selected,
    this.brightness = Brightness.light,
  });

  final ValueChanged<PlaylistInspirationChoice?> onChoice;
  final InitialPlaylistSeed? selected;
  final Brightness brightness;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: brightness == Brightness.dark
        ? MixtapeTheme.dark()
        : MixtapeTheme.light(),
    home: Consumer(
      builder: (context, ref, _) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () async => onChoice(
              await showPlaylistInspirationPicker(
                context,
                ref,
                selected: selected,
              ),
            ),
            child: const Text('Pick'),
          ),
        ),
      ),
    ),
  );
}

Future<void> openPicker(
  WidgetTester tester,
  PlaylistApi api, {
  required ValueChanged<PlaylistInspirationChoice?> onChoice,
  InitialPlaylistSeed? selected,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(SignedIn.new),
        playlistApiProvider.overrideWithValue(api),
      ],
      child: PickerHost(
        onChoice: onChoice,
        selected: selected,
        brightness: brightness,
      ),
    ),
  );
  await tester.tap(find.text('Pick'));
  await tester.pumpAndSettle();
}

/// The attachment chip on its own, in the tone and menu mode under test.
Widget chipHost({
  String? name = 'Late nights',
  InspirationChipTone tone = InspirationChipTone.ready,
  bool excludeSourceTracks = false,
  VoidCallback? onPick,
  VoidCallback? onDetach,
  VoidCallback? onToggleExclude,
  Brightness brightness = Brightness.light,
}) => MaterialApp(
  theme: brightness == Brightness.dark
      ? MixtapeTheme.dark()
      : MixtapeTheme.light(),
  home: Scaffold(
    body: Center(
      child: InspirationChip(
        name: name,
        tone: tone,
        excludeSourceTracks: excludeSourceTracks,
        onPick: onPick,
        onDetach: onDetach,
        onToggleExclude: onToggleExclude,
      ),
    ),
  ),
);

void main() {
  group('attachment chip menu', () {
    testWidgets('offers Replace, Exclude its songs and Detach', (tester) async {
      var picks = 0;
      var detaches = 0;
      var toggles = 0;
      await tester.pumpWidget(
        chipHost(
          onPick: () => picks++,
          onDetach: () => detaches++,
          onToggleExclude: () => toggles++,
        ),
      );

      expect(find.text('Inspired by: Late nights'), findsOneWidget);
      // The chip itself never detaches: the cross is gone, the menu owns it.
      expect(find.byKey(InspirationChip.detachKey), findsNothing);

      await tester.tap(find.byKey(InspirationChip.chipKey));
      await tester.pumpAndSettle();
      expect(find.byKey(InspirationChip.replaceItemKey), findsOneWidget);
      expect(find.byKey(InspirationChip.excludeItemKey), findsOneWidget);
      expect(find.byKey(InspirationChip.detachItemKey), findsOneWidget);
      expect(find.text(InspirationChip.excludeLabel), findsOneWidget);

      await tester.tap(find.byKey(InspirationChip.excludeItemKey));
      await tester.pumpAndSettle();
      expect(toggles, 1);
      expect(picks, 0);
      expect(detaches, 0);

      await tester.tap(find.byKey(InspirationChip.chipKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(InspirationChip.replaceItemKey));
      await tester.pumpAndSettle();
      expect(picks, 1);

      await tester.tap(find.byKey(InspirationChip.chipKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(InspirationChip.detachItemKey));
      await tester.pumpAndSettle();
      expect(detaches, 1);
    });

    testWidgets('the exclude item is checked when the flag is on', (
      tester,
    ) async {
      await tester.pumpWidget(
        chipHost(
          excludeSourceTracks: true,
          onPick: () {},
          onDetach: () {},
          onToggleExclude: () {},
        ),
      );
      await tester.tap(find.byKey(InspirationChip.chipKey));
      await tester.pumpAndSettle();

      final item = tester.widget<MixtapeMenuItem<Object?>>(
        find.byKey(InspirationChip.excludeItemKey),
      );
      expect(item.action.isSelected, isTrue);
    });

    testWidgets('an unavailable chip keeps its name and offers no exclude', (
      tester,
    ) async {
      await tester.pumpWidget(
        chipHost(
          tone: InspirationChipTone.unavailable,
          onPick: () {},
          onDetach: () {},
          onToggleExclude: () {},
        ),
      );

      expect(find.text('Late nights · unavailable'), findsOneWidget);
      await tester.tap(find.byKey(InspirationChip.chipKey));
      await tester.pumpAndSettle();
      expect(find.byKey(InspirationChip.replaceItemKey), findsOneWidget);
      expect(find.byKey(InspirationChip.detachItemKey), findsOneWidget);
      expect(find.byKey(InspirationChip.excludeItemKey), findsNothing);
      expect(find.byKey(InspirationChip.menuNoteKey), findsNothing);
    });

    testWidgets('an insufficient chip says it cannot be sent in its header', (
      tester,
    ) async {
      await tester.pumpWidget(
        chipHost(
          tone: InspirationChipTone.insufficient,
          onPick: () {},
          onDetach: () {},
          onToggleExclude: () {},
        ),
      );

      expect(find.text('Late nights · too few songs'), findsOneWidget);
      await tester.tap(find.byKey(InspirationChip.chipKey));
      await tester.pumpAndSettle();
      expect(find.byKey(InspirationChip.menuNoteKey), findsOneWidget);
      expect(find.text(InspirationChip.insufficientNote), findsOneWidget);
      expect(find.byKey(InspirationChip.excludeItemKey), findsNothing);
      expect(find.byKey(InspirationChip.replaceItemKey), findsOneWidget);
      expect(find.byKey(InspirationChip.detachItemKey), findsOneWidget);
      // The header is a note, not an action.
      expect(
        tester
            .widget<MixtapeMenuItem<Object?>>(
              find.byKey(InspirationChip.menuNoteKey),
            )
            .action
            .enabled,
        isFalse,
      );
    });

    testWidgets('without a menu the chip still picks and detaches directly', (
      tester,
    ) async {
      var picks = 0;
      var detaches = 0;
      await tester.pumpWidget(
        chipHost(onPick: () => picks++, onDetach: () => detaches++),
      );

      await tester.tap(find.byKey(InspirationChip.chipKey));
      await tester.pumpAndSettle();
      expect(picks, 1);
      await tester.tap(find.byKey(InspirationChip.detachKey));
      await tester.pumpAndSettle();
      expect(detaches, 1);
    });

    testWidgets('the cross is a button VoiceOver can activate', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(chipHost(onPick: () {}, onDetach: () {}));

      final data = tester
          .getSemantics(find.bySemanticsLabel('Detach playlist inspiration'))
          .getSemanticsData();
      expect(
        data.hasAction(SemanticsAction.tap),
        isTrue,
        reason: 'a node with no tap action cannot be activated by VoiceOver',
      );
      expect(data.flagsCollection.isButton, isTrue);

      handle.dispose();
    });
  });

  group('picker sheet', () {
    testWidgets('searches, seeds the exclude flag and returns the exact id', (
      tester,
    ) async {
      final api = BrowseApi();
      PlaylistInspirationChoice? choice;
      await openPicker(tester, api, onChoice: (value) => choice = value);

      expect(find.text(PlaylistPicker.title), findsOneWidget);
      expect(find.byKey(PlaylistPicker.handleKey), findsOneWidget);
      expect(find.text(PlaylistPicker.excludeLabel), findsOneWidget);

      await tester.enterText(find.byKey(PlaylistPicker.searchKey), 'Night');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(api.queries.last, 'Night');

      await tester.tap(find.byKey(PlaylistPicker.excludeKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(PlaylistPicker.rowKey('apple-0')));
      await tester.pumpAndSettle();

      expect(choice!.seed.playlistId, 'apple-0');
      expect(choice!.seed.excludeSourceTracks, isTrue);
    });

    testWidgets('rows carry the song count and the source label', (
      tester,
    ) async {
      final api = BrowseApi(
        pages: [
          playlist('apple-0', 'apple', name: 'Late nights', entryCount: 41),
          playlist(
            'spotify-0',
            'spotify_export',
            name: 'Running, long',
            entryCount: 63,
          ),
        ],
      );
      await openPicker(tester, api, onChoice: (_) {});

      expect(find.text('41 songs · Apple Music'), findsOneWidget);
      expect(find.text('63 songs · Spotify import'), findsOneWidget);
    });

    testWidgets('a seeded selection opens with its toggle on and row checked', (
      tester,
    ) async {
      final api = BrowseApi(
        pages: [
          playlist('apple-0', 'apple'),
          playlist('spotify-0', 'spotify_export'),
        ],
      );
      PlaylistInspirationChoice? choice;
      await openPicker(
        tester,
        api,
        onChoice: (value) => choice = value,
        selected: const InitialPlaylistSeed(
          playlistId: 'spotify-0',
          excludeSourceTracks: true,
        ),
      );

      expect(
        tester.widget<Switch>(find.byKey(PlaylistPicker.excludeKey)).value,
        isTrue,
      );
      expect(
        find.descendant(
          of: find.byKey(PlaylistPicker.rowKey('spotify-0')),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(PlaylistPicker.rowKey('apple-0')),
          matching: find.byIcon(Icons.check),
        ),
        findsNothing,
      );

      // Choosing again keeps the flag it opened with.
      await tester.tap(find.byKey(PlaylistPicker.rowKey('apple-0')));
      await tester.pumpAndSettle();
      expect(choice!.seed.playlistId, 'apple-0');
      expect(choice!.seed.excludeSourceTracks, isTrue);
    });

    testWidgets('a playlist with too few matched songs cannot be chosen', (
      tester,
    ) async {
      final api = BrowseApi(
        pages: [
          playlist('thin', 'apple', name: 'Quiet mornings', entryCount: 2),
          playlist('fat', 'apple', name: 'Late nights', entryCount: 41),
        ],
      );
      PlaylistInspirationChoice? choice;
      var answered = false;
      await openPicker(
        tester,
        api,
        onChoice: (value) {
          choice = value;
          answered = true;
        },
      );

      expect(find.byType(StatusWord), findsOneWidget);
      expect(find.text(PlaylistPicker.notEnoughLabel), findsOneWidget);
      // Still listed, still readable.
      expect(find.text('Quiet mornings'), findsOneWidget);

      await tester.tap(
        find.byKey(PlaylistPicker.rowKey('thin')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(answered, isFalse);
      expect(find.text(PlaylistPicker.title), findsOneWidget);

      await tester.tap(find.byKey(PlaylistPicker.rowKey('fat')));
      await tester.pumpAndSettle();
      expect(choice!.seed.playlistId, 'fat');
    });

    testWidgets('scrolling to the end pages in the next playlists', (
      tester,
    ) async {
      final api = BrowseApi();
      PlaylistInspirationChoice? choice;
      await openPicker(tester, api, onChoice: (value) => choice = value);

      expect(api.cursors, [null]);
      await tester.drag(
        find.byKey(PlaylistPicker.listKey),
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      expect(api.cursors, [null, 'next']);

      await tester.scrollUntilVisible(
        find.byKey(PlaylistPicker.rowKey('spotify-7')),
        200,
        scrollable: find.descendant(
          of: find.byKey(PlaylistPicker.listKey),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(find.byKey(PlaylistPicker.rowKey('spotify-7')));
      await tester.pumpAndSettle();
      expect(choice!.seed.playlistId, 'spotify-7');
    });

    testWidgets('an outside tap dismisses without choosing', (tester) async {
      PlaylistInspirationChoice? choice;
      var answered = false;
      await openPicker(
        tester,
        BrowseApi(),
        onChoice: (value) {
          choice = value;
          answered = true;
        },
      );

      await tester.tapAt(const Offset(400, 20));
      await tester.pumpAndSettle();

      expect(answered, isTrue);
      expect(choice, isNull);
      expect(find.text(PlaylistPicker.title), findsNothing);
    });

    testWidgets('Back dismisses without choosing', (tester) async {
      PlaylistInspirationChoice? choice;
      var answered = false;
      await openPicker(
        tester,
        BrowseApi(),
        onChoice: (value) {
          choice = value;
          answered = true;
        },
      );

      final sheet = tester.element(find.byKey(PlaylistPicker.sheetKey));
      Navigator.of(sheet).maybePop();
      await tester.pumpAndSettle();

      expect(answered, isTrue);
      expect(choice, isNull);
    });

    for (final brightness in Brightness.values) {
      testWidgets('draws at 320 and 200% text in ${brightness.name}', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 568);
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
              theme: brightness == Brightness.dark
                  ? MixtapeTheme.dark()
                  : MixtapeTheme.light(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: Consumer(
                builder: (context, ref, _) => Scaffold(
                  body: Center(
                    child: TextButton(
                      onPressed: () =>
                          showPlaylistInspirationPicker(context, ref),
                      child: const Text('Pick'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Pick'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        final sheet = tester.getRect(find.byKey(PlaylistPicker.sheetKey));
        expect(sheet.left, greaterThanOrEqualTo(0));
        expect(sheet.right, lessThanOrEqualTo(320));
        expect(sheet.bottom, lessThanOrEqualTo(568));
        expect(find.byKey(PlaylistPicker.excludeKey), findsOneWidget);
        final exclude = tester.getRect(find.byKey(PlaylistPicker.excludeKey));
        expect(exclude.bottom, lessThanOrEqualTo(sheet.bottom + 0.5));
      });
    }
  });
}
