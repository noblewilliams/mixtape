// The energy shape chip and its popover (board revision 3, section 5: "Shape
// on Home" on `docs/mockups/2026-11-03-mix-conversation-redesign.html`).
import '../../helpers/auth_ui_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/energy_journey.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_feedback.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_menu.dart';
import 'package:mixtape/presentation/widgets/mix_prompt_input.dart';

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

Future<void> _pumpChip(
  WidgetTester tester,
  TextEditingController controller, {
  EnergyArc? initial,
  ThemeData? theme,
  double textScale = 1,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? MixtapeTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 120),
            child: _ChipHost(controller: controller, initial: initial),
          ),
        ),
      ),
    ),
  );
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(EnergyControl.chipKey));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('captures the native energy menu', (tester) async {
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
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 120),
                child: _ChipHost(
                  controller: controller,
                  initial: EnergyArc.fall,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _openMenu(tester);
    expect(find.byKey(mixtapeMenuKey), findsOneWidget);
    await captureAuthSnapshot(tester, 'energy-native-dark');
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('the popover lists the four shapes with curves, in board order', (
    tester,
  ) async {
    final controller = TextEditingController();
    await _pumpChip(tester, controller);
    await _openMenu(tester);

    // Anchored to the chip: it sits near the bottom, so the menu opens above.
    final menu = tester.getRect(find.byKey(mixtapeMenuKey));
    final chip = tester.getRect(find.byKey(EnergyControl.chipKey));
    expect(menu.bottom, lessThanOrEqualTo(chip.top));

    for (final arc in EnergyArc.values) {
      final row = find.byKey(EnergyControl.presetKey(arc));
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.text(arc.label)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.text(arc.description)),
        findsOneWidget,
      );
      final glyph = tester.widget<EnergyShapeGlyph>(
        find.descendant(of: row, matching: find.byType(EnergyShapeGlyph)),
      );
      expect(glyph.arc, arc);
    }
    final order = [
      for (final arc in EnergyArc.values)
        (arc, tester.getTopLeft(find.byKey(EnergyControl.presetKey(arc))).dy),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    expect([for (final entry in order) entry.$1], energyArcOrder);
    expect(energyArcOrder, [
      EnergyArc.steady,
      EnergyArc.rise,
      EnergyArc.fall,
      EnergyArc.arc,
    ]);
    // Nothing set, nothing to clear; no confirm step and no Cancel row.
    expect(find.byKey(EnergyControl.clearKey), findsNothing);
    expect(find.text('Use this shape'), findsNothing);
    expect(find.text('Cancel'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('every shape reads its name, state and subtitle to VoiceOver', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final controller = TextEditingController();
    await _pumpChip(tester, controller, initial: EnergyArc.fall);
    await _openMenu(tester);

    for (final arc in EnergyArc.values) {
      final data = tester
          .getSemantics(find.byKey(EnergyControl.presetKey(arc)))
          .getSemanticsData();
      expect(data.label, '${arc.label}. ${arc.description}');
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      expect(data.flagsCollection.isButton, isTrue);
      expect(data.flagsCollection.isSelected, arc == EnergyArc.fall);
    }

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    handle.dispose();
  });

  testWidgets(
    'picking a shape applies it at once, on the chip, not the field',
    (tester) async {
      final controller = TextEditingController(text: 'Sunday morning');
      await _pumpChip(tester, controller);
      expect(find.text(EnergyControl.unsetLabel), findsOneWidget);

      await _openMenu(tester);
      await tester.tap(find.byKey(EnergyControl.presetKey(EnergyArc.fall)));
      await tester.pumpAndSettle();

      // Closed, and the chip wears the shape's name and curve.
      expect(find.byKey(mixtapeMenuKey), findsNothing);
      expect(find.text(EnergyArc.fall.label), findsOneWidget);
      expect(find.text(EnergyControl.unsetLabel), findsNothing);
      final chipGlyph = tester.widget<EnergyShapeGlyph>(
        find.descendant(
          of: find.byKey(EnergyControl.chipKey),
          matching: find.byType(EnergyShapeGlyph),
        ),
      );
      expect(chipGlyph.arc, EnergyArc.fall);
      expect(controller.text, 'Sunday morning');
      expect(find.text(energyShapeToast), findsNothing);

      // Reopening ticks it; tapping outside changes nothing.
      await _openMenu(tester);
      expect(
        find.descendant(
          of: find.byKey(EnergyControl.presetKey(EnergyArc.fall)),
          matching: find.byKey(MixtapeMenuItem.tickKey),
        ),
        findsOneWidget,
      );
      await tester.tapAt(const Offset(380, 10));
      await tester.pumpAndSettle();
      expect(find.text(EnergyArc.fall.label), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets('Clear shape only appears with a shape set, and takes it off', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'Sunday morning');
    await _pumpChip(tester, controller, initial: EnergyArc.rise);
    await _openMenu(tester);

    final clear = find.byKey(EnergyControl.clearKey);
    expect(clear, findsOneWidget);
    expect(find.text(energyClearShapeLabel), findsOneWidget);
    // The last row, behind the group gap.
    expect(
      tester.getTopLeft(clear).dy -
          tester
              .getBottomLeft(find.byKey(EnergyControl.presetKey(EnergyArc.arc)))
              .dy,
      closeTo(6, 0.5),
    );
    await tester.tap(clear);
    await tester.pumpAndSettle();

    expect(find.text(EnergyControl.unsetLabel), findsOneWidget);
    expect(find.text(EnergyArc.rise.label), findsNothing);
    expect(controller.text, 'Sunday morning');

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('a brief with no room for the shape toasts and changes nothing', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'x' * 2000);
    await _pumpChip(tester, controller);
    await _openMenu(tester);
    await tester.tap(find.byKey(EnergyControl.presetKey(EnergyArc.rise)));
    await tester.pumpAndSettle();

    expect(find.byKey(mixtapeMenuKey), findsNothing);
    expect(find.text(energySheetTooLong), findsOneWidget);
    expect(find.byType(MixtapeFeedback), findsOneWidget);
    expect(find.text(EnergyControl.unsetLabel), findsOneWidget);
    expect(controller.text, 'x' * 2000);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('the menu fits a short phone with large text', (tester) async {
    final controller = TextEditingController(text: 'Sunday');
    await _pumpChip(
      tester,
      controller,
      theme: MixtapeTheme.dark(),
      textScale: 2,
      size: const Size(320, 568),
    );
    await _openMenu(tester);
    expect(tester.takeException(), isNull);
    final menu = tester.getRect(find.byKey(mixtapeMenuKey));
    expect(menu.left, greaterThanOrEqualTo(14));
    expect(menu.right, lessThanOrEqualTo(320 - 14));
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('a disabled chip cannot open the menu', (tester) async {
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
    expect(find.byKey(mixtapeMenuKey), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  testWidgets('each glyph draws its own curve at the board size', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Row(
          children: [for (final arc in EnergyArc.values) EnergyShapeGlyph(arc)],
        ),
      ),
    );
    for (final glyph in tester.widgetList<EnergyShapeGlyph>(
      find.byType(EnergyShapeGlyph),
    )) {
      expect(tester.getSize(find.byWidget(glyph)), EnergyShapeGlyph.boardSize);
    }
    expect(EnergyShapeGlyph.boardSize, const Size(34, 20));
  });

  // The chip used to be built by the composer and hidden by the screens that
  // drew their own; it now lives in Home's title row, so the composer draws
  // none at all (smoke round five, note 1).
  testWidgets('the composer draws no Shape control of its own', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Scaffold(
          body: MixPromptInput(
            controller: controller,
            busy: false,
            onSubmit: () {},
            showVoiceInput: false,
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
