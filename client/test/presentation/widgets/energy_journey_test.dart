// The energy shape chip and its sheet (plan task 4.3; frame A1 and `.sheet` /
// `.preset` on `docs/mockups/2026-09-17-mobile-conversation-states.html`).
import '../../helpers/auth_ui_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/energy_journey.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_sheet.dart';

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

/// Home's half of the contract: the chip's state lives above it, and the
/// draft is never written to (smoke round three, note 5).
class _ChipHost extends StatefulWidget {
  const _ChipHost({required this.controller, this.initial});

  final TextEditingController controller;
  final EnergyArc? initial;

  @override
  State<_ChipHost> createState() => _ChipHostState();
}

class _ChipHostState extends State<_ChipHost> {
  late EnergyArc? arc = widget.initial;

  @override
  Widget build(BuildContext context) => EnergyControl(
    controller: widget.controller,
    selectedArc: arc,
    onArcChanged: (next) => setState(() => arc = next),
  );
}

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
      find.text(energySheetBlurb),
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

  testWidgets('every preset is one VoiceOver can activate', (tester) async {
    final handle = tester.ensureSemantics();
    final controller = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Scaffold(body: EnergyControl(controller: controller)),
      ),
    );
    await tester.tap(find.byKey(EnergyControl.chipKey));
    await tester.pumpAndSettle();

    for (final arc in EnergyArc.values) {
      final data = tester
          .getSemantics(
            find.bySemanticsLabel('${arc.label}. ${arc.description}'),
          )
          .getSemanticsData();
      expect(
        data.hasAction(SemanticsAction.tap),
        isTrue,
        reason: '${arc.label}: a node with no tap action cannot be activated '
            'by VoiceOver',
      );
      expect(data.flagsCollection.isButton, isTrue);
    }

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    handle.dispose();
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
        home: Scaffold(body: _ChipHost(controller: controller)),
      ),
    );
    await tester.tap(find.byKey(EnergyControl.chipKey));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(EnergyControl.confirmKey));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(EnergyControl.confirmKey));
    await tester.pumpAndSettle();
    expect(controller.text, 'Sunday', reason: 'the draft is never written to');
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('a chosen shape lands on the chip, not in the field', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'Sunday morning');
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Scaffold(body: _ChipHost(controller: controller)),
      ),
    );
    expect(find.text(EnergyControl.unsetLabel), findsOneWidget);

    await tester.tap(find.byKey(EnergyControl.chipKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(EnergyControl.presetKey(EnergyArc.fall)));
    await tester.pumpAndSettle();
    expect(controller.text, 'Sunday morning');
    await tester.tap(find.byKey(EnergyControl.confirmKey));
    await tester.pumpAndSettle();

    // The chip wears the arc; the draft is untouched and nothing toasts.
    expect(find.text(EnergyArc.fall.label), findsOneWidget);
    expect(find.text(EnergyControl.unsetLabel), findsNothing);
    expect(controller.text, 'Sunday morning');
    expect(find.text(energyShapeToast), findsNothing);

    // Reopening preselects it, and Cancel changes nothing.
    await tester.tap(find.byKey(EnergyControl.chipKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text(EnergyArc.fall.label), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('Clear only appears with a shape set, and takes it off', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'Sunday morning');
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Scaffold(body: _ChipHost(controller: controller)),
      ),
    );
    await tester.tap(find.byKey(EnergyControl.chipKey));
    await tester.pumpAndSettle();
    expect(
      find.byKey(EnergyControl.clearKey),
      findsNothing,
      reason: 'nothing to clear yet',
    );
    await tester.tap(find.byKey(EnergyControl.presetKey(EnergyArc.rise)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(EnergyControl.confirmKey));
    await tester.pumpAndSettle();
    expect(find.text(EnergyArc.rise.label), findsOneWidget);

    await tester.tap(find.byKey(EnergyControl.chipKey));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(EnergyControl.clearKey));
    await tester.pumpAndSettle();

    expect(find.text(EnergyControl.unsetLabel), findsOneWidget);
    expect(find.text(EnergyArc.rise.label), findsNothing);
    expect(controller.text, 'Sunday morning');

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('the sheet opens on the shape the chip is already wearing', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'Sunday morning');
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Scaffold(
          body: _ChipHost(controller: controller, initial: EnergyArc.steady),
        ),
      ),
    );
    await tester.tap(find.byKey(EnergyControl.chipKey));
    await tester.pumpAndSettle();
    // Confirming without touching a preset keeps the current shape.
    await tester.tap(find.byKey(EnergyControl.confirmKey));
    await tester.pumpAndSettle();
    expect(find.text(EnergyArc.steady.label), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('Cancel sits at the left edge and the tape button at the right', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController(text: 'Sunday morning');
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Scaffold(body: EnergyControl(controller: controller)),
      ),
    );
    await tester.tap(find.byKey(EnergyControl.chipKey));
    await tester.pumpAndSettle();

    final sheet = tester.getRect(find.byKey(EnergyControl.sheetKey));
    final cancel = tester.getRect(find.text('Cancel'));
    final confirm = tester.getRect(find.byKey(EnergyControl.confirmKey));
    expect(cancel.center.dx, lessThan(sheet.center.dx));
    expect(confirm.center.dx, greaterThan(sheet.center.dx));

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('the shape sheet is opaque, full width and bottom flush', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController(text: 'Sunday morning');
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Scaffold(body: EnergyControl(controller: controller)),
      ),
    );
    await tester.tap(find.byKey(EnergyControl.chipKey));
    await tester.pumpAndSettle();

    final surface = tester.getRect(find.byKey(MixtapeSheet.surfaceKey));
    expect(surface.left, 0);
    expect(surface.right, 390);
    expect(surface.bottom, 844);
    final barrier = tester
        .widgetList<ModalBarrier>(find.byType(ModalBarrier))
        .where((b) => b.color != null)
        .last;
    expect(barrier.color, MixtapeSheet.lightBarrier);

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
