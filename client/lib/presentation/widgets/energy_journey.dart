/// The energy shape: the Shape chip beside the composer and the popover it
/// opens (`docs/mockups/approved/2026-11-03-mix-conversation-redesign.md` →
/// Shape; "Shape on Home" and `.sh` on
/// `docs/mockups/2026-11-03-mix-conversation-redesign.html`, section 5).
///
/// Each shape is a menu row with its curve drawn beside it. Picking one
/// applies it at once: there is no "Use this shape" step any more.
///
/// The shape is state on the chip, not text in the field (smoke round three,
/// note 5): the chip wears the chosen arc, the draft is never touched, and
/// Home folds the sentence in only when the listener sends. Nothing generates
/// until they do.
library;

import 'package:flutter/material.dart';

import '../theme/mixtape_theme.dart';
import 'foundation/frosted_surface.dart';
import 'foundation/mixtape_feedback.dart';
import 'foundation/mixtape_menu.dart';
import 'foundation/segmented_toggle.dart';

enum EnergyArc {
  steady('Steady', 'A consistent feel from start to finish.'),
  rise('Build gradually', 'Begin gently and finish with more energy.'),
  fall('Wind down', 'Start with a lift and settle toward the end.'),
  arc('Build, then settle', 'Gentle start. Lift in the middle. Soft landing.');

  const EnergyArc(this.label, this.description);
  final String label;
  final String description;
}

/// The order the approved board draws the shapes in (revision 3, "Shape on
/// Home").
const List<EnergyArc> energyArcOrder = [
  EnergyArc.steady,
  EnergyArc.rise,
  EnergyArc.fall,
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

/// The toast when the brief has no room for the shape's sentence. Home also
/// says it under the composer when a send would overflow.
const String energySheetTooLong =
    'Shorten your brief to make room for the shape.';
const String energyShapeToast = 'Shape added to your brief. Send when ready.';

/// The menu's last entry, offered only while a shape is set.
const String energyClearShapeLabel = 'Clear shape';

/// Home's `Shape` control: a glass pill marked with the wave glyph. Home draws
/// it [compact] on the panel's row above the composer, trailing the Mix | Album
/// control (album picks board H1, 2026-10-20); before that it sat in the
/// large-title row (smoke round five, note 1).
///
/// With no shape chosen it reads "Shape" beside the generic curve; with one it
/// wears that arc's own name and curve, and the menu ticks it.
class EnergyControl extends StatelessWidget {
  const EnergyControl({
    super.key,
    required this.controller,
    this.enabled = true,
    this.selectedArc,
    this.onArcChanged,
    this.compact = false,
  });

  /// The Home panel's row size (album picks board H1, `.moderow .chip`):
  /// drawn [compactHeight] tall in [compactFontSize] type, with an invisible
  /// band above and below that keeps the target 44 pt tall. The menu and its
  /// flow are the same either way.
  final bool compact;

  /// The draft, which the menu reads to judge the composed message's length.
  /// It is never written to.
  final TextEditingController controller;
  final bool enabled;

  /// The shape the chip is wearing, or null for none.
  final EnergyArc? selectedArc;

  /// Told the new shape, or null when the listener clears it.
  final ValueChanged<EnergyArc?>? onArcChanged;

  /// What the chip says with nothing chosen.
  static const String unsetLabel = 'Shape';

  /// The curve the unset chip wears.
  static const EnergyArc genericArc = EnergyArc.arc;

  static const Key chipKey = Key('energy-shape-chip');

  /// The glass pill's own geometry: a 44 pt target and the curve that marks
  /// it.
  static const double pillHeight = MixtapeMetrics.minTarget;
  static const double pillSidePadding = 12;
  static const double waveWidth = 20;
  static const double waveHeight = 12;
  static const double waveGap = 6;

  /// The compact chip's drawn height at 1x (it grows with text as the compact
  /// segmented control does, to 32 pt at 1.5x), label size, padding and wave.
  static const double compactHeight = SegmentedToggle.compactTrackHeight;
  static const double compactFontSize = 11.5;
  static const double compactSidePadding = 9;

  /// The board's chip curve (`.moderow .chip svg`: 18 × 11).
  static const double compactWaveWidth = 18;
  static const double compactWaveHeight = 11;
  static const double compactWaveGap = 5;

  /// The label stops growing here rather than pushing the title off its row.
  static const double maxLabelWidth = 132;

  /// The menu's row keys, published here so callers and tests have one place
  /// to look for them.
  static const Key clearKey = Key('energy-shape-clear');

  static Key presetKey(EnergyArc arc) => ValueKey('energy-preset-${arc.name}');

  /// Anchored to the chip itself.
  Future<void> _open(BuildContext context) => showEnergyShapeMenu(
    context,
    controller: controller,
    selected: selectedArc,
    onChanged: (arc) => onArcChanged?.call(arc),
  );

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final arc = selectedArc;
    final label = arc?.label ?? unsetLabel;
    final drawn = compact
        ? SegmentedToggle.compactDrawnHeight(context)
        : pillHeight;
    final slop = compact ? SegmentedToggle.compactHitSlopFor(drawn) : 0.0;

    final chip = Semantics(
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
        child: Padding(
          // Compact: the hit band, inside the detector so it answers taps.
          padding: EdgeInsets.symmetric(vertical: slop),
          child: Opacity(
            opacity: enabled ? 1 : 0.4,
            child: FrostedSurface(
              key: chipKey,
              borderRadius: BorderRadius.circular(MixtapeMetrics.pillRadius),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: drawn),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? compactSidePadding : pillSidePadding,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      EnergyShapeGlyph(
                        arc ?? genericArc,
                        size: compact
                            ? const Size(compactWaveWidth, compactWaveHeight)
                            : const Size(waveWidth, waveHeight),
                      ),
                      SizedBox(width: compact ? compactWaveGap : waveGap),
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: maxLabelWidth,
                        ),
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: compact ? compactFontSize : 13,
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
      ),
    );
    // Compact, the label stops growing where the drawn height does (1.5x).
    return compact
        ? MediaQuery.withClampedTextScaling(
            maxScaleFactor: SegmentedToggle.compactMaxTextScale,
            child: chip,
          )
        : chip;
  }
}

/// What a shape row answers with; [_clearShape] is the Clear row.
const String _clearShape = 'clear';

/// The shape popover (revision 3, "Shape on Home"), anchored to [anchor]'s
/// render box: one row per shape with its curve and shipped subtitle, a tick
/// on [selected], and "Clear shape" behind a separator only when a shape is
/// set.
///
/// A pick applies at once: [onChanged] hears the arc, or null for Clear.
/// When [controller]'s brief has no room for the shape's sentence, nothing
/// changes and the listener gets [energySheetTooLong] as a toast. Tapping
/// outside changes nothing.
Future<void> showEnergyShapeMenu(
  BuildContext anchor, {
  required TextEditingController controller,
  EnergyArc? selected,
  required ValueChanged<EnergyArc?> onChanged,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(anchor);
  final picked = await showMixtapeMenu<String>(
    anchor,
    actions: [
      for (final arc in energyArcOrder)
        MixtapeMenuAction(
          key: EnergyControl.presetKey(arc),
          value: arc.name,
          label: arc.label,
          subtitle: arc.description,
          isSelected: arc == selected,
          leading: EnergyShapeGlyph(arc),
        ),
      if (selected != null)
        const MixtapeMenuAction(
          key: EnergyControl.clearKey,
          value: _clearShape,
          label: energyClearShapeLabel,
          separatorBefore: true,
        ),
    ],
  );
  if (picked == null) return;
  if (picked == _clearShape) {
    onChanged(null);
    return;
  }
  final arc = EnergyArc.values.byName(picked);
  if (energyBrief(controller.text, arc) == null) {
    messenger?.showSnackBar(
      mixtapeSnackBar(message: energySheetTooLong, kind: FeedbackKind.error),
    );
    return;
  }
  onChanged(arc);
}

/// One shape's curve, as the board draws it (`.sh`: a 34 × 20 viewBox,
/// 2 pt round-capped stroke in plum): flat, rise, fall and arc. Scaled to
/// [size]; the chip wears it at 18 × 11.
class EnergyShapeGlyph extends StatelessWidget {
  const EnergyShapeGlyph(
    this.arc, {
    super.key,
    this.size = boardSize,
    this.color,
  });

  final EnergyArc arc;
  final Size size;

  /// Defaults to `tokens.plum`.
  final Color? color;

  /// The board's `.sh` box.
  static const Size boardSize = Size(34, 20);

  @override
  Widget build(BuildContext context) => SizedBox.fromSize(
    size: size,
    child: CustomPaint(
      painter: _ShapeGlyphPainter(arc, color ?? context.tokens.plum),
    ),
  );
}

class _ShapeGlyphPainter extends CustomPainter {
  const _ShapeGlyphPainter(this.arc, this.color);

  final EnergyArc arc;
  final Color color;

  /// The board's paths, in its 34 × 20 viewBox.
  static Path pathFor(EnergyArc arc) {
    final path = Path();
    switch (arc) {
      case EnergyArc.steady:
        path
          ..moveTo(2, 10)
          ..lineTo(32, 10);
      case EnergyArc.rise:
        path
          ..moveTo(2, 17)
          ..cubicTo(14, 16, 22, 10, 32, 3);
      case EnergyArc.fall:
        path
          ..moveTo(2, 3)
          ..cubicTo(12, 4, 20, 10, 32, 17);
      case EnergyArc.arc:
        // `C10 16 12 3 17 3 S24 16 32 16`: the S reflects (12, 3) about
        // (17, 3) for its first control point.
        path
          ..moveTo(2, 16)
          ..cubicTo(10, 16, 12, 3, 17, 3)
          ..cubicTo(22, 3, 24, 16, 32, 16);
    }
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final box = EnergyShapeGlyph.boardSize;
    final scaleX = size.width / box.width;
    final scaleY = size.height / box.height;
    final scale = (scaleX + scaleY) / 2;
    canvas.save();
    canvas.scale(scaleX, scaleY);
    canvas.drawPath(
      pathFor(arc),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        // The board's 2 pt in viewBox units, but never thinner than 1.5 pt on
        // screen: at the chip's size a scaled stroke disappears.
        ..strokeWidth = (2 * scale).clamp(1.5, double.infinity) / scale
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ShapeGlyphPainter oldDelegate) =>
      arc != oldDelegate.arc || color != oldDelegate.color;
}

/// The earlier board's `.preset svg.w` path for one arc, drawn on a 44 × 28
/// box and scaled to whatever size it is given: the energy line's glyph. The
/// chip and the shape menu draw [EnergyShapeGlyph] instead.
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
