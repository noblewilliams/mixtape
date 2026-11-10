/// Trailing swipe actions, the way iOS Mail and WhatsApp do them (founder,
/// 2026-11-09): drag a row left and its actions slide in behind it; let go
/// past halfway and the row stays open, so the choice is made with a tap; drag
/// all the way across and the last action fires on its own.
///
/// It replaces the Mixes tab's `Dismissible`, which archived the moment the
/// swipe ended and left no room to change your mind.
library;

import 'dart:async';

import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart' show HapticFeedback;

/// One action behind a row.
@immutable
class SwipeAction {
  const SwipeAction({
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
    this.foreground = Colors.white,
    this.commits = false,
    this.key,
  });

  final String label;
  final IconData icon;

  /// The panel's fill.
  final Color color;
  final Color foreground;

  /// Runs when the panel is tapped, or on a full swipe for the last action.
  final FutureOr<void> Function() onPressed;

  /// Whether the action takes the row away (Archive). The row slides fully
  /// across while it runs and comes back only if the row is still there
  /// afterwards — a failed request. Otherwise the row closes first, so a menu
  /// opened by the action anchors to the row at rest.
  final bool commits;

  /// The panel's own key, for tests.
  final Key? key;
}

/// A row with [actions] behind its trailing edge.
class SwipeActions extends StatefulWidget {
  const SwipeActions({
    super.key,
    required this.child,
    required this.actions,
    this.enabled = true,
    this.fullSwipe = true,
    this.bleed = 0,
  }) : assert(actions.length > 0, 'a swipe needs at least one action');

  final Widget child;

  /// In reading order. The last sits against the trailing edge and is the one
  /// a full swipe fires.
  final List<SwipeAction> actions;

  /// False while the row is busy or being edited: no swipe, and an open row
  /// closes.
  final bool enabled;

  /// Whether dragging all the way across fires the last action.
  final bool fullSwipe;

  /// How far past its own edges the row may draw: a row inset by the screen's
  /// side padding slides out under the screen edge, and the last panel's
  /// colour runs to it, as a full-bleed table row does. A tap in the trailing
  /// bleed of an open row counts as a tap on the last panel; that needs a
  /// [SwipeActionsGroup] above, which sees touches outside the row.
  final double bleed;

  /// Each panel's width once the row is open.
  static const double actionWidth = 76;

  /// How far across, as a share of the row's width, a drag arms the full
  /// swipe.
  static const double fullSwipeFraction = 0.62;

  /// Opening, closing and the full-swipe slide.
  static const Duration settleDuration = Duration(milliseconds: 260);

  /// A fling faster than this opens or closes the row whatever its position.
  static const double flingVelocity = 500;

  /// Labels stop growing here so a panel keeps its shape at large text sizes.
  static const double maxLabelScale = 1.3;

  @override
  State<SwipeActions> createState() => SwipeActionsState();
}

/// Public so [SwipeActionsGroup] can close the open row.
class SwipeActionsState extends State<SwipeActions>
    with TickerProviderStateMixin {
  /// The row's horizontal offset in logical pixels: 0 at rest, negative while
  /// the actions show.
  late final AnimationController _offset = AnimationController.unbounded(
    vsync: this,
  );

  /// 0 → 1 as the last action takes over the whole strip on a full swipe.
  late final AnimationController _takeover = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
  );

  double _width = 0;
  bool _armed = false;
  bool _committing = false;
  SwipeActionsGroupState? _group;

  double get _openExtent => SwipeActions.actionWidth * widget.actions.length;

  /// Whether the actions are showing and the row is waiting on a tap.
  bool get isOpen => _offset.value < 0 && !_committing;

  Duration get _duration => MediaQuery.disableAnimationsOf(context)
      ? Duration.zero
      : SwipeActions.settleDuration;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final group = SwipeActionsGroup._maybeOf(context);
    if (group != _group) {
      _group?._forget(this);
      _group = group;
    }
  }

  @override
  void didUpdateWidget(SwipeActions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled && oldWidget.enabled && !_committing) close();
  }

  @override
  void dispose() {
    _group?._forget(this);
    _offset.dispose();
    _takeover.dispose();
    super.dispose();
  }

  /// Slides the row back to rest.
  Future<void> close() async {
    if (!mounted) return;
    _group?._forget(this);
    _setArmed(false, haptic: false);
    if (_offset.value == 0) return;
    await _offset.animateTo(0, duration: _duration, curve: Curves.easeOutCubic);
  }

  Future<void> _open() async {
    _group?._opened(this);
    _setArmed(false, haptic: false);
    await _offset.animateTo(
      -_openExtent,
      duration: _duration,
      curve: Curves.easeOutCubic,
    );
  }

  void _setArmed(bool armed, {bool haptic = true}) {
    if (armed == _armed) return;
    _armed = armed;
    if (haptic) HapticFeedback.mediumImpact();
    if (MediaQuery.disableAnimationsOf(context)) {
      _takeover.value = armed ? 1 : 0;
    } else if (armed) {
      _takeover.forward();
    } else {
      _takeover.reverse();
    }
  }

  void _dragStart(DragStartDetails details) {
    _offset.stop();
    _group?._opened(this);
  }

  void _dragUpdate(DragUpdateDetails details) {
    final delta = details.primaryDelta ?? 0;
    var next = _offset.value + delta;
    if (next > 0) next = 0;
    final pastOpen = -next - _openExtent;
    if (!widget.fullSwipe && pastOpen > 0) {
      // No full swipe: the row stretches a little past open, then stops.
      next = -_openExtent - pastOpen * 0.25;
    }
    if (_width > 0 && -next > _width) next = -_width;
    _offset.value = next;
    if (widget.fullSwipe && _width > 0) {
      _setArmed(-next >= _fullSwipeAt);
    }
  }

  double get _fullSwipeAt => (_width * SwipeActions.fullSwipeFraction).clamp(
    _openExtent + SwipeActions.actionWidth / 2,
    double.infinity,
  );

  void _dragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (_armed) {
      _run(widget.actions.length - 1);
    } else if (velocity <= -SwipeActions.flingVelocity) {
      _open();
    } else if (velocity >= SwipeActions.flingVelocity) {
      close();
    } else if (-_offset.value >= _openExtent / 2) {
      _open();
    } else {
      close();
    }
  }

  /// Runs the action at [index]. By position, not identity: the row above
  /// builds fresh actions every time it rebuilds.
  Future<void> _run(int index) async {
    if (_committing || index >= widget.actions.length) return;
    final action = widget.actions[index];
    if (!action.commits) {
      unawaited(close());
      await action.onPressed();
      return;
    }
    _committing = true;
    _group?._forget(this);
    // The last action takes the strip, and the row slides fully across while
    // the parent decides; success removes the row, failure brings it back.
    if (index == widget.actions.length - 1) {
      _armed = true;
      if (MediaQuery.disableAnimationsOf(context)) {
        _takeover.value = 1;
      } else {
        _takeover.forward();
      }
    }
    unawaited(
      _offset.animateTo(
        -_width,
        duration: _duration,
        curve: Curves.easeOutCubic,
      ),
    );
    try {
      await action.onPressed();
    } finally {
      if (mounted) {
        _committing = false;
        await close();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final actions = widget.actions;
    final semantics = <CustomSemanticsAction, VoidCallback>{
      for (var i = 0; i < actions.length; i++)
        CustomSemanticsAction(label: actions[i].label): () => _run(i),
    };

    return Semantics(
      customSemanticsActions: widget.enabled ? semantics : null,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _width = constraints.maxWidth;
          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: widget.enabled ? _dragStart : null,
            onHorizontalDragUpdate: widget.enabled ? _dragUpdate : null,
            onHorizontalDragEnd: widget.enabled ? _dragEnd : null,
            child: ClipRect(
              clipper: _BleedClipper(widget.bleed),
              child: AnimatedBuilder(
                animation: Listenable.merge([_offset, _takeover]),
                builder: (context, child) {
                  final offset = _offset.value;
                  final open = offset < 0;
                  // One shape open or shut, so the row underneath keeps its
                  // state as the swipe starts and ends.
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned(
                        top: 0,
                        bottom: 0,
                        right: -widget.bleed,
                        width: open ? -offset + widget.bleed : 0,
                        child: open
                            ? _panels(context, -offset)
                            : const SizedBox.shrink(),
                      ),
                      Transform.translate(
                        offset: Offset(offset, 0),
                        // An open row closes on a tap rather than opening
                        // what it holds.
                        child: GestureDetector(
                          behavior: open
                              ? HitTestBehavior.opaque
                              : HitTestBehavior.deferToChild,
                          onTap: open ? close : null,
                          child: IgnorePointer(ignoring: open, child: child),
                        ),
                      ),
                    ],
                  );
                },
                child: _GroupGuard(state: this, child: widget.child),
              ),
            ),
          );
        },
      ),
    );
  }

  /// The strip behind the row, [revealed] wide inside the row plus the bleed.
  /// Panels share it evenly until a full swipe arms, when the last one takes
  /// all of it.
  Widget _panels(BuildContext context, double revealed) {
    final actions = widget.actions;
    final n = actions.length;
    final t = Curves.easeOut.transform(_takeover.value);
    final even = revealed / n;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: SwipeActions.maxLabelScale,
      child: Row(
        children: [
          for (var i = 0; i < n; i++)
            if (i == n - 1)
              SizedBox(
                width: even + (revealed - even) * t + widget.bleed,
                child: _panel(i, inside: even + (revealed - even) * t),
              )
            else
              SizedBox(
                width: even * (1 - t),
                child: _panel(i, inside: even * (1 - t)),
              ),
        ],
      ),
    );
  }

  /// One panel; its label sits in the [inside] part, clear of the bleed.
  Widget _panel(int index, {required double inside}) {
    final action = widget.actions[index];
    // At rest each label centres in its panel; a panel stretched past its
    // width (the full swipe) keeps it by the row's edge.
    final wide = inside > SwipeActions.actionWidth;
    return Semantics(
      // The row's custom actions already carry these to a screen reader.
      excludeSemantics: true,
      child: GestureDetector(
        key: action.key,
        behavior: HitTestBehavior.opaque,
        onTap: () => _run(index),
        child: ColoredBox(
          color: action.color,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: inside,
              child: ClipRect(
                child: OverflowBox(
                  alignment: wide ? Alignment.centerLeft : Alignment.center,
                  minWidth: SwipeActions.actionWidth,
                  maxWidth: SwipeActions.actionWidth,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(action.icon, size: 22, color: action.foreground),
                      const SizedBox(height: 4),
                      Text(
                        action.label,
                        maxLines: 1,
                        overflow: TextOverflow.clip,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: action.foreground,
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
  }
}

/// The row's clip, widened by the bleed on both sides.
class _BleedClipper extends CustomClipper<Rect> {
  const _BleedClipper(this.bleed);

  final double bleed;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTRB(-bleed, 0, size.width + bleed, size.height);

  @override
  bool shouldReclip(_BleedClipper oldClipper) => oldClipper.bleed != bleed;
}

/// While another row in the group is open, this row's tap closes that one
/// instead of opening this one — iOS's rule for swiped table rows.
class _GroupGuard extends StatelessWidget {
  const _GroupGuard({required this.state, required this.child});

  final SwipeActionsState state;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final group = SwipeActionsGroup._maybeOf(context);
    if (group == null) return child;
    return ListenableBuilder(
      listenable: group._openRow,
      builder: (context, child) {
        final other = group._openRow.value;
        final guarded = other != null && other != state;
        return GestureDetector(
          behavior: guarded
              ? HitTestBehavior.opaque
              : HitTestBehavior.deferToChild,
          onTap: guarded ? group.closeAll : null,
          child: IgnorePointer(ignoring: guarded, child: child),
        );
      },
      child: child,
    );
  }
}

/// Keeps at most one [SwipeActions] open below it, and closes the open one
/// when the list scrolls or a touch lands anywhere else — wrap the scroll
/// view, not the sliver, so its scroll notifications pass through here.
class SwipeActionsGroup extends StatefulWidget {
  const SwipeActionsGroup({super.key, required this.child});

  final Widget child;

  static SwipeActionsGroupState? _maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SwipeActionsScope>()?.state;

  @override
  State<SwipeActionsGroup> createState() => SwipeActionsGroupState();
}

class SwipeActionsGroupState extends State<SwipeActionsGroup> {
  final ValueNotifier<SwipeActionsState?> _openRow = ValueNotifier(null);

  /// A touch that landed in the open row's trailing bleed: it counts as a
  /// tap on the last panel if it lifts where it went down.
  int? _bleedPointer;
  Offset? _bleedDown;

  /// Closes whichever row is open.
  void closeAll() {
    final open = _openRow.value;
    _setOpenRow(null);
    open?.close();
  }

  void _opened(SwipeActionsState row) {
    final previous = _openRow.value;
    if (previous == row) return;
    _setOpenRow(row);
    previous?.close();
  }

  void _forget(SwipeActionsState row) {
    if (_openRow.value == row) _setOpenRow(null);
  }

  /// The other rows rebuild when this changes, which they cannot do while the
  /// tree is building or locked (a row closing as it is disposed, or as its
  /// parent disables it): then the change waits for the end of the frame.
  void _setOpenRow(SwipeActionsState? row) {
    final binding = SchedulerBinding.instance;
    if (binding.schedulerPhase != SchedulerPhase.persistentCallbacks) {
      _openRow.value = row;
      return;
    }
    final expected = _openRow.value;
    binding.addPostFrameCallback((_) {
      if (!mounted || _openRow.value != expected) return;
      _openRow.value = row != null && !row.mounted ? null : row;
    });
  }

  void _pointerDown(PointerDownEvent event) {
    final open = _openRow.value;
    if (open == null || !open.mounted) return;
    final box = open.context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final local = box.globalToLocal(event.position);
    if ((Offset.zero & box.size).contains(local)) return;
    final bleed = open.widget.bleed;
    final inBleed =
        bleed > 0 &&
        local.dy >= 0 &&
        local.dy <= box.size.height &&
        local.dx > box.size.width &&
        local.dx <= box.size.width + bleed;
    if (inBleed) {
      // The panel paints out here but its box stops at the row's edge.
      _bleedPointer = event.pointer;
      _bleedDown = event.position;
      return;
    }
    closeAll();
  }

  void _pointerUp(PointerUpEvent event) {
    if (event.pointer != _bleedPointer) return;
    final down = _bleedDown;
    _bleedPointer = null;
    _bleedDown = null;
    final open = _openRow.value;
    if (down == null || open == null || !open.mounted || !open.isOpen) return;
    if ((event.position - down).distance > kTouchSlop) return;
    open._run(open.widget.actions.length - 1);
  }

  void _pointerCancel(PointerCancelEvent event) {
    if (event.pointer != _bleedPointer) return;
    _bleedPointer = null;
    _bleedDown = null;
  }

  @override
  void dispose() {
    _openRow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _SwipeActionsScope(
    state: this,
    child: Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _pointerDown,
      onPointerUp: _pointerUp,
      onPointerCancel: _pointerCancel,
      child: NotificationListener<ScrollUpdateNotification>(
        onNotification: (notification) {
          // Only when the list really moves: a touch on it can raise a scroll
          // start with no scroll, and a row's own swipe raises none.
          if (notification.metrics.axis == Axis.vertical &&
              (notification.scrollDelta ?? 0) != 0) {
            closeAll();
          }
          return false;
        },
        child: widget.child,
      ),
    ),
  );
}

class _SwipeActionsScope extends InheritedWidget {
  const _SwipeActionsScope({required this.state, required super.child});

  final SwipeActionsGroupState state;

  @override
  bool updateShouldNotify(_SwipeActionsScope oldWidget) =>
      oldWidget.state != state;
}
