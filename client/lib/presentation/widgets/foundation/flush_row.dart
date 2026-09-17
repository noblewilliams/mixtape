import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';

/// Stacks [FlushRow]s and tells each whether it is the first, so the hairline
/// falls between rows and never above the list.
///
/// `docs/mockups/2026-09-17-mobile-shell-r3.html` → `.list`, `.row`.
class FlushList extends StatelessWidget {
  const FlushList({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < children.length; i++)
        FlushRowPosition(isFirst: i == 0, child: children[i]),
    ],
  );
}

/// Carries a row's place in its list down to [FlushRow].
class FlushRowPosition extends InheritedWidget {
  const FlushRowPosition({
    super.key,
    required this.isFirst,
    required super.child,
  });

  final bool isFirst;

  /// Null when no list wraps the row, so [FlushRow] can tell "first" apart
  /// from "built lazily, position unknown".
  static bool? maybeIsFirstOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FlushRowPosition>()?.isFirst;

  @override
  bool updateShouldNotify(FlushRowPosition oldWidget) =>
      oldWidget.isFirst != isFirst;
}

/// A flush list row: no background, no card, a hairline between rows only.
class FlushRow extends StatelessWidget {
  const FlushRow({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.subtitleWidget,
    this.trailing,
    this.onTap,
    this.leadingSize = 60,
    this.inset = true,
    this.isFirst,
  });

  final Widget leading;
  final String title;
  final String? subtitle;

  /// Takes precedence over [subtitle] (a status word, a meta line with ink).
  final Widget? subtitleWidget;

  /// Replaces the default chevron.
  final Widget? trailing;

  final VoidCallback? onTap;

  /// The leading column's width; also the hairline's inset.
  final double leadingSize;

  /// Whether the hairline is inset past the leading column.
  final bool inset;

  /// Whether this row opens its list, and so draws no hairline above itself.
  ///
  /// Defaults to the enclosing [FlushList]'s answer. A row built lazily — in a
  /// `ListView.builder`, where there is no [FlushRowPosition] — draws the
  /// hairline unless the builder passes `isFirst: index == 0`.
  final bool? isFirst;

  /// The 1 px rule drawn at the top of every row but the first.
  static const Key hairlineKey = Key('flush-row-hairline');

  /// The gap between the leading column and the text.
  static const double gap = 14;

  /// Titles wrap rather than ellipsise from this text scale up.
  static const double wrapScale = 1.5;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final scale = MediaQuery.textScalerOf(context).scale(100) / 100;
    final wraps = scale >= wrapScale;
    final subtitleLine =
        subtitleWidget ??
        (subtitle == null
            ? null
            : Text(
                subtitle!,
                style: tokens.meta.copyWith(
                  fontSize: 12.5,
                  color: tokens.muted,
                ),
                maxLines: wraps ? null : 1,
                overflow: wraps ? null : TextOverflow.ellipsis,
              ));
    final end =
        trailing ??
        (onTap == null
            ? null
            : Icon(
                Icons.chevron_right,
                size: 20,
                color: tokens.muted.withValues(alpha: 0.6),
              ));

    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          leading,
          const SizedBox(width: gap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: tokens.rowTitle,
                  maxLines: wraps ? null : 1,
                  overflow: wraps ? null : TextOverflow.ellipsis,
                ),
                if (subtitleLine != null) ...[
                  const SizedBox(height: 2),
                  subtitleLine,
                ],
              ],
            ),
          ),
          if (end != null) ...[const SizedBox(width: 8), end],
        ],
      ),
    );

    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: MixtapeMetrics.minTarget),
      child: Stack(
        children: [
          if (!(isFirst ?? FlushRowPosition.maybeIsFirstOf(context) ?? false))
            Positioned(
              left: inset ? leadingSize + gap : 0,
              right: 0,
              top: 0,
              child: Container(
                key: hairlineKey,
                height: 1,
                color: tokens.hairline,
              ),
            ),
          content,
        ],
      ),
    );

    if (onTap == null) return row;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(onTap: onTap, child: row),
    );
  }
}
