// The tape settings sheet (board section 3; locked record → Tape settings).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/tape_palette.dart';
import 'package:mixtape/presentation/widgets/tape_settings_dialog.dart';

class _Writes {
  final colours = <String>[];
  final names = <String>[];
  bool colourOk = true;
}

Future<_Writes> _open(
  WidgetTester tester, {
  String initialColor = '#617f9c',
  String title = 'Smooth Cruise',
  Brightness brightness = Brightness.light,
  bool colourOk = true,
}) async {
  final writes = _Writes()..colourOk = colourOk;
  await tester.pumpWidget(
    MaterialApp(
      theme: brightness == Brightness.dark
          ? MixtapeTheme.dark()
          : MixtapeTheme.light(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showTapeSettingsSheet(
                context,
                title: title,
                initialColor: initialColor,
                onSave: (colour) async {
                  writes.colours.add(colour);
                  return writes.colourOk;
                },
                onRename: (name) async {
                  writes.names.add(name);
                  return true;
                },
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
  return writes;
}

bool _selected(WidgetTester tester, String label) => tester
    .getSemantics(find.bySemanticsLabel(label))
    .flagsCollection
    .isSelected;

void main() {
  testWidgets('families are the palette in order, six each', (tester) async {
    expect(tapeFamilyNames, [
      'Reds',
      'Oranges',
      'Yellows',
      'Greens',
      'Teals',
      'Blues',
      'Purples',
      'Neutrals',
    ]);
    expect(tapeFamily(5).map((c) => c.$1), [
      'Sky',
      'Blue',
      'Cobalt',
      'Navy',
      'Denim',
      'Slate',
    ]);
    expect(tapeFamilyOf('#617F9C'), 5);
    expect(tapeFamilyOf('#000000'), isNull);
  });

  testWidgets('opens on the family of the colour shown, that colour selected', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _open(tester);

    expect(find.byKey(TapeSettingsSheet.sheetKey), findsOneWidget);
    expect(find.text('Tape'), findsOneWidget);
    expect(find.byKey(TapeSettingsSheet.nameFieldKey), findsOneWidget);
    for (final name in tapeFamilyNames) {
      expect(find.bySemanticsLabel(name), findsOneWidget);
    }
    expect(_selected(tester, 'Blues'), isTrue);
    expect(_selected(tester, 'Reds'), isFalse);
    for (final colour in ['Sky', 'Blue', 'Cobalt', 'Navy', 'Denim', 'Slate']) {
      expect(find.text(colour), findsOneWidget);
    }
    expect(_selected(tester, 'Denim'), isTrue);
    expect(find.text('Cherry'), findsNothing);
    handle.dispose();
  });

  testWidgets('the sheet is opaque in both themes', (tester) async {
    for (final brightness in Brightness.values) {
      await _open(tester, brightness: brightness);
      final material = tester.widget<Material>(
        find.byKey(TapeSettingsSheet.sheetKey),
      );
      expect(material.color!.a, 1.0, reason: '$brightness');
      await tester.tap(find.byKey(TapeSettingsSheet.doneKey));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('a family swatch shows its six cassettes', (tester) async {
    await _open(tester);
    await tester.tap(find.byKey(TapeSettingsSheet.familyKey(0)));
    await tester.pumpAndSettle();
    for (final colour in ['Rose', 'Cherry', 'Crimson', 'Wine', 'Coral']) {
      expect(find.text(colour), findsOneWidget);
    }
    expect(find.text('Denim'), findsNothing);
  });

  testWidgets('picking a colour saves at once; Done only closes', (
    tester,
  ) async {
    final writes = await _open(tester);
    await tester.tap(find.text('Navy'));
    await tester.pumpAndSettle();
    expect(writes.colours, ['#293e6c']);
    expect(find.byKey(TapeSettingsSheet.sheetKey), findsOneWidget);

    await tester.tap(find.byKey(TapeSettingsSheet.doneKey));
    await tester.pumpAndSettle();
    expect(writes.colours, ['#293e6c']);
    expect(writes.names, isEmpty);
    expect(find.byKey(TapeSettingsSheet.sheetKey), findsNothing);
  });

  testWidgets('a refused colour says so and stays retryable', (tester) async {
    final writes = await _open(tester, colourOk: false);
    await tester.tap(find.text('Navy'));
    await tester.pumpAndSettle();
    expect(find.text('Couldn’t save tape colour. Try again.'), findsOneWidget);

    writes.colourOk = true;
    await tester.tap(find.text('Navy'));
    await tester.pumpAndSettle();
    expect(writes.colours, ['#293e6c', '#293e6c']);
    expect(find.text('Couldn’t save tape colour. Try again.'), findsNothing);
  });

  testWidgets('a changed name is saved when the sheet closes', (tester) async {
    final writes = await _open(tester);
    await tester.enterText(
      find.byKey(TapeSettingsSheet.nameFieldKey),
      '  Lekki drive ',
    );
    await tester.tap(find.byKey(TapeSettingsSheet.doneKey));
    await tester.pumpAndSettle();
    expect(writes.names, ['Lekki drive']);
    expect(writes.colours, isEmpty);
  });
}
