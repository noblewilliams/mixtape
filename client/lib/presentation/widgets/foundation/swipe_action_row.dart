/// A list row with one action on each side, revealed the way Apple Music's
/// rows reveal theirs: the row lifts into a rounded card as it slides, and a
/// capsule in the action's colour sits in the gap behind it.
///
/// Three ways a swipe ends:
/// * **Short:** the row springs back.
/// * **Part way:** the row rests open with the capsule showing, and waits.
///   Tapping the capsule runs the action; tapping the row, scrolling the list
///   or opening another row closes it.
/// * **All the way** (or a hard flick past the open point): the action runs
///   at once. The capsule stretches with the pull and its glyph pops, with a
///   haptic, once letting go would count.
///
/// A [SwipeAction.removes] action carries the row off the edge and folds the
/// gap closed before it runs (the caller then drops the row); any other
/// springs the row back. A removing action that returns a Future and leaves
/// the row in place once it completes (a failed request) unfolds it again.
///
/// Mixes' rows use it too (founder, 2026-11-23: a mix swipes as a song does).
library;

import 'dart:async';

import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

import '../../theme/mixtape_theme.dart';
import 'haptics.dart';

@immutable
class SwipeAction {
  const SwipeAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTrigger,
    this.removes = false,
    this.key,
  });

  /// The glyph, drawn white at about 17 pt.
  final Widget icon;

  /// What VoiceOver calls it.
  final String label;
  final Color color;
  final FutureOr<void> Function() onTrigger;

  /// Whether the action takes the row away.
  final bool removes;

  /// The capsule's own key, for tests; [SwipeActionRow.capsuleKey] otherwise.
  final Key? key;
}

class SwipeActionRow extends StatefulWidget {
  const SwipeActionRow({
    super.key,
    required this.child,
    this.leading,
    this.trailing,
    this.liftColor,
    this.reducedMotion = false,
    this.onActiveChanged,
    this.enabled = true,
    this.bleed = 0,
  });

  final Widget child;

  /// Revealed by a swipe to the right.
  final SwipeAction? leading;

  /// Revealed by a swipe to the left.
  final SwipeAction? trailing;

  /// The card the row becomes while it slides.
  final Color? liftColor;

  final bool reducedMotion;

  /// Told true when the row starts to slide (or rests open) and false once
  /// it is back in place: the list hides the hairlines around it meanwhile.
  final ValueChanged<bool>? onActiveChanged;

  /// False while the row is busy or being edited: no swipe, and an open row
  /// closes.
  final bool enabled;

  /// How far past its own edges the card and capsules draw: a row inset by
  /// the screen's side padding still lifts edge to edge, with its capsules
  /// [edgeInset] from the screen edge, as a full-width row's do.
  final double bleed;

  /// The capsule's width when the row rests open.
  static const double buttonWidth = 72;

  /// The gap between the card and the capsule.
  static const double gap = 8;

  /// The capsule's inset from the screen edge (the row runs edge to edge).
  static const double edgeInset = 10;

  /// The row's offset when it rests open.
  static const double openOffset = buttonWidth + gap + edgeInset;

  /// How far a swipe must go to rest open rather than spring back.
  static const double openAt = 44;

  /// The share of the row's width a swipe must cross to run the action.
  static const double fullFraction = 0.5;

  /// Where the row starts to resist being pulled further.
  static const double resistFraction = 0.68;

  /// The card's corner once fully lifted.
  static const double cardRadius = 14;

  static Key capsuleKey(bool leading) =>
      ValueKey('swipe-capsule-${leading ? 'leading' : 'trailing'}');

  /// Every row resting open (at most one in practice).
  static final Set<_SwipeActionRowState> _open = {};

  /// Closes any row resting open: for a list that has started to scroll.
  static void closeAll() {
    for (final row in _open.toList()) {
      row._close();
    }
  }

  @override
  State<SwipeActionRow> createState() => _SwipeActionRowState();
}

class _SwipeActionRowState extends State<SwipeActionRow>
    with TickerProviderStateMixin {
  /// The row's offset in logical pixels, positive to the right.
  late final AnimationController _offset = AnimationController.unbounded(
    vsync: this,
  )..addListener(_onOffset);

  /// 0 → 1 as a removed row folds closed.
  late final AnimationController _fold = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  /// The pull before resistance, so the finger and the row stay in step.
  double _raw = 0;
  double _width = 0;
  bool _armed = false;
  bool _busy = false;
  bool _active = false;

  @override
  void didUpdateWidget(SwipeActionRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && oldWidget.enabled && !_busy) _close();
  }

  @override
  void dispose() {
    SwipeActionRow._open.remove(this);
    _offset.dispose();
    _fold.dispose();
    super.dispose();
  }

  double get _fullAt => _width * SwipeActionRow.fullFraction;

  bool get _isOpen => SwipeActionRow._open.contains(this);

  /// The action a slide of [dx] reveals; within half a point of rest (where
  /// a spring comes to stop) there is none.
  SwipeAction? _actionFor(double dx) => dx > 0.5
      ? widget.leading
      : dx < -0.5
      ? widget.trailing
      : null;

  void _onOffset() {
    final active = _offset.value.abs() > 0.5;
    if (active == _active) return;
    _active = active;
    widget.onActiveChanged?.call(active);
  }

  /// The finger's pull, eased past [SwipeActionRow.resistFraction].
  double _resisted(double raw) {
    final limit = _width * SwipeActionRow.resistFraction;
    final magnitude = raw.abs();
    if (magnitude <= limit) return raw;
    return raw.sign * (limit + (magnitude - limit) * 0.3);
  }

  void _onStart(DragStartDetails _) {
    if (_busy) return;
    // Opening one row closes any other.
    for (final other in SwipeActionRow._open.toList()) {
      if (other != this) other._close();
    }
    _offset.stop();
    _raw = _offset.value;
  }

  void _onUpdate(DragUpdateDetails details) {
    if (_busy) return;
    var next = _raw + details.delta.dx;
    // No action that way: the row does not move that way.
    if (next > 0 && widget.leading == null) next = 0;
    if (next < 0 && widget.trailing == null) next = 0;
    _raw = next;
    _offset.value = _resisted(next);
    final armed = _offset.value.abs() >= _fullAt;
    if (armed != _armed) {
      _armed = armed;
      if (armed) unawaited(Haptics.play(HapticKind.threshold));
      setState(() {});
    }
  }

  void _onEnd(DragEndDetails details) {
    if (_busy) return;
    final dx = _offset.value;
    final velocity = details.primaryVelocity ?? 0;
    final action = _actionFor(dx);
    final wasArmed = _armed;
    _armed = false;
    final towards = velocity.sign == dx.sign;
    if (action == null) {
      _settleTo(0, velocity);
      return;
    }
    // All the way, or a hard flick from beyond the open point.
    if (wasArmed ||
        (towards &&
            velocity.abs() > 1800 &&
            dx.abs() > SwipeActionRow.openOffset)) {
      if (!wasArmed) unawaited(Haptics.play(HapticKind.threshold));
      _run(action, velocity);
      return;
    }
    // Part way (or flicked open): rest open; flicked back: close.
    final open =
        (dx.abs() >= SwipeActionRow.openAt &&
            !(velocity.abs() > 400 && !towards)) ||
        (towards && velocity.abs() > 400);
    _settleTo(open ? dx.sign * SwipeActionRow.openOffset : 0, velocity);
  }

  Future<void> _run(SwipeAction action, [double velocity = 0]) async {
    if (_busy) return;
    if (!action.removes) {
      _settleTo(0, velocity);
      unawaited(Future.sync(action.onTrigger));
      return;
    }
    _busy = true;
    unawaited(Haptics.play(HapticKind.destructive));
    SwipeActionRow._open.remove(this);
    final out =
        (_offset.value == 0 ? -1 : _offset.value.sign) *
        (_width + widget.bleed + 40);
    if (widget.reducedMotion) {
      _offset.value = out;
      _fold.value = 1;
    } else {
      await _offset.animateTo(
        out,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeIn,
      );
      if (!mounted) return;
      await _fold.forward();
    }
    if (!mounted) return;
    try {
      final result = action.onTrigger();
      if (result is Future) await result;
    } catch (_) {
      // The caller owns the error; the row comes back below if it stays.
    }
    // Still here: the caller kept the row (a request failed), so bring it
    // back. A row the caller dropped is gone by now.
    if (!mounted) return;
    _busy = false;
    _raw = 0;
    if (widget.reducedMotion) {
      _offset.value = 0;
      _fold.value = 0;
    } else {
      _offset.value = 0;
      await _fold.reverse();
    }
  }

  void _close() => _settleTo(0, 0);

  void _settleTo(double target, double velocity) {
    _raw = target;
    if (target == 0) {
      SwipeActionRow._open.remove(this);
    } else {
      SwipeActionRow._open.add(this);
    }
    if (widget.reducedMotion) {
      _offset.value = target;
    } else {
      _offset.animateWith(
        SpringSimulation(
          const SpringDescription(mass: 1, stiffness: 420, damping: 32),
          _offset.value,
          target,
          velocity,
        ),
      );
    }
    if (mounted) setState(() {});
  }

  Widget _capsule(SwipeAction action, double dx) {
    final leading = dx > 0;
    final width = (dx.abs() - SwipeActionRow.gap - SwipeActionRow.edgeInset)
        .clamp(0.0, double.infinity);
    final grown = (dx.abs() / SwipeActionRow.openOffset).clamp(0.0, 1.0);
    final armed = dx.abs() >= _fullAt;
    // The glyph grows in with the pull, and pops once letting go would run
    // the action.
    final scale = armed ? 1.18 : 0.55 + 0.45 * grown;
    final inset = SwipeActionRow.edgeInset - widget.bleed;
    return Positioned(
      left: leading ? inset : null,
      right: leading ? null : inset,
      top: 4,
      bottom: 4,
      width: width,
      child: Semantics(
        button: true,
        label: action.label,
        excludeSemantics: true,
        onTap: () => _run(action),
        child: GestureDetector(
          key: action.key ?? SwipeActionRow.capsuleKey(leading),
          behavior: HitTestBehavior.opaque,
          onTap: () => _run(action),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: action.color,
              borderRadius: BorderRadius.circular(999),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              // Loose both ways: the capsule's own size must not reach the
              // glyph (a drawn glyph like QuoteGlyph fills what it is given).
              child: OverflowBox(
                minWidth: 0,
                minHeight: 0,
                maxWidth: double.infinity,
                child: Opacity(
                  opacity: width < 28 ? 0 : 1,
                  child: AnimatedScale(
                    scale: scale,
                    duration: const Duration(milliseconds: 160),
                    curve: armed ? Curves.easeOutBack : Curves.easeOut,
                    child: action.icon,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lift = widget.liftColor ?? context.tokens.field;
    // Folds closed from the bottom, as a SizeTransition would, but clips only
    // past the bleed: the card and capsules draw out to the screen edge.
    final folded = CurvedAnimation(parent: _fold, curve: Curves.easeInOut);
    return AnimatedBuilder(
      animation: folded,
      builder: (context, child) => ClipRect(
        clipper: _BleedClipper(widget.bleed),
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: 1 - folded.value,
          child: child,
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          _width = constraints.maxWidth;
          final on = widget.enabled;
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: on ? _onStart : null,
            onHorizontalDragUpdate: on ? _onUpdate : null,
            onHorizontalDragEnd: on ? _onEnd : null,
            child: AnimatedBuilder(
              animation: _offset,
              child: widget.child,
              builder: (context, child) {
                final dx = _offset.value;
                final action = _actionFor(dx);
                // The card fades in over the first few points of the pull.
                final t = (dx.abs() / 32).clamp(0.0, 1.0);
                final bleed = widget.bleed;
                Widget card = Stack(
                  clipBehavior: Clip.none,
                  children: [
                    if (t > 0)
                      Positioned(
                        left: -bleed,
                        right: -bleed,
                        top: 0,
                        bottom: 0,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Color.lerp(
                              lift.withValues(alpha: 0),
                              lift,
                              t,
                            ),
                            borderRadius: BorderRadius.circular(
                              SwipeActionRow.cardRadius * t,
                            ),
                          ),
                        ),
                      ),
                    child!,
                  ],
                );
                // Resting open, a tap on the row only closes it.
                if (_isOpen) {
                  card = GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _close,
                    child: IgnorePointer(child: card),
                  );
                }
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    if (action != null) _capsule(action, dx),
                    Transform.translate(offset: Offset(dx, 0), child: card),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// The row's own box, widened by [bleed] on each side.
class _BleedClipper extends CustomClipper<Rect> {
  const _BleedClipper(this.bleed);

  final double bleed;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(-bleed, 0, size.width + bleed, size.height);

  @override
  bool shouldReclip(_BleedClipper oldClipper) => oldClipper.bleed != bleed;
}
