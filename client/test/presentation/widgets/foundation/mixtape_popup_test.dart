import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_popup.dart';

void main() {
  // A pop-up with a field (Save as playlist, 2026-11-22) must sit above the
  // keyboard, not centred on the whole screen behind it.
  testWidgets('the pop-up rises clear of the keyboard', (tester) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    tester.view.viewInsets = const FakeViewPadding(bottom: 336);

    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Scaffold(
          resizeToAvoidBottomInset: false,
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showMixtapePopup<void>(
                context,
                label: 'Test',
                builder: (_) => const SizedBox(height: 200),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final surface = tester.getRect(find.byKey(MixtapePopup.surfaceKey));
    expect(surface.bottom, lessThanOrEqualTo(852 - 336));
  });
}
