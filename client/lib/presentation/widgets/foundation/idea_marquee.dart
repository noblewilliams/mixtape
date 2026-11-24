/// Home's idea pills on one line, drifting sideways in a slow loop.
///
/// A held finger stops the drift and drags the row; it picks up again a
/// moment after letting go. Reduced motion, VoiceOver navigation and [running]
/// false all leave it still: a plain row that scrolls by hand, with each pill
/// drawn once.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

class IdeaMarquee extends StatefulWidget {
  const IdeaMarquee({
    super.key,
    required this.children,
    this.running = true,
    this.still = false,
    this.inset = 0,
    this.gap = 8,
  });

  final List<Widget> children;

  /// Whether the row drifts. Home stops it while the field has a draft, so
  /// nothing moves under someone typing.
  final bool running;

  /// Never drifts: a plain row that scrolls by hand. For a short set that is
  /// a choice to make rather than ideas to browse (a playlist's refinements).
  final bool still;

  /// Where the first pill rests, from the row's leading edge — in line with
  /// the composer above, while the row itself runs edge to edge.
  final double inset;

  final double gap;

  /// Points per second.
  static const double speed = 22;

  /// How long after a finger lifts before the drift resumes.
  static const Duration resumeDelay = Duration(seconds: 2);

  /// How far in from each edge the pills fade out.
  static const double edgeFade = 18;

  /// The widest a single pill may be, as a share of the row.
  static const double maxItemFraction = 0.72;

  /// Widget tests switch the drift off (`test/flutter_test_config.dart`): a
  /// row that never stops moving never lets `pumpAndSettle` settle.
  static bool animate = true;

  static const Key rowKey = Key('idea-marquee');

  @override
  State<IdeaMarquee> createState() => _IdeaMarqueeState();
}

class _IdeaMarqueeState extends State<IdeaMarquee>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final ValueNotifier<double> _offset = ValueNotifier(0);
  final GlobalKey _cycleKey = GlobalKey();
  final GlobalKey _firstKey = GlobalKey();
  Duration _last = Duration.zero;
  double _cycle = 0;
  bool _held = false;
  Timer? _resume;

  /// The first pill's width with its gap, as last laid out.
  double? _first;

  /// The first pill was swapped for another (or one was put in front): once
  /// the new one is laid out, the offset moves by the difference.
  ({double before, bool inserted})? _firstChanged;

  @override
  void dispose() {
    _resume?.cancel();
    _ticker.dispose();
    _offset.dispose();
    super.dispose();
  }

  bool _moving(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    return IdeaMarquee.animate &&
        !widget.still &&
        widget.children.isNotEmpty &&
        !(media?.disableAnimations ?? false) &&
        !(media?.accessibleNavigation ?? false);
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    if (_held || !widget.running || _cycle == 0) return;
    _offset.value += IdeaMarquee.speed * dt;
  }

  void _hold() {
    _resume?.cancel();
    _held = true;
  }

  void _release() {
    _resume?.cancel();
    _resume = Timer(IdeaMarquee.resumeDelay, () => _held = false);
  }

  /// One pass of the pills, measured once laid out.
  void _measure() {
    final first = _firstKey.currentContext?.findRenderObject() as RenderBox?;
    if (first != null && first.hasSize) {
      final width = first.size.width;
      final changed = _firstChanged;
      if (changed != null) {
        _firstChanged = null;
        _shift(width - (changed.inserted ? 0 : changed.before));
      }
      _first = width;
    }
    final box = _cycleKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final width = box.size.width;
    if (width != _cycle && mounted) setState(() => _cycle = width);
  }

  /// Moves the drift by [delta] within the current pass, so the pills on
  /// screen keep their places while the pass changes length in front of
  /// them.
  void _shift(double delta) {
    if (_cycle <= 0) return;
    _offset.value = (_offset.value % _cycle) + delta;
  }

  /// When the first pill changes (Home's routine skeleton giving way once the
  /// routine has loaded), the pills after it would all jump by its width. The
  /// offset takes up the change instead, so nothing on screen moves (launch
  /// glitch, 2026-11-24).
  @override
  void didUpdateWidget(IdeaMarquee old) {
    super.didUpdateWidget(old);
    if (old.children.isEmpty || widget.children.isEmpty) return;
    final before = old.children.first.key;
    final now = widget.children.first.key;
    if (before == null || before == now) return;
    final width = _first;
    if (width == null || _cycle <= 0) return;
    final gone =
        old.children.length > 1 && old.children[1].key == now && now != null;
    if (gone) {
      // The first pill left: the rest stay put, and the pass is shorter by
      // exactly its width, known now.
      _offset.value = (_offset.value % _cycle) - width;
      _cycle -= width;
      _first = null;
      return;
    }
    final inserted =
        widget.children.length > 1 && widget.children[1].key == before;
    _firstChanged = (before: width, inserted: inserted);
  }

  /// A long routine title ellipsizes rather than running a whole screen
  /// wide: no pill is wider than [IdeaMarquee.maxItemFraction] of the row.
  Widget _capped(Widget child, double viewport) => ConstrainedBox(
    constraints: BoxConstraints(
      maxWidth: viewport * IdeaMarquee.maxItemFraction,
    ),
    child: child,
  );

  Widget _pass(double viewport, {Key? key, required bool primary}) {
    final row = Row(
      key: key,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          Padding(
            key: primary && i == 0 ? _firstKey : null,
            padding: EdgeInsets.only(right: widget.gap),
            child: _capped(widget.children[i], viewport),
          ),
      ],
    );
    // Only one pass is read aloud; the rest are the same pills again.
    return primary ? row : ExcludeSemantics(child: row);
  }

  @override
  Widget build(BuildContext context) {
    final moving = _moving(context);
    if (moving && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    } else if (!moving && _ticker.isActive) {
      _ticker.stop();
    }

    if (!moving) {
      return LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          key: IdeaMarquee.rowKey,
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: widget.inset),
          child: Row(
            children: [
              for (var i = 0; i < widget.children.length; i++) ...[
                if (i > 0) SizedBox(width: widget.gap),
                _capped(widget.children[i], constraints.maxWidth),
              ],
            ],
          ),
        ),
      );
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());

    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.maxWidth;
        // One pass sits ahead of the resting one so the leading edge is never
        // bare as the loop wraps; enough follow to fill the rest of the row.
        final passes = _cycle == 0
            ? 3
            : math.max(3, ((viewport + _cycle) / _cycle).ceil() + 1);
        final fade = IdeaMarquee.edgeFade / math.max(viewport, 1);

        return Listener(
          onPointerDown: (_) => _hold(),
          onPointerUp: (_) => _release(),
          onPointerCancel: (_) => _release(),
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragUpdate: (details) =>
                _offset.value -= details.delta.dx,
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: (rect) => LinearGradient(
                colors: const [
                  Color(0x00000000),
                  Color(0xFF000000),
                  Color(0xFF000000),
                  Color(0x00000000),
                ],
                stops: [0, fade, 1 - fade, 1],
              ).createShader(rect),
              child: UnconstrainedBox(
                key: IdeaMarquee.rowKey,
                alignment: Alignment.centerLeft,
                constrainedAxis: Axis.vertical,
                clipBehavior: Clip.hardEdge,
                child: ValueListenableBuilder<double>(
                  valueListenable: _offset,
                  builder: (context, offset, child) {
                    final shift = _cycle == 0 ? 0.0 : offset % _cycle;
                    return Transform.translate(
                      offset: Offset(widget.inset - _cycle - shift, 0),
                      child: child,
                    );
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < passes; i++)
                        _pass(
                          viewport,
                          key: i == 1 ? _cycleKey : null,
                          primary: i == 1,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
