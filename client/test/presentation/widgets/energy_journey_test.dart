import '../../helpers/auth_ui_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/widgets/energy_journey.dart';

void main() {
  testWidgets('captures the native energy picker', (tester) async {
    await loadAuthSnapshotFonts(tester);
    tester.view.physicalSize = const Size(390,780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController(text:'Sunday, unhurried');
    await tester.pumpWidget(RepaintBoundary(key:authSnapshotKey,child:MaterialApp(theme:authSnapshotTheme(Brightness.dark),home:Scaffold(body:EnergyControl(controller:controller)))));
    await tester.tap(find.text('Energy journey')); await tester.pumpAndSettle();
    await captureAuthSnapshot(tester,'energy-native-dark');
    await tester.pumpWidget(const SizedBox()); controller.dispose();
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
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF544451),
          brightness: Brightness.dark,
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(body: EnergyControl(controller: controller)),
      ),
    );
    await tester.tap(find.text('Energy journey'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Use this shape'));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Use this shape'));
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
        home: Scaffold(body: EnergyControl(controller: controller)),
      ),
    );
    await tester.tap(find.text('Energy journey'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wind down'));
    await tester.pumpAndSettle();
    expect(controller.text, 'Sunday morning');
    await tester.tap(find.text('Use this shape'));
    await tester.pumpAndSettle();
    expect(controller.text, 'Sunday morning\nEnergy journey: Wind down.');
    await tester.tap(find.text('Energy journey'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(controller.text, 'Sunday morning\nEnergy journey: Wind down.');
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
