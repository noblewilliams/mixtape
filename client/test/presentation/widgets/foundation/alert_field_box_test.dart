// Text fields inside a Cupertino alert (device smoke 2026-11-13): the alert
// measured the field short and scrolled its own content.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/alert_field_box.dart';

Future<void> _open(WidgetTester tester, {double textScale = 1}) async {
  tester.view.physicalSize = const Size(393, 852);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: MixtapeTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(
          size: const Size(393, 852),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showCupertinoDialog<void>(
                context: context,
                builder: (_) => CupertinoAlertDialog(
                  title: const Text('Create playlist'),
                  content: const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(height: 14),
                      AlertFieldBox(
                        child: CupertinoTextField(placeholder: 'Name'),
                      ),
                      SizedBox(height: 10),
                      AlertFieldBox(
                        child: CupertinoTextField(placeholder: 'Your name'),
                      ),
                    ],
                  ),
                  actions: [
                    CupertinoDialogAction(
                      onPressed: () {},
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  for (final scale in [1.0, 1.6]) {
    testWidgets('an alert with fields fits them without scrolling at ${scale}x', (
      tester,
    ) async {
      await _open(tester, textScale: scale);
      for (final scrollable in tester.stateList<ScrollableState>(
        find.byType(Scrollable),
      )) {
        expect(scrollable.position.maxScrollExtent, 0);
      }
      expect(tester.takeException(), isNull);
      // Each field's line of text sits wholly inside its box.
      final boxes = find.byType(AlertFieldBox);
      for (var i = 0; i < 2; i++) {
        final box = tester.getRect(boxes.at(i));
        final text = tester.getRect(
          find.descendant(of: boxes.at(i), matching: find.byType(EditableText)),
        );
        expect(text.top, greaterThanOrEqualTo(box.top));
        expect(text.bottom, lessThanOrEqualTo(box.bottom));
      }
    });
  }
}
