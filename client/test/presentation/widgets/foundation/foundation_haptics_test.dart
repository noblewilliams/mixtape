import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/flush_row.dart';
import 'package:mixtape/presentation/widgets/foundation/haptics.dart';
import 'package:mixtape/presentation/widgets/foundation/idea_pill.dart';
import 'package:mixtape/presentation/widgets/foundation/label_chip.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_menu.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_sheet.dart';
import 'package:mixtape/presentation/widgets/foundation/segmented_toggle.dart';
import 'package:mixtape/presentation/widgets/foundation/tape_button.dart';
import 'package:mixtape/presentation/widgets/foundation/text_action.dart';

import '../../../helpers/haptic_recorder.dart';

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    theme: MixtapeTheme.light(),
    home: Scaffold(body: Center(child: child)),
  ),
);

void main() {
  testWidgets('each control feels like what it does', (tester) async {
    final played = recordHaptics(tester);
    await _pump(
      tester,
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TapeButton(label: 'Play', onPressed: () {}),
          TextAction(label: 'Edit', onPressed: () {}),
          IdeaPill(label: 'Rainy drive', onPressed: () {}),
          LabelChip(label: 'Calm', onPressed: () {}),
          TapeButton(
            label: 'Create playlist',
            haptic: HapticKind.commit,
            onPressed: () {},
          ),
        ],
      ),
    );

    await tester.tap(find.text('Play'));
    await tester.tap(find.text('Edit'));
    await tester.tap(find.text('Rainy drive'));
    await tester.tap(find.text('Calm'));
    await tester.tap(find.text('Create playlist'));

    expect(played, [
      HapticKind.primary,
      HapticKind.tap,
      HapticKind.suggest,
      HapticKind.select,
      HapticKind.commit,
    ]);
  });

  testWidgets('a disabled control plays nothing', (tester) async {
    final played = recordHaptics(tester);
    await _pump(tester, const TapeButton(label: 'Play'));
    await tester.tap(find.text('Play'));
    expect(played, isEmpty);
  });

  testWidgets('rows tap, segments select', (tester) async {
    final played = recordHaptics(tester);
    var value = 'a';
    await _pump(
      tester,
      StatefulBuilder(
        builder: (context, setState) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FlushRow(
              leading: const SizedBox.square(dimension: 20),
              title: 'Row',
              onTap: () {},
            ),
            SegmentedToggle<String>(
              options: const [
                SegmentedOption(value: 'a', label: 'Mixes'),
                SegmentedOption(value: 'b', label: 'Playlists'),
              ],
              value: value,
              onChanged: (v) => setState(() => value = v),
            ),
          ],
        ),
      ),
    );

    await tester.tap(find.text('Row'));
    await tester.tap(find.text('Playlists'));
    expect(played, [HapticKind.tap, HapticKind.select]);
  });

  testWidgets('a menu opens, picks, and dismisses with its own feel', (
    tester,
  ) async {
    final played = recordHaptics(tester);
    await _pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showMixtapeMenu<String>(
            context,
            actions: const [MixtapeMenuAction(label: 'Rename', value: 'r')],
          ),
          child: const Text('More'),
        ),
      ),
    );

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(mixtapeMenuBarrierKey), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(played, [
      HapticKind.open,
      HapticKind.select,
      HapticKind.open,
      HapticKind.dismiss,
    ]);
  });

  testWidgets('a destructive confirm warns', (tester) async {
    final played = recordHaptics(tester);
    await _pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showMixtapeConfirm<bool>(
            context,
            title: 'Delete 2 mixes?',
            actions: const [
              MixtapeConfirmAction(
                label: 'Delete',
                value: true,
                isDestructive: true,
              ),
              MixtapeConfirmAction(label: 'Cancel', value: false),
            ],
          ),
          child: const Text('Delete'),
        ),
      ),
    );

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();

    expect(played, [HapticKind.open, HapticKind.destructive]);
  });

  testWidgets('presenting a sheet opens', (tester) async {
    final played = recordHaptics(tester);
    await _pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showMixtapeSheet<void>(
            context,
            builder: (_) => const Text('Sheet'),
          ),
          child: const Text('Open'),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(played, [HapticKind.open]);
  });
}
