import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/screens/mix_history_screen.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/presentation/widgets/foundation/cassette_tile.dart';
import 'package:mixtape/presentation/widgets/foundation/flush_row.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_menu.dart';
import 'package:mixtape/presentation/widgets/mix_home_row.dart';

void main() {
  final session = DjSession(
    id: 'one',
    title: 'Sunday',
    status: 'active',
    queueVersion: 1,
    updatedAt: DateTime(2026),
  );
  testWidgets('row opens; menu renames without opening, retains failed draft', (
    tester,
  ) async {
    var opens = 0;
    final names = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MixHomeRow(
            session: session,
            // The trailing actions button is opt-in since task 2.2; these two
            // cases drive the menu through it rather than the long-press.
            showActionsButton: true,
            onOpen: () => opens++,
            onRename: (name) async {
              names.add(name);
              return names.length > 1;
            },
            onArchive: () async => true,
            onRestore: () async => true,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Sunday'));
    expect(opens, 1);
    await tester.tap(find.byTooltip('Mix actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Monday');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Monday'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(names, ['Monday', 'Monday']);
    expect(opens, 1);
  });
  testWidgets('Escape cancels rename and vertical drag never archives', (
    tester,
  ) async {
    var writes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MixHomeRow(
            session: session,
            showActionsButton: true,
            onOpen: () {},
            onRename: (_) async {
              writes++;
              return true;
            },
            onArchive: () async {
              writes++;
              return true;
            },
            onRestore: () async => true,
          ),
        ),
      ),
    );
    await tester.drag(find.text('Sunday'), const Offset(0, -100));
    await tester.pumpAndSettle();
    expect(writes, 0);
    await tester.tap(find.byTooltip('Mix actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Changed');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(writes, 0);
    expect(find.text('Sunday'), findsOneWidget);
  });
  testWidgets('long-press opens the actions menu on a row', (tester) async {
    var history = 0;
    var archives = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MixHomeRow(
            session: session,
            showActionsButton: false,
            onVersionHistory: () => history++,
            onOpen: () {},
            onRename: (_) async => true,
            onArchive: () async {
              archives++;
              return true;
            },
            onRestore: () async => true,
          ),
        ),
      ),
    );

    // No chevron (founder, 2026-11-09) and no visible more button.
    expect(find.byKey(const ValueKey('mix-actions-one')), findsNothing);
    expect(
      find.descendant(
        of: find.byType(FlushRow),
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsNothing,
    );

    await tester.longPress(find.text('Sunday'));
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Version history'), findsOneWidget);
    expect(find.text('Archive'), findsOneWidget);
    // The row lifts over the dim, in place, and the menu sits under it.
    final lift = find.byKey(mixtapeMenuLiftKey);
    expect(
      find.descendant(of: lift, matching: find.text('Sunday')),
      findsOneWidget,
    );
    expect(
      tester.getRect(lift).center,
      tester.getRect(find.byType(FlushRow).first).center,
    );
    expect(
      tester.getTopLeft(find.byKey(mixtapeMenuKey)).dy,
      greaterThanOrEqualTo(tester.getBottomLeft(lift).dy),
    );

    await tester.tap(find.text('Version history'));
    await tester.pumpAndSettle();
    expect(history, 1);
    expect(archives, 0);

    await tester.longPress(find.text('Sunday'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    expect(archives, 1);
  });

  testWidgets('Version history pushes the history screen by default', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: MixHomeRow(
              session: session,
              showActionsButton: false,
              onOpen: () {},
              onRename: (_) async => true,
              onArchive: () async => true,
              onRestore: () async => true,
            ),
          ),
        ),
      ),
    );
    await tester.longPress(find.text('Sunday'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Version history'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final screen = tester.widget<MixHistoryScreen>(
      find.byType(MixHistoryScreen),
    );
    expect(screen.sessionId, 'one');
  });

  group('swipe', () {
    Future<void> pumpSwipeRow(
      WidgetTester tester, {
      required Future<bool> Function() onArchive,
      Future<bool> Function()? onRestore,
      DjSession? row,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MixHomeRow(
            session: row ?? session,
            onOpen: () {},
            onRename: (_) async => true,
            onArchive: onArchive,
            onRestore: onRestore ?? () async => true,
          ),
        ),
      ),
    );

    testWidgets('a swipe opens More and Archive and waits; nothing is '
        'archived until Archive is tapped', (tester) async {
      var archives = 0;
      await pumpSwipeRow(
        tester,
        onArchive: () async {
          archives++;
          return true;
        },
      );
      await tester.drag(find.text('Sunday'), const Offset(-140, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(MixHomeRow.moreActionKey('one')), findsOneWidget);
      expect(find.byKey(MixHomeRow.archiveActionKey('one')), findsOneWidget);
      expect(archives, 0);

      await tester.tap(find.byKey(MixHomeRow.archiveActionKey('one')));
      await tester.pumpAndSettle();
      expect(archives, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('More opens the row menu', (tester) async {
      await pumpSwipeRow(tester, onArchive: () async => true);
      await tester.drag(find.text('Sunday'), const Offset(-140, 0));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(MixHomeRow.moreActionKey('one')));
      await tester.pumpAndSettle();
      expect(find.byKey(mixtapeMenuKey), findsOneWidget);
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Archive'), findsWidgets);
    });

    testWidgets('a full swipe archives on its own', (tester) async {
      var archives = 0;
      await pumpSwipeRow(
        tester,
        onArchive: () async {
          archives++;
          return true;
        },
      );
      await tester.drag(find.text('Sunday'), const Offset(-700, 0));
      await tester.pumpAndSettle();
      expect(archives, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an archived row swipes to Unarchive', (tester) async {
      var restores = 0;
      await pumpSwipeRow(
        tester,
        row: DjSession(
          id: 'one',
          title: 'Sunday',
          status: 'archived',
          queueVersion: 1,
          updatedAt: DateTime(2026),
        ),
        onArchive: () async => true,
        onRestore: () async {
          restores++;
          return true;
        },
      );
      await tester.drag(find.text('Sunday'), const Offset(-140, 0));
      await tester.pumpAndSettle();
      expect(find.text('Unarchive'), findsOneWidget);

      await tester.tap(find.byKey(MixHomeRow.archiveActionKey('one')));
      await tester.pumpAndSettle();
      expect(restores, 1);
    });
  });

  group('album session', () {
    final album = DjSession(
      id: 'alb',
      title: 'Something new, warm',
      status: 'active',
      queueVersion: 2,
      updatedAt: DateTime(2026),
      kind: SessionKind.album,
      pick: const AlbumSummary(
        title: 'Kitchen Radio Sessions',
        artist: 'Odun & the Weather',
      ),
    );

    Future<void> pumpRow(WidgetTester tester, DjSession s) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MixHomeRow(
            session: s,
            onOpen: () {},
            onRename: (_) async => true,
            onCaseColor: (_) async => true,
            onArchive: () async => true,
            onRestore: () async => true,
          ),
        ),
      ),
    );

    testWidgets('the long-press menu offers Rename and Archive only', (
      tester,
    ) async {
      await pumpRow(tester, album);
      await tester.longPress(find.text('Something new, warm'));
      await tester.pumpAndSettle();
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Archive'), findsOneWidget);
      expect(find.text('Version history'), findsNothing);
      expect(find.text('Tape settings'), findsNothing);
    });

    testWidgets('the subtitle is the pick, and the tile stays a cassette', (
      tester,
    ) async {
      await pumpRow(tester, album);
      expect(
        find.text('Kitchen Radio Sessions · Odun & the Weather'),
        findsOneWidget,
      );
      expect(find.byType(CassetteTile), findsOneWidget);
    });

    testWidgets('before its first pick the subtitle is the relative time', (
      tester,
    ) async {
      await pumpRow(
        tester,
        DjSession(
          id: 'alb2',
          title: 'Loud and strange',
          status: 'active',
          queueVersion: 0,
          updatedAt: DateTime(2026),
          kind: SessionKind.album,
        ),
      );
      expect(find.textContaining(' · '), findsNothing);
      expect(find.text('Loud and strange'), findsOneWidget);
    });
  });
}
