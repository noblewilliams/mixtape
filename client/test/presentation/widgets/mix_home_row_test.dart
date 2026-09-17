import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/screens/mix_history_screen.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/presentation/widgets/foundation/flush_row.dart';
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
  testWidgets('long-press opens the actions menu on a chevron row', (
    tester,
  ) async {
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

    // The approved row: a chevron, no visible more button.
    expect(find.byKey(const ValueKey('mix-actions-one')), findsNothing);
    expect(
      find.descendant(
        of: find.byType(FlushRow),
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsOneWidget,
    );

    await tester.longPress(find.text('Sunday'));
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Version history'), findsOneWidget);
    expect(find.text('Archive'), findsOneWidget);

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

  testWidgets(
    'successful swipe can leave row mounted without dismissal assertion',
    (tester) async {
      var archives = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MixHomeRow(
              session: session,
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
      await tester.drag(find.byType(Dismissible), const Offset(-700, 0));
      await tester.pumpAndSettle();
      expect(archives, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
