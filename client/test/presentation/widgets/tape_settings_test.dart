import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/tape_settings_dialog.dart';

void main() {
  testWidgets(
    'colour remains retryable after failure and writes only on Done',
    (tester) async {
      final writes = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: MixtapeTheme.light(),
          home: Scaffold(
            body: TapeSettingsDialog(
              title: 'Sunday',
              initialColor: '#d88c9a',
              onSave: (color) async {
                writes.add(color);
                return false;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Ink'));
      await tester.pump();
      expect(writes, isEmpty);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(writes, ['#282a35']);
      expect(
        find.text('Couldn’t save tape colour. Try again.'),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Rose'));
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(writes, ['#282a35', '#d88c9a']);
    },
  );
}
