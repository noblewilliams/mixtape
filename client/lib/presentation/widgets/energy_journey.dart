/// The energy shape: the Shape chip beside the composer and the sheet it opens
/// (`docs/mockups/approved/2026-09-17-mobile-conversation-states.md` → Energy
/// shape sheet; frame A1 and `.sheet` / `.preset` on
/// `docs/mockups/2026-09-17-mobile-conversation-states.html`).
///
/// The shape is state on the chip, not text in the field (smoke round three,
/// note 5): the chip wears the chosen arc, the draft is never touched, and
/// Home folds the sentence in only when the listener sends. Nothing generates
/// until they do.
library;

import 'package:flutter/material.dart';

import '../theme/mixtape_theme.dart';
import 'foundation/label_chip.dart';
import 'foundation/mixtape_sheet.dart';
import 'foundation/tape_button.dart';
import 'foundation/text_action.dart';

enum EnergyArc {
  steady('Steady', 'A consistent feel from start to finish.'),
  rise('Build gradually', 'Begin gently and finish with more energy.'),
  fall('Wind down', 'Start with a lift and settle toward the end.'),
  arc('Build, then settle', 'Gentle start. Lift in the middle. Soft landing.');

  const EnergyArc(this.label, this.description);
  final String label;
  final String description;
}

/// The order the approved board draws the presets in (frame A1).
const List<EnergyArc> energyArcOrder = [
  EnergyArc.rise,
  EnergyArc.fall,
  EnergyArc.steady,
  EnergyArc.arc,
];

String? energyBrief(String text, EnergyArc arc) {
  final clean = text
      .replaceAll(
        RegExp(
          r'(?:^|\n)Energy journey: (?:Steady|Build gradually|Wind down|Build, then settle)\.(?=\n|$)',
        ),
        '',
      )
      .trim();
  final next =
      '${clean.isEmpty ? '' : '$clean\n'}Energy journey: ${arc.label}.';
  return next.length <= 2000 ? next : null;
}

String journeyMessage(String status) => switch (status) {
  'follows' => 'The opening, middle and ending broadly follow your shape.',
  'mixed' =>
    'A gentler journey this time. This mix does not follow every part of the shape. Your song choices and exclusions still come first.',
  _ =>
    'There is not enough energy information to judge every transition. Your song choices and exclusions still come first.',
};

/// The energy line's verdict, appended to the shape's own name: "Steady,
/// then a lift · as asked" / "· limited coverage" on the approved board. The
/// middle case keeps the shipped "mixed" wording's own words.
String energyLineVerdict(String status) => switch (status) {
  'follows' => 'as asked',
  'mixed' => 'a gentler journey',
  _ => 'limited coverage',
};

/// "Build, then settle · as asked" — the whole line, or null when the version
/// detail carries no shape to speak of.
String? energyLine(Map<String, dynamic> detail) {
  final arc = EnergyArc.values
      .where((a) => a.name == detail['energyArc'])
      .firstOrNull;
  final journey = detail['energyJourney'];
  if (arc == null || journey is! Map) return null;
  final status = journey['status'] as String? ?? 'limited';
  return '${arc.label} · ${energyLineVerdict(status)}';
}

/// The sheet's own copy.
const String energySheetTitle = 'Give the mix a shape.';
/// The shape no longer lands in the field, so the blurb no longer promises it
/// will (smoke round three, note 5).
const String energySheetBlurb =
    'Goes out with your brief. You still send it yourself.';
const String energySheetTooLong =
    'Shorten your brief to make room for the shape.';
const String energyShapeToast = 'Shape added to your brief. Send when ready.';

/// Hides the composer's own Shape chip for screens that draw it themselves.
///
/// [MixPromptInput] always builds an [EnergyControl] under the attachment
/// slot, which is right for Home. The conversation puts the chip in its own
/// attachment row beside the playlist chip (the board's single `.attach` row),
/// so it wraps the composer in this and draws the chip itself.
class EnergyControlVisibility extends InheritedWidget {
  const EnergyControlVisibility({
    super.key,
    required this.visible,
    required super.child,
  });

  final bool visible;

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<EnergyControlVisibility>()
          ?.visible ??
      true;

  @override
  bool updateShouldNotify(EnergyControlVisibility oldWidget) =>
      oldWidget.visible != visible;
}

/// What the shape sheet answers with.
///
/// A null result from the sheet itself is a dismissal and changes nothing; a
/// choice carrying a null [arc] is the listener pressing Clear.
@immutable
class EnergyShapeChoice {
  const EnergyShapeChoice(this.arc);

  final EnergyArc? arc;

  @override
  bool operator ==(Object other) =>
      other is EnergyShapeChoice && other.arc == arc;

  @override
  int get hashCode => arc.hashCode;
}

/// The board's `Shape` chip: a 36 pt label chip marked with the wave glyph.
///
/// With no shape chosen it reads "Shape" over the generic wave; with one it
/// wears that arc's own name and its own wave, and the sheet opens on it.
class EnergyControl extends StatelessWidget {
  const EnergyControl({
    super.key,
    required this.controller,
    this.enabled = true,
    this.selectedArc,
    this.onArcChanged,
  });

  /// The draft, which the sheet reads to judge the composed message's length.
  /// It is never written to.
  final TextEditingController controller;
  final bool enabled;

  /// The shape the chip is wearing, or null for none.
  final EnergyArc? selectedArc;

  /// Told the new shape, or null when the listener clears it.
  final ValueChanged<EnergyArc?>? onArcChanged;

  /// What the chip says with nothing chosen.
  static const String unsetLabel = 'Shape';

  /// The wave the unset chip wears.
  static const EnergyArc genericArc = EnergyArc.arc;

  static const Key chipKey = Key('energy-shape-chip');

  /// The sheet's own keys, published here so callers and tests have one place
  /// to look for them.
  static const Key sheetKey = Key('energy-shape-sheet');
  static const Key confirmKey = Key('energy-shape-confirm');
  static const Key clearKey = Key('energy-shape-clear');
  static const Key tooLongKey = Key('energy-shape-too-long');

  static Key presetKey(EnergyArc arc) => ValueKey('energy-preset-${arc.name}');

  Future<void> _open(BuildContext context) async {
    final choice = await pickEnergyShape(
      context,
      controller,
      selected: selectedArc,
    );
    if (choice == null) return;
    onArcChanged?.call(choice.arc);
  }

  @override
  Widget build(BuildContext context) {
    if (!EnergyControlVisibility.of(context)) return const SizedBox.shrink();
    final arc = selectedArc;
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: LabelChip(
          key: chipKey,
          label: arc?.label ?? unsetLabel,
          hole: false,
          leading: EnergyWave(
            arc: arc ?? genericArc,
            width: 18,
            height: 12,
          ),
          onPressed: enabled ? () => _open(context) : null,
        ),
      ),
    );
  }
}

/// Opens the shape sheet on [selected] and returns what the listener did.
Future<EnergyShapeChoice?> pickEnergyShape(
  BuildContext context,
  TextEditingController controller, {
  EnergyArc? selected,
}) => showMixtapeSheet<EnergyShapeChoice>(
  context,
  isScrollControlled: true,
  builder: (_) =>
      _EnergyShapeSheet(controller: controller, selected: selected),
);

/// The conversation's chip: there is no session-start message to fold the
/// sentence into on a later turn, so choosing a shape mid-conversation still
/// writes it into the draft and toasts. Nothing is sent.
Future<void> showEnergyShapeSheet(
  BuildContext context,
  TextEditingController controller,
) async {
  final choice = await pickEnergyShape(context, controller);
  final result = choice?.arc;
  if (!context.mounted || result == null) return;
  final next = energyBrief(controller.text, result);
  if (next == null) return;
  controller.value = TextEditingValue(
    text: next,
    selection: TextSelection.collapsed(offset: next.length),
  );
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text(energyShapeToast),
      behavior: SnackBarBehavior.floating,
      margin: EdgeInsets.all(16),
    ),
  );
}

class _EnergyShapeSheet extends StatefulWidget {
  const _EnergyShapeSheet({required this.controller, this.selected});

  final TextEditingController controller;

  /// The shape the chip is already wearing, which the radio opens on and
  /// which is what makes Clear worth offering.
  final EnergyArc? selected;

  @override
  State<_EnergyShapeSheet> createState() => _EnergyShapeSheetState();
}

class _EnergyShapeSheetState extends State<_EnergyShapeSheet> {
  late EnergyArc arc = widget.selected ?? EnergyControl.genericArc;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final tooLong = energyBrief(widget.controller.text, arc) == null;

    return Semantics(
      key: EnergyControl.sheetKey,
      container: true,
      label: energySheetTitle,
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(energySheetTitle, style: MixtapeSheet.headingOf(context)),
              const SizedBox(height: 2),
              Padding(
                // The heading block's own gap plus the founder's extra air
                // above the first row (smoke round three, note 4).
                padding: const EdgeInsets.only(
                  bottom: 8 + MixtapeSheet.headingGap,
                ),
                child: Text(
                  energySheetBlurb,
                  style: MixtapeSheet.subtitleOf(context),
                ),
              ),
              for (var i = 0; i < energyArcOrder.length; i++)
                _preset(tokens, energyArcOrder[i], separated: i > 0),
              if (tooLong)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    energySheetTooLong,
                    key: EnergyControl.tooLongKey,
                    style: tokens.secondary.copyWith(color: tokens.errInk),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 12),
                // Cancel at the left edge, the action at the right: the
                // two are not a huddle (smoke round two, note 3).
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextAction(
                          label: 'Cancel',
                          quiet: true,
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        // Only worth offering once there is a shape to take
                        // off the chip.
                        if (widget.selected != null) ...[
                          const SizedBox(width: 4),
                          TextAction(
                            key: EnergyControl.clearKey,
                            label: 'Clear',
                            onPressed: () => Navigator.of(
                              context,
                            ).pop(const EnergyShapeChoice(null)),
                          ),
                        ],
                      ],
                    ),
                    Flexible(
                      child: TapeButton(
                        key: EnergyControl.confirmKey,
                        label: 'Use this shape',
                        onPressed: tooLong
                            ? null
                            : () => Navigator.of(
                                context,
                              ).pop(EnergyShapeChoice(arc)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// `.preset`: the wave glyph, the label and its description, and the radio.
  Widget _preset(
    MixtapeTokens tokens,
    EnergyArc option, {
    required bool separated,
  }) {
    final selected = option == arc;
    return Semantics(
      button: true,
      inMutuallyExclusiveGroup: true,
      selected: selected,
      label: '${option.label}. ${option.description}',
      // `excludeSemantics` drops the detector's own tap action, and a node
      // with no action cannot be activated by VoiceOver. Declare it here.
      onTap: () => setState(() => arc = option),
      excludeSemantics: true,
      child: GestureDetector(
        key: EnergyControl.presetKey(option),
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => arc = option),
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: separated
              ? BoxDecoration(
                  border: Border(top: BorderSide(color: tokens.hairline)),
                )
              : null,
          child: Row(
            children: [
              EnergyWave(
                arc: option,
                width: 44,
                height: 28,
                color: tokens.plum,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      option.label,
                      style: tokens.rowTitle.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      option.description,
                      style: tokens.meta.copyWith(color: tokens.muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? tokens.plum : tokens.muted,
                    width: selected ? 7 : 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The board's `.preset svg.w` path for one arc, drawn on a 44 × 28 box and
/// scaled to whatever size it is given. Also the energy line's glyph.
class EnergyWave extends StatelessWidget {
  const EnergyWave({
    super.key,
    required this.arc,
    this.width = 44,
    this.height = 28,
    this.color,
  });

  final EnergyArc arc;
  final double width;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: height,
    child: CustomPaint(
      painter: _WavePainter(arc, color ?? context.tokens.plum),
    ),
  );
}

class _WavePainter extends CustomPainter {
  const _WavePainter(this.arc, this.color);

  final EnergyArc arc;
  final Color color;

  /// The board's viewBox.
  static const Size _viewBox = Size(44, 28);

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path();
    switch (arc) {
      case EnergyArc.steady:
        path.moveTo(3, 14);
        path.lineTo(41, 14);
      case EnergyArc.rise:
        path.moveTo(3, 24);
        path.quadraticBezierTo(22, 24, 41, 4);
      case EnergyArc.fall:
        path.moveTo(3, 4);
        path.quadraticBezierTo(22, 4, 41, 24);
      case EnergyArc.arc:
        path.moveTo(3, 24);
        path.quadraticBezierTo(22, -8, 41, 24);
    }
    final scaleX = size.width / _viewBox.width;
    final scaleY = size.height / _viewBox.height;
    canvas.save();
    canvas.scale(scaleX, scaleY);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 / ((scaleX + scaleY) / 2)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_WavePainter oldDelegate) =>
      arc != oldDelegate.arc || color != oldDelegate.color;
}

class EnergyAssessment extends StatelessWidget {
  const EnergyAssessment({super.key, required this.detail});
  final Map<String, dynamic> detail;
  @override
  Widget build(BuildContext context) {
    final arc = EnergyArc.values
        .where((a) => a.name == detail['energyArc'])
        .firstOrNull;
    final journey = detail['energyJourney'];
    if (arc == null || journey is! Map) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(arc.label, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(journeyMessage(journey['status'] as String? ?? 'limited')),
        ],
      ),
    );
  }
}
