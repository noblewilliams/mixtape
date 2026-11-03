/// The one menu presentation in the app: an anchored popover
/// (`docs/mockups/approved/2026-11-03-mix-conversation-redesign.md` → Menus;
/// `.pop` on `docs/mockups/2026-11-03-mix-conversation-redesign.html`).
///
/// It replaces the bottom action sheets of smoke round three, note 8. That
/// choice was about grey Material boxes clashing with glass; this popover is
/// drawn in the sheet surface instead. It anchors to the control that opened
/// it, so callers pass that *control's* context (a `Builder` where needed).
/// Tapping outside dismisses it, so there is no Cancel row. Destructive
/// entries are red and sit last, behind a separator. Reduced transparency
/// makes it opaque.
///
/// Alerts keep their own call sites: `showCupertinoDialog` with a
/// `CupertinoAlertDialog`.
library;

import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';
import 'frosted_surface.dart';

/// One entry in a [showMixtapeMenu] popover.
@immutable
class MixtapeMenuAction<T> {
  const MixtapeMenuAction({
    required this.label,
    this.value,
    this.key,
    this.subtitle,
    this.isDestructive = false,
    this.enabled = true,
    this.isSelected = false,
    this.separatorBefore = false,
    this.leading,
    this.icon,
  });

  /// What the entry says.
  final String label;

  /// A second, quieter line under [label].
  final String? subtitle;

  /// What [showMixtapeMenu] returns when this entry is chosen.
  final T? value;

  /// The row's own key, so tests and automation find it.
  final Key? key;

  /// Drawn in the destructive red.
  final bool isDestructive;

  /// A disabled entry is dimmed and does nothing.
  final bool enabled;

  /// A checkable entry that is currently on: a trailing tick.
  final bool isSelected;

  /// Opens a new group: a 6 pt gap above this row.
  final bool separatorBefore;

  /// Drawn before the label (the shape menu's curves).
  final Widget? leading;

  /// A trailing glyph, in plum.
  final IconData? icon;
}

/// The popover itself, for tests.
const Key mixtapeMenuKey = Key('mixtape-menu');

/// The dimmed backdrop; tapping it dismisses the menu with null.
const Key mixtapeMenuBarrierKey = Key('mixtape-menu-barrier');

/// The raised copy of the row a long-press menu belongs to.
const Key mixtapeMenuLiftKey = Key('mixtape-menu-lift');

/// Presents [actions] in a popover anchored to [context]'s render box.
///
/// It opens below the anchor, or above it when there is no room, clamped to
/// the screen with 14 pt margins. When [context] has no laid-out box it sits
/// centred near the top of the screen.
///
/// [lifted], when given, builds a copy of the anchor that is drawn over the
/// dim at the anchor's place, as iOS context menus lift their row. The caller
/// decorates it; [MixtapeMenuLift] is the standard raised sheet-surface card.
///
/// Returns the chosen action's value, or null when the listener tapped
/// outside.
Future<T?> showMixtapeMenu<T>(
  BuildContext context, {
  required List<MixtapeMenuAction<T>> actions,
  String? title,
  String? message,
  WidgetBuilder? lifted,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final overlayBox = navigator.context.findRenderObject() as RenderBox?;
  final box = context.findRenderObject();
  Rect? anchor;
  if (box is RenderBox &&
      box.attached &&
      box.hasSize &&
      overlayBox != null &&
      overlayBox.hasSize) {
    anchor = box.localToGlobal(Offset.zero, ancestor: overlayBox) & box.size;
  }
  return navigator.push<T>(
    _MixtapeMenuRoute<T>(
      anchor: anchor,
      actions: actions,
      title: title,
      message: message,
      lifted: lifted,
      theme: Theme.of(context),
      reduceTransparency: FrostedSurfaceMode.of(context).reduceTransparency,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    ),
  );
}

/// The menu's geometry, from the board's `.pop`.
abstract final class MixtapeMenuMetrics {
  static const double radius = 14;
  static const double minWidth = 232;
  static const double maxWidth = 320;
  static const double rowHeight = MixtapeMetrics.minTarget;
  static const double screenMargin = 14;
  static const double anchorGap = 6;
  static const double separatorGap = 6;
  static const double sidePadding = 16;
}

class _MixtapeMenuRoute<T> extends PopupRoute<T> {
  _MixtapeMenuRoute({
    required this.anchor,
    required this.actions,
    required this.title,
    required this.message,
    required this.lifted,
    required this.theme,
    required this.reduceTransparency,
    required this.barrierLabel,
  });

  final Rect? anchor;
  final List<MixtapeMenuAction<T>> actions;
  final String? title;
  final String? message;
  final WidgetBuilder? lifted;
  final ThemeData theme;
  final bool reduceTransparency;

  @override
  final String barrierLabel;

  // The page draws its own keyed barrier so it can sit under the lifted row.
  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 180);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 120);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final media = MediaQuery.of(context);
    final dark = theme.brightness == Brightness.dark;
    final popover = _Popover<T>(
      actions: actions,
      title: title,
      message: message,
      reduceTransparency: reduceTransparency,
      onSelected: (value) => Navigator.of(context).pop(value),
    );
    final lift = lifted;
    final belowAnchor =
        anchor == null || anchor!.center.dy < media.size.height / 2;
    final reduceMotion = media.disableAnimations;
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeIn,
    );

    Widget menu = FadeTransition(opacity: curved, child: popover);
    if (!reduceMotion) {
      menu = ScaleTransition(
        scale: Tween<double>(begin: 0.92, end: 1).animate(curved),
        alignment: belowAnchor ? Alignment.topCenter : Alignment.bottomCenter,
        child: menu,
      );
    }

    return Theme(
      data: theme,
      child: FrostedSurfaceMode(
        reduceTransparency: reduceTransparency,
        child: Stack(
          children: [
            Positioned.fill(
              child: FadeTransition(
                opacity: curved,
                child: Semantics(
                  button: true,
                  label: barrierLabel,
                  onTap: () => Navigator.of(context).pop(),
                  excludeSemantics: true,
                  child: GestureDetector(
                    key: mixtapeMenuBarrierKey,
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(context).pop(),
                    child: ColoredBox(
                      color: dark
                          ? const Color.fromRGBO(0, 0, 0, 0.4)
                          : const Color.fromRGBO(20, 16, 20, 0.28),
                    ),
                  ),
                ),
              ),
            ),
            if (lift != null && anchor != null)
              Positioned.fromRect(
                rect: anchor!,
                child: IgnorePointer(
                  child: FadeTransition(
                    opacity: curved,
                    child: SizedBox.expand(
                      key: mixtapeMenuLiftKey,
                      child: Builder(builder: lift),
                    ),
                  ),
                ),
              ),
            Positioned.fill(
              child: CustomSingleChildLayout(
                delegate: _MenuLayout(anchor: anchor, padding: media.padding),
                child: menu,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The raised card a long-pressed row is drawn on over the menu's dim: the
/// sheet surface, 14 pt corners and a soft shadow (board section 5, "Long-press
/// on a row").
class MixtapeMenuLift extends StatelessWidget {
  const MixtapeMenuLift({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 10),
    this.radius = defaultRadius,
  });

  final Widget child;

  /// Breathing room inside the card, which bleeds out past the row's own box
  /// by the same amount so the row's content stays where it was.
  final EdgeInsets padding;

  /// The card's corners: the board's 14 pt, or a pill for a pill.
  final double radius;

  static const double defaultRadius = 14;

  @override
  Widget build(BuildContext context) {
    final tokens = _tokensOf(Theme.of(context));
    return Stack(
      clipBehavior: Clip.none,
      fit: StackFit.expand,
      children: [
        Positioned(
          left: -padding.left,
          top: -padding.top,
          right: -padding.right,
          bottom: -padding.bottom,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: tokens.sheetSurface,
              borderRadius: BorderRadius.circular(radius),
              boxShadow: [
                BoxShadow(
                  color: tokens.glassShadow,
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
          ),
        ),
        child,
      ],
    );
  }
}

MixtapeTokens _tokensOf(ThemeData theme) =>
    theme.extension<MixtapeTokens>() ??
    (theme.brightness == Brightness.dark
        ? MixtapeTokens.dark
        : MixtapeTokens.light);

/// Places the popover below [anchor], or above it when there is no room,
/// clamped to the screen's margins.
class _MenuLayout extends SingleChildLayoutDelegate {
  const _MenuLayout({required this.anchor, required this.padding});

  final Rect? anchor;
  final EdgeInsets padding;

  static const double _margin = MixtapeMenuMetrics.screenMargin;

  double _top(Size size) => padding.top + _margin;
  double _bottom(Size size) => size.height - padding.bottom - _margin;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final size = constraints.biggest;
    final maxWidth = math.max(
      0.0,
      math.min(MixtapeMenuMetrics.maxWidth, size.width - 2 * _margin),
    );
    return BoxConstraints(
      minWidth: math.min(MixtapeMenuMetrics.minWidth, maxWidth),
      maxWidth: maxWidth,
      maxHeight: math.max(0.0, _bottom(size) - _top(size)),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size child) {
    final top = _top(size);
    final bottom = _bottom(size);
    final maxX = math.max(_margin, size.width - _margin - child.width);
    final maxY = math.max(top, bottom - child.height);
    final a = anchor;
    if (a == null) {
      return Offset(
        ((size.width - child.width) / 2).clamp(_margin, maxX),
        (padding.top + 56).clamp(top, maxY),
      );
    }

    final x = a.center.dx > size.width / 2 ? a.right - child.width : a.left;

    final below = a.bottom + MixtapeMenuMetrics.anchorGap;
    final above = a.top - MixtapeMenuMetrics.anchorGap - child.height;
    final double y;
    if (below + child.height <= bottom) {
      y = below;
    } else if (above >= top) {
      y = above;
    } else {
      // Neither side fits whole: take the roomier side, then clamp.
      y = (bottom - a.bottom) >= (a.top - top) ? below : above;
    }
    return Offset(x.clamp(_margin, maxX), y.clamp(top, maxY));
  }

  @override
  bool shouldRelayout(_MenuLayout oldDelegate) =>
      anchor != oldDelegate.anchor || padding != oldDelegate.padding;
}

class _Popover<T> extends StatelessWidget {
  const _Popover({
    required this.actions,
    required this.title,
    required this.message,
    required this.reduceTransparency,
    required this.onSelected,
  });

  final List<MixtapeMenuAction<T>> actions;
  final String? title;
  final String? message;
  final bool reduceTransparency;
  final ValueChanged<T?> onSelected;

  @override
  Widget build(BuildContext context) {
    final tokens = _tokensOf(Theme.of(context));
    final radius = BorderRadius.circular(MixtapeMenuMetrics.radius);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final header = [?title, ?message];

    final children = <Widget>[
      if (header.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(
            MixtapeMenuMetrics.sidePadding,
            10,
            MixtapeMenuMetrics.sidePadding,
            8,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (title != null)
                Text(
                  title!,
                  style: tokens.meta.copyWith(
                    fontWeight: FontWeight.w600,
                    color: tokens.muted,
                  ),
                ),
              if (message != null)
                Text(
                  message!,
                  style: tokens.meta.copyWith(color: tokens.muted),
                ),
            ],
          ),
        ),
      for (var i = 0; i < actions.length; i++) ...[
        if (i > 0 || header.isNotEmpty)
          actions[i].separatorBefore
              ? SizedBox(
                  height: MixtapeMenuMetrics.separatorGap,
                  child: ColoredBox(color: tokens.hairline),
                )
              : Divider(height: 1, thickness: 0.5, color: tokens.hairline),
        MixtapeMenuItem<T>(
          key: actions[i].key,
          action: actions[i],
          onSelected: () => onSelected(actions[i].value),
        ),
      ],
    ];

    final fill = reduceTransparency
        ? tokens.sheetSurface
        : tokens.sheetSurface.withValues(alpha: dark ? 0.98 : 0.97);

    return Container(
      key: mixtapeMenuKey,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: radius,
        border: Border.all(
          color: dark
              ? const Color.fromRGBO(255, 255, 255, 0.08)
              : const Color.fromRGBO(0, 0, 0, 0.06),
          width: 0.5,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color.fromRGBO(20, 16, 24, 0.28),
            blurRadius: 50,
            offset: Offset(0, 18),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Material(
          type: MaterialType.transparency,
          child: SingleChildScrollView(
            child: IntrinsicWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: children,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One popover row: optional leading mark, the label and its second line, a
/// trailing tick when selected, and an optional trailing glyph.
class MixtapeMenuItem<T> extends StatefulWidget {
  const MixtapeMenuItem({super.key, required this.action, this.onSelected});

  final MixtapeMenuAction<T> action;
  final VoidCallback? onSelected;

  /// The tick a selected entry wears, for tests.
  static const Key tickKey = Key('mixtape-menu-tick');

  /// The board's destructive reds (`.pop .red`).
  static const Color destructiveLight = Color(0xFFC0392B);
  static const Color destructiveDark = Color(0xFFFF6B5E);

  @override
  State<MixtapeMenuItem<T>> createState() => _MixtapeMenuItemState<T>();
}

class _MixtapeMenuItemState<T> extends State<MixtapeMenuItem<T>> {
  bool _pressed = false;

  void _press(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final action = widget.action;
    final tokens = _tokensOf(Theme.of(context));
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = action.isDestructive
        ? (dark
              ? MixtapeMenuItem.destructiveDark
              : MixtapeMenuItem.destructiveLight)
        : tokens.text;
    final enabled = action.enabled;
    final subtitle = action.subtitle;
    final leading = action.leading;
    final icon = action.icon;
    final onTap = enabled ? widget.onSelected : null;

    final label = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          action.label,
          style: TextStyle(fontSize: 16, height: 1.25, color: ink),
        ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(
              subtitle,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.3,
                color: tokens.muted,
              ),
            ),
          ),
      ],
    );

    return Semantics(
      button: true,
      enabled: enabled,
      selected: action.isSelected,
      label: subtitle == null ? action.label : '${action.label}. $subtitle',
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: onTap == null ? null : (_) => _press(true),
        onTapCancel: () => _press(false),
        onTapUp: (_) => _press(false),
        onTap: onTap,
        child: ColoredBox(
          color: _pressed ? tokens.hairline : Colors.transparent,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: MixtapeMenuMetrics.rowHeight,
            ),
            child: Opacity(
              opacity: enabled ? 1 : 0.4,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: MixtapeMenuMetrics.sidePadding,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    if (leading != null) ...[
                      leading,
                      const SizedBox(width: 12),
                    ],
                    Expanded(child: label),
                    if (action.isSelected) ...[
                      const SizedBox(width: 12),
                      Icon(
                        CupertinoIcons.check_mark,
                        key: MixtapeMenuItem.tickKey,
                        size: 17,
                        color: tokens.plum,
                      ),
                    ],
                    if (icon != null) ...[
                      const SizedBox(width: 16),
                      Icon(
                        icon,
                        size: 19,
                        color: ink == tokens.text ? tokens.plum : ink,
                      ),
                    ],
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
