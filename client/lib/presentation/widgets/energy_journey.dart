import 'package:flutter/material.dart';

enum EnergyArc {
  steady('Steady', 'A consistent feel from start to finish.'),
  rise('Build gradually', 'Begin gently and finish with more energy.'),
  fall('Wind down', 'Start with a lift and settle toward the end.'),
  arc('Build, then settle', 'Gentle start. Lift in the middle. Soft landing.');

  const EnergyArc(this.label, this.description);
  final String label;
  final String description;
}

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

class EnergyControl extends StatelessWidget {
  const EnergyControl({
    super.key,
    required this.controller,
    this.enabled = true,
  });
  final TextEditingController controller;
  final bool enabled;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: TextButton.icon(
      icon: const Icon(Icons.show_chart, size: 18),
      label: const Text('Energy journey'),
      onPressed: !enabled
          ? null
          : () async {
              final result = await showDialog<EnergyArc>(
                context: context,
                builder: (_) => _EnergyDialog(controller: controller),
              );
              if (!context.mounted || result == null) return;
              final next = energyBrief(controller.text, result);
              if (next == null) return;
              controller.value = TextEditingValue(
                text: next,
                selection: TextSelection.collapsed(offset: next.length),
              );
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Shape added to your brief. Send when ready.'),
                ),
              );
            },
    ),
  );
}

class _EnergyDialog extends StatefulWidget {
  const _EnergyDialog({required this.controller});
  final TextEditingController controller;
  @override
  State<_EnergyDialog> createState() => _EnergyDialogState();
}

class _EnergyDialogState extends State<_EnergyDialog> {
  EnergyArc arc = EnergyArc.arc;
  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('Give the mix a shape.'),
    content: SizedBox(
      width: 340,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(arc.description),
          const SizedBox(height: 16),
          Semantics(
            label: 'Target shape: ${arc.label}',
            child: SizedBox(
              height: 100,
              width: double.infinity,
              child: CustomPaint(
                painter: _EnergyPainter(
                  arc,
                  Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ),
          const Text(
            'Target shape · not a measurement of your songs',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in EnergyArc.values)
                ChoiceChip(
                  label: Text(option.label),
                  selected: option == arc,
                  onSelected: (_) => setState(() => arc = option),
                ),
            ],
          ),
          if (energyBrief(widget.controller.text, arc) == null)
            const Text('Shorten your brief to make room for the shape.'),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: energyBrief(widget.controller.text, arc) == null
            ? null
            : () => Navigator.pop(context, arc),
        child: const Text('Use this shape'),
      ),
    ],
  );
}

class _EnergyPainter extends CustomPainter {
  _EnergyPainter(this.arc, this.color);
  final EnergyArc arc;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final path = Path();
    switch (arc) {
      case EnergyArc.steady:
        path.moveTo(4, 50);
        path.lineTo(w - 4, 50);
      case EnergyArc.rise:
        path.moveTo(4, 85);
        path.cubicTo(w * .3, 85, w * .7, 15, w - 4, 15);
      case EnergyArc.fall:
        path.moveTo(4, 15);
        path.cubicTo(w * .3, 15, w * .7, 85, w - 4, 85);
      case EnergyArc.arc:
        path.moveTo(4, 85);
        path.cubicTo(w * .25, 85, w * .3, 15, w * .5, 15);
        path.cubicTo(w * .7, 15, w * .75, 85, w - 4, 85);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_EnergyPainter oldDelegate) =>
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
