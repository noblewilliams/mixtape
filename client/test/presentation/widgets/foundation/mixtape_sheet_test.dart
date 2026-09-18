// The one modal-sheet presentation every sheet in the app goes through
// (smoke round two, note 4): full width, flush to the bottom edge, 20 pt top
// corners, an opaque panel and a lighter scrim than Material's own.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_sheet.dart';

Future<void> _open(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  EdgeInsets padding = EdgeInsets.zero,
  bool scrollControlled = false,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: brightness == Brightness.dark
          ? MixtapeTheme.dark()
          : MixtapeTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(padding: padding),
        child: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => showMixtapeSheet<void>(
                  context,
                  isScrollControlled: scrollControlled,
                  builder: (_) => const SizedBox(
                    height: 200,
                    child: Center(child: Text('Sheet body')),
                  ),
                ),
                child: const Text('open'),
              ),
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
  testWidgets('the sheet is full width and flush to the bottom edge', (
    tester,
  ) async {
    await _open(tester);

    expect(find.text('Sheet body'), findsOneWidget);
    final sheet = tester.getRect(find.byKey(MixtapeSheet.surfaceKey));
    expect(sheet.left, 0, reason: 'no side margin');
    expect(sheet.right, 390, reason: 'no side margin');
    expect(sheet.bottom, 844, reason: 'no floating gap under the sheet');
  });

  testWidgets('the sheet absorbs the bottom safe area itself', (tester) async {
    await _open(tester, padding: const EdgeInsets.only(bottom: 34));

    final sheet = tester.getRect(find.byKey(MixtapeSheet.surfaceKey));
    expect(sheet.bottom, 844, reason: 'the surface still reaches the edge');
    final body = tester.getRect(find.text('Sheet body'));
    expect(
      sheet.bottom - body.bottom,
      greaterThanOrEqualTo(34),
      reason: 'the content clears the home indicator',
    );
  });

  testWidgets('the scrim is the board’s lighter one in both themes', (
    tester,
  ) async {
    for (final (brightness, expected) in [
      (Brightness.light, MixtapeSheet.lightBarrier),
      (Brightness.dark, MixtapeSheet.darkBarrier),
    ]) {
      await _open(tester, brightness: brightness);
      final barriers = tester
          .widgetList<ModalBarrier>(find.byType(ModalBarrier))
          .where((barrier) => barrier.color != null)
          .toList();
      expect(barriers, isNotEmpty);
      expect(barriers.last.color, expected);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('the sheet carries one grab handle and rounded top corners', (
    tester,
  ) async {
    await _open(tester);

    expect(find.byKey(MixtapeSheet.handleKey), findsOneWidget);
    final material = tester.widget<Material>(
      find
          .ancestor(
            of: find.byKey(MixtapeSheet.surfaceKey),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(
      material.shape,
      const RoundedRectangleBorder(borderRadius: MixtapeSheet.radius),
    );
    expect(material.color?.a, 1, reason: 'the panel is opaque');
  });
}
