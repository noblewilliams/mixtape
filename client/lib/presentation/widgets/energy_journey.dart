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

import 'package:mixtape/presentation/widgets/foundation/mixtape_feedback.dart';
import 'package:flutter/material.dart';

import '../theme/mixtape_theme.dart';
import 'foundation/frosted_surface.dart';
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

/// Home's `Shape` control: a glass pill marked with the wave glyph, sitting in
/// the large-title row's trailing slot beside the title — the same slot
/// Library's glass cluster uses (founder, smoke round five, note 1).
///
/// With no shape chosen it reads "Shape" over the generic wave; with one it
/// wears that arc's own name and its own wave, and the sheet opens on it. It
/// used to sit inside the bottom panel above the composer, which stretched the
/// panel.
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

  /// The glass pill's own geometry: the board's 46 pt title-row cluster around
  /// a 44 pt target, and the wave that marks it.
  static const double pillHeight = MixtapeMetrics.minTarget;
  static const double pillSidePadding = 12;
  static const double waveWidth = 18;
  static const double waveHeight = 12;
  static const double waveGap = 6;

  /// The label stops growing here rather than pushing the title off its row.
  static const double maxLabelWidth = 132;

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
    final tokens = context.tokens;
    final arc = selectedArc;
    final label = arc?.label ?? unsetLabel;

    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      // `excludeSemantics` drops the detector's own tap action, and a node
      // with no action cannot be activated by VoiceOver. Declare it here.
      onTap: enabled ? () => _open(context) : null,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => _open(context) : null,
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: FrostedSurface(
            key: chipKey,
            borderRadius: BorderRadius.circular(MixtapeMetrics.pillRadius),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: pillHeight),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: pillSidePadding,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    EnergyWave(
                      arc: arc ?? genericArc,
                      width: waveWidth,
                      height: waveHeight,
                    ),
                    const SizedBox(width: waveGap),
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: maxLabelWidth,
                      ),
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: tokens.text,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
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
  builder: (_) => _EnergyShapeSheet(controller: controller, selected: selected),
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
    mixtapeSnackBar(message: energyShapeToast, kind: FeedbackKind.info),
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
