import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';

/// The cassette, painted from `web/public/tape.svg` (viewBox 200 × 128).
///
/// The one decorative motif in the approved shell
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md`). It is drawn rather
/// than loaded so it scales from a 22 pt line glyph to a 150 pt empty-state
/// illustration without an SVG dependency.
class CassetteTile extends StatefulWidget {
  const CassetteTile({
    super.key,
    required this.width,
    this.caseColor,
    this.seedId,
    this.spinning = false,
  });

  /// The painted width; height follows the 200 × 128 viewBox.
  final double width;

  /// Overrides the colour [seedId] would pick.
  final Color? caseColor;

  /// A stable id (usually a mix id): the same id always gives the same case.
  final String? seedId;

  /// Turns the hubs, unless the platform asks for reduced motion.
  final bool spinning;

  /// One turn of the hubs, matching the board's `hub` keyframes.
  static const Duration hubPeriod = Duration(milliseconds: 1050);

  /// The painted [CustomPaint], for tests.
  static const Key paintKey = Key('cassette-paint');

  /// The five case colours from the board.
  static const List<Color> caseColors = [
    Color(0xFF3F4851),
    Color(0xFF544451),
    Color(0xFF45596D),
    Color(0xFF6F5A4D),
    Color(0xFF2C2B33),
  ];

  /// Picks a case from [caseColors] by a stable hash of [seedId].
  ///
  /// FNV-1a rather than [String.hashCode], which is not stable across runs.
  static Color caseColorFor(String? seedId) {
    if (seedId == null || seedId.isEmpty) return caseColors.first;
    var hash = 0x811c9dc5;
    for (final unit in seedId.codeUnits) {
      hash = (hash ^ unit) & 0xFFFFFFFF;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return caseColors[hash % caseColors.length];
  }

  @override
  CassetteTileState createState() => CassetteTileState();
}

/// Public so tests can assert the hubs never start under reduced motion.
class CassetteTileState extends State<CassetteTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hubs = AnimationController(
    vsync: this,
    duration: CassetteTile.hubPeriod,
  );
  bool _reducedMotion = false;

  /// Whether the hub controller is actually running.
  @visibleForTesting
  bool get isSpinning => _hubs.isAnimating;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reducedMotion = MediaQuery.disableAnimationsOf(context);
    _syncHubs();
  }

  @override
  void didUpdateWidget(CassetteTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.spinning != widget.spinning) _syncHubs();
  }

  void _syncHubs() {
    if (widget.spinning && !_reducedMotion) {
      if (!_hubs.isAnimating) _hubs.repeat();
    } else if (_hubs.isAnimating) {
      _hubs.stop();
      _hubs.value = 0;
    }
  }

  @override
  void dispose() {
    _hubs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final caseColor =
        widget.caseColor ?? CassetteTile.caseColorFor(widget.seedId);
    final stripes = tokens.prism.take(5).toList(growable: false);
    final size = Size(widget.width, widget.width * 128 / 200);

    return SizedBox.fromSize(
      size: size,
      child: AnimatedBuilder(
        animation: _hubs,
        builder: (_, __) => CustomPaint(
          key: CassetteTile.paintKey,
          size: size,
          painter: CassettePainter(
            caseColor: caseColor,
            stripes: stripes,
            turn: _hubs.value,
          ),
        ),
      ),
    );
  }
}

/// Paints the cassette in the SVG's own 200 × 128 coordinates, scaled to fit.
class CassettePainter extends CustomPainter {
  const CassettePainter({
    required this.caseColor,
    required this.stripes,
    this.turn = 0,
  });

  final Color caseColor;

  /// Prism stops 1–5, top to bottom.
  final List<Color> stripes;

  /// Hub rotation, 0–1 of a full turn.
  final double turn;

  static const Color _caseEdge = Color(0xFF252328);
  static const Color _stock = Color(0xFFF2EDE2);
  static const Color _rule = Color.fromRGBO(75, 66, 71, 0.34);
  static const Color _dark = Color(0xFF17161A);
  static const Color _darkEdge = Color(0xFF28262A);
  static const Color _band = Color(0xFF493638);
  static const Color _ring = Color(0xFFDEDBD6);
  static const Color _hole = Color(0xFFF4F1EC);
  static const Color _guide = Color(0xFFF2F0EB);
  static const Color _guideEdge = Color(0xFF544E52);
  static const Color _metal = Color(0xFF9A9590);
  static const Color _metalEdge = Color(0xFF4F4A4D);

  static Paint _fill(Color color) => Paint()
    ..style = PaintingStyle.fill
    ..color = color
    ..isAntiAlias = true;

  static Paint _stroke(Color color, double width) => Paint()
    ..style = PaintingStyle.stroke
    ..color = color
    ..strokeWidth = width
    ..isAntiAlias = true;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 200);

    // Case and its inner edge.
    final shell = RRect.fromLTRBR(1, 1, 199, 127, const Radius.circular(9));
    canvas
      ..drawRRect(shell, _fill(caseColor))
      ..drawRRect(shell, _stroke(_caseEdge, 2))
      ..drawRRect(
        RRect.fromLTRBR(3, 3, 197, 125, const Radius.circular(7)),
        _stroke(const Color.fromRGBO(255, 255, 255, 0.25), 2),
      )
      // Paper stock and its rule line.
      ..drawRRect(
        RRect.fromLTRBR(14, 12, 186, 85, const Radius.circular(5)),
        _fill(_stock),
      )
      ..drawLine(
        const Offset(22, 31),
        const Offset(178, 31),
        _stroke(_rule, 1),
      );

    // The prism stripes, y 39 → 64 in 5 pt bands.
    for (var i = 0; i < stripes.length && i < 5; i++) {
      canvas.drawRect(Rect.fromLTWH(14, 39 + i * 5, 172, 5), _fill(stripes[i]));
    }

    // The window, the tape band behind it, and the hubs.
    final window = RRect.fromLTRBR(42, 42, 158, 81, const Radius.circular(7));
    canvas
      ..drawRRect(window, _fill(_dark))
      ..drawRRect(window, _stroke(_darkEdge, 2))
      ..drawRRect(
        RRect.fromLTRBR(72, 55, 128, 67, const Radius.circular(2)),
        _fill(_band),
      );
    _paintHub(canvas, const Offset(61, 61), turn);
    // The right hub turns the other way, as in `web/src/components/Cassette.tsx`
    // (`<Hub x={139} reverse />`); the board's CSS simplified both to one.
    _paintHub(canvas, const Offset(139, 61), -turn);

    // Lower trapezoid, guide rollers and the metal parts.
    final skirt = Path()
      ..moveTo(48, 89)
      ..lineTo(152, 89)
      ..lineTo(164, 119)
      ..lineTo(36, 119)
      ..close();
    canvas
      ..drawPath(skirt, _fill(_dark))
      ..drawPath(skirt, _stroke(_darkEdge, 2));

    final guideFill = _fill(_guide);
    final guideStroke = _stroke(_guideEdge, 2);
    for (final center in const [Offset(58, 105), Offset(142, 105)]) {
      canvas
        ..drawCircle(center, 6, guideFill)
        ..drawCircle(center, 6, guideStroke);
    }

    final metalFill = _fill(_metal);
    final metalStroke = _stroke(_metalEdge, 1.5);
    for (final rect in const [
      Rect.fromLTWH(75, 100, 8, 13),
      Rect.fromLTWH(117, 100, 8, 13),
    ]) {
      final rounded = RRect.fromRectAndRadius(rect, const Radius.circular(2));
      canvas
        ..drawRRect(rounded, metalFill)
        ..drawRRect(rounded, metalStroke);
    }
    for (final circle in const [
      (Offset(100, 108), 4.0),
      (Offset(9, 9), 3.0),
      (Offset(191, 9), 3.0),
      (Offset(9, 119), 3.0),
      (Offset(191, 119), 3.0),
    ]) {
      canvas
        ..drawCircle(circle.$1, circle.$2, metalFill)
        ..drawCircle(circle.$1, circle.$2, metalStroke);
    }

    canvas.restore();
  }

  void _paintHub(Canvas canvas, Offset center, double turn) {
    canvas
      ..save()
      ..translate(center.dx, center.dy)
      ..drawCircle(Offset.zero, 16, _fill(_ring))
      ..drawCircle(Offset.zero, 16, _stroke(_darkEdge, 4))
      ..save()
      ..rotate(turn * 2 * math.pi);
    final tooth = _fill(_darkEdge);
    for (var i = 0; i < 8; i++) {
      canvas
        ..save()
        ..rotate(i * math.pi / 4)
        ..drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(-3, -15, 6, 6),
            const Radius.circular(1),
          ),
          tooth,
        )
        ..restore();
    }
    canvas
      ..restore()
      ..drawCircle(Offset.zero, 5, _fill(_hole))
      ..restore();
  }

  @override
  bool shouldRepaint(CassettePainter oldDelegate) =>
      oldDelegate.caseColor != caseColor ||
      oldDelegate.turn != turn ||
      !_sameStripes(oldDelegate.stripes, stripes);

  static bool _sameStripes(List<Color> a, List<Color> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
