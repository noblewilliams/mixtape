// The Listen later shelf row (album picks Task 13; frames L1 and L2 in
// `docs/mockups/2026-10-20-album-picks-states.html`).
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/album_card.dart' show AlbumCover;
import 'package:mixtape/presentation/widgets/foundation/flush_row.dart';
import 'package:mixtape/presentation/widgets/foundation/remove_band.dart';
import 'package:mixtape/presentation/widgets/foundation/status_word.dart';
import 'package:mixtape/presentation/widgets/listen_later_row.dart';

ListenLaterEntry _entry({
  String id = 'a1',
  String title = 'Low Tide Hours',
  String artist = 'Mara Ilesanmi',
  String type = 'album',
  int? releaseYear = 2019,
  String? sessionId = 's1',
  DateTime? listenedAt,
  String? reason = 'A live record, warm and unhurried.',
}) => ListenLaterEntry(
  id: id,
  title: title,
  artist: artist,
  type: type,
  releaseYear: releaseYear,
  sessionId: sessionId,
  savedAt: DateTime(2026, 10, 1),
  listenedAt: listenedAt,
  reason: reason,
);

Future<void> _pump(
  WidgetTester tester,
  Widget row, {
  Brightness brightness = Brightness.light,
}) => tester.pumpWidget(
  MaterialApp(
    theme: brightness == Brightness.dark
        ? MixtapeTheme.dark()
        : MixtapeTheme.light(),
    home: Scaffold(body: ListView(children: [row])),
  ),
);

List<String> _rotor(WidgetTester tester, String id) {
  final data = tester
      .getSemantics(find.byKey(ListenLaterRow.semanticsKey(id)))
      .getSemanticsData();
  return [
    for (final actionId in data.customSemanticsActionIds ?? const <int>[])
      CustomSemanticsAction.getAction(actionId)!.label!,
  ];
}

void main() {
  group('formatting', () {
    test('the listened date is day and short month, no leading zero', () {
      expect(listenedDateLabel(DateTime(2026, 10, 2)), '2 Oct');
      expect(listenedDateLabel(DateTime(2026, 5, 12)), '12 May');
      expect(listenedSpokenDate(DateTime(2026, 9, 7)), '7 September');
    });

    test('the subtitle omits a null year', () {
      expect(listenLaterSubtitle(_entry()), 'Mara Ilesanmi · Album · 2019');
      expect(
        listenLaterSubtitle(_entry(releaseYear: null, type: 'ep')),
        'Mara Ilesanmi · EP',
      );
    });

    test('the row label reads title, artist, type and the listened date', () {
      expect(
        listenLaterRowLabel(_entry()),
        'Low Tide Hours, Mara Ilesanmi, album, 2019',
      );
      expect(
        listenLaterRowLabel(
          _entry(type: 'ep', listenedAt: DateTime(2026, 10, 12)),
        ),
        'Low Tide Hours, Mara Ilesanmi, EP, 2019, listened 12 October',
      );
    });
  });

  testWidgets('unlistened: cover in the 60 pt tile, subtitle, chevron, '
      'tap opens', (tester) async {
    var opens = 0;
    await _pump(
      tester,
      ListenLaterRow(entry: _entry(), onOpen: () => opens++, isFirst: true),
    );
    expect(find.byType(AlbumCover), findsOneWidget);
    expect(tester.getSize(find.byType(AlbumCover)), const Size(60, 60));
    expect(find.text('Low Tide Hours'), findsOneWidget);
    expect(find.text('Mara Ilesanmi · Album · 2019'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    expect(find.byType(StatusWord), findsNothing);
    expect(find.text('New to you'), findsNothing);

    await tester.tap(find.text('Low Tide Hours'));
    expect(opens, 1);
  });

  testWidgets('listened: muted, plum status word with the date', (
    tester,
  ) async {
    await _pump(
      tester,
      ListenLaterRow(
        entry: _entry(type: 'ep', listenedAt: DateTime(2026, 10, 12)),
        onOpen: () {},
      ),
    );
    final word = tester.widget<StatusWord>(find.byType(StatusWord));
    expect(word.label, 'Listened 12 Oct');
    expect(word.kind, StatusKind.accent);
    expect(word.icon, isFalse);
    expect(find.textContaining('Mara Ilesanmi · EP'), findsOneWidget);
    expect(find.textContaining('2019'), findsNothing);
    final context = tester.element(find.text('Low Tide Hours'));
    expect(
      tester.widget<Text>(find.text('Low Tide Hours')).style?.color ??
          DefaultTextStyle.of(context).style.color,
      context.tokens.muted,
    );
  });

  testWidgets('long-press expands why, Saved from and Mark listened; '
      'again collapses', (tester) async {
    var marks = 0;
    await _pump(
      tester,
      ListenLaterRow(
        entry: _entry(),
        savedFrom: 'Something new, warm',
        onOpen: () {},
        onMarkListened: () async => marks++,
      ),
    );
    expect(find.textContaining('warm and unhurried'), findsNothing);

    await tester.longPress(find.text('Low Tide Hours'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'A live record, warm and unhurried. '
        'Saved from "Something new, warm".',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Mark listened'));
    await tester.pump();
    expect(marks, 1);

    await tester.longPress(find.text('Low Tide Hours'));
    await tester.pumpAndSettle();
    expect(find.textContaining('warm and unhurried'), findsNothing);
    expect(find.text('Mark listened'), findsNothing);
  });

  testWidgets('expanded without a reason or a known prompt; listened rows '
      'offer no Mark listened', (tester) async {
    await _pump(
      tester,
      ListenLaterRow(
        entry: _entry(reason: null, listenedAt: DateTime(2026, 10, 2)),
        onOpen: () {},
        onMarkListened: () async {},
      ),
    );
    await tester.longPress(find.text('Low Tide Hours'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Saved from'), findsNothing);
    expect(find.text('Mark listened'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no session: no tap action and no chevron', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, ListenLaterRow(entry: _entry(sessionId: null)));
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.byType(InkWell), findsNothing);
    expect(_rotor(tester, 'a1'), isNot(contains('Open')));
    handle.dispose();
  });

  testWidgets('rotor actions: Open, Show why, Mark listened, Remove', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      ListenLaterRow(
        entry: _entry(),
        onOpen: () {},
        onMarkListened: () async {},
        onRemove: () async {},
      ),
    );
    expect(_rotor(tester, 'a1'), [
      'Open',
      'Show why',
      'Mark listened',
      'Remove',
    ]);
    final data = tester
        .getSemantics(find.byKey(ListenLaterRow.semanticsKey('a1')))
        .getSemanticsData();
    expect(data.label, 'Low Tide Hours, Mara Ilesanmi, album, 2019');

    // Show why expands the row in place.
    tester.semantics.customAction(
      find.semantics.byLabel('Low Tide Hours, Mara Ilesanmi, album, 2019'),
      const CustomSemanticsAction(label: 'Show why'),
    );
    await tester.pumpAndSettle();
    expect(find.text('Mark listened'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('listened rows drop Mark listened from the rotor', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      ListenLaterRow(
        entry: _entry(listenedAt: DateTime(2026, 10, 12)),
        onOpen: () {},
        onMarkListened: () async {},
        onRemove: () async {},
      ),
    );
    expect(_rotor(tester, 'a1'), ['Open', 'Show why', 'Remove']);
    handle.dispose();
  });

  testWidgets('swipe left calls remove and keeps the row for the parent', (
    tester,
  ) async {
    var removes = 0;
    await _pump(
      tester,
      ListenLaterRow(
        entry: _entry(),
        onOpen: () {},
        onRemove: () async => removes++,
      ),
    );
    await tester.drag(find.byType(Dismissible), const Offset(-700, 0));
    await tester.pumpAndSettle();
    expect(removes, 1);
    expect(find.text('Low Tide Hours'), findsOneWidget);
  });

  test('the row label omits an unknown year', () {
    expect(
      listenLaterRowLabel(_entry(releaseYear: null)),
      'Low Tide Hours, Mara Ilesanmi, album',
    );
  });

  testWidgets('the swipe shows the arrangement screen\'s Remove band, and '
      'reduced motion drops its movement', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: ListView(
              children: [
                ListenLaterRow(
                  entry: _entry(),
                  onOpen: () {},
                  onRemove: () async {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final dismissible = tester.widget<Dismissible>(find.byType(Dismissible));
    expect(dismissible.background, isA<RemoveBand>());
    expect(dismissible.movementDuration, Duration.zero);
  });

  testWidgets('dark theme builds every state', (tester) async {
    await _pump(
      tester,
      Column(
        children: [
          ListenLaterRow(entry: _entry(), onOpen: () {}, isFirst: true),
          ListenLaterRow(
            entry: _entry(id: 'a2', listenedAt: DateTime(2026, 10, 12)),
            onOpen: () {},
          ),
          ListenLaterRow(entry: _entry(id: 'a3', sessionId: null)),
        ],
      ),
      brightness: Brightness.dark,
    );
    await tester.longPress(find.text('Low Tide Hours').first);
    await tester.pumpAndSettle();
    expect(find.byType(FlushRow), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });
}
