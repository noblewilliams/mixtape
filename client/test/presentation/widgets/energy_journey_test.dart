// The energy shape chip and its sheet (plan task 4.3; frame A1 and `.sheet` /
// `.preset` on `docs/mockups/2026-09-17-mobile-conversation-states.html`).
import '../../helpers/auth_ui_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/energy_journey.dart';

/// The snapshot theme (seeded colours, the synthetic font) plus the design
/// tokens every native widget reads off the ambient theme.
ThemeData nativeSnapshotTheme(Brightness brightness) =>
    authSnapshotTheme(brightness).copyWith(
      extensions: [
        brightness == Brightness.dark
            ? MixtapeTokens.dark
            : MixtapeTokens.light,
      ],
    );

void main() {
  testWidgets('captures the native energy sheet', (tester) async {
    await loadAuthSnapshotFonts(tester);
    tester.view.physicalSize = const Size(390, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController(text: 'Sunday, unhurried');
    await tester.pumpWidget(
      RepaintBoundary(
        key: authSnapshotKey,
        child: MaterialApp(
          theme: nativeSnapshotTheme(Brightness.dark),
          home: Scaffold(body: EnergyControl(controller: controller)),
        ),
      ),
    );
    await tester.tap(find.byKey(EnergyControl.chipKey));
    await tester.pumpAndSettle();
    expect(find.byKey(EnergyControl.sheetKey), findsOneWidget);
    await captureAuthSnapshot(tester, 'energy-native-dark');
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('the sheet draws the four shipped presets in the board order', (
    tester,
  ) async {
    final controller = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Scaffold(body: EnergyControl(controller: controller)),
      ),
    );
    await tester.tap(find.byKey(EnergyControl.chipKey));
    await tester.pumpAndSettle();

    expect(find.text('Give the mix a shape.'), findsOneWidget);
    expect(
      find.text('Adds a sentence to your brief. You still send it yourself.'),
      findsOneWidget,
    );
    for (final arc in EnergyArc.values) {
      expect(find.byKey(EnergyControl.presetKey(arc)), findsOneWidget);
      expect(find.text(arc.label), findsOneWidget);
      expect(find.text(arc.description), findsOneWidget);
    }
    final order = [
      for (final arc in EnergyArc.values)
        (arc, tester.getTopLeft(find.byKey(EnergyControl.presetKey(arc))).dy),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    expect([for (final entry in order) entry.$1], energyArcOrder);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('shape controls fit a short phone with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController(text: 'Sunday');
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(body: EnergyControl(controller: controller)),
      ),
    );
    await tester.tap(find.byKey(EnergyControl.chipKey));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(EnergyControl.confirmKey));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(EnergyControl.confirmKey));
    await tester.pumpAndSettle();
    expect(controller.text, contains('Build, then settle'));
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('choosing a shape only changes the brief after confirmation', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'Sunday morning');
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Scaffold(body: EnergyControl(controller: controller)),
      ),
    );
    await tester.tap(find.byKey(EnergyControl.chipKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(EnergyControl.presetKey(EnergyArc.fall)));
    await tester.pumpAndSettle();
    expect(controller.text, 'Sunday morning');
    await tester.tap(find.byKey(EnergyControl.confirmKey));
    await tester.pumpAndSettle();
    expect(controller.text, 'Sunday morning\nEnergy journey: Wind down.');
    expect(find.text('Shape added to your brief. Send when ready.'), findsOneWidget);

    await tester.tap(find.byKey(EnergyControl.chipKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(controller.text, 'Sunday morning\nEnergy journey: Wind down.');
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('a brief with no room for the sentence says so and cannot confirm', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'x' * 2000);
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Scaffold(body: EnergyControl(controller: controller)),
      ),
    );
    await tester.tap(find.byKey(EnergyControl.chipKey));
    await tester.pumpAndSettle();

    expect(find.byKey(EnergyControl.tooLongKey), findsOneWidget);
    expect(find.text('Shorten your brief to make room for the shape.'), findsOneWidget);
    await tester.tap(find.byKey(EnergyControl.confirmKey));
    await tester.pumpAndSettle();
    // Still open, nothing written.
    expect(find.byKey(EnergyControl.sheetKey), findsOneWidget);
    expect(controller.text, 'x' * 2000);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('a disabled chip cannot open the sheet', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Scaffold(
          body: EnergyControl(controller: controller, enabled: false),
        ),
      ),
    );
    await tester.tap(find.byKey(EnergyControl.chipKey));
    await tester.pumpAndSettle();
    expect(find.byKey(EnergyControl.sheetKey), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('a screen that draws the chip itself suppresses the composer copy', (
    tester,
  ) async {
    final controller = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Scaffold(
          body: EnergyControlVisibility(
            visible: false,
            child: EnergyControl(controller: controller),
          ),
        ),
      ),
    );
    expect(find.byKey(EnergyControl.chipKey), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  test('does not truncate the brief or keep stale preset lines', () {
    expect(
      energyBrief('Sunday\nEnergy journey: Steady.', EnergyArc.rise),
      'Sunday\nEnergy journey: Build gradually.',
    );
    expect(energyBrief('x' * 2000, EnergyArc.arc), isNull);
  });
}
