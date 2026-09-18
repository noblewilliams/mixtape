import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';

/// A native inset-grouped list: one rounded surface holding [InsetRow]s
/// separated by an inset hairline.
///
/// `docs/mockups/2026-09-17-mobile-shell-r3.html` → `.group`, `.grow`.
class InsetGroup extends StatelessWidget {
  const InsetGroup({
    super.key,
    required this.children,
    this.header,
    this.outlined = false,
  });

  final List<Widget> children;

  /// Usually a `SectionWord`, drawn above the surface.
  final Widget? header;

  /// Draws a hairline around the rounded surface, so a group reads as a card
  /// rather than a tint — the import review's file entries (founder, smoke
  /// round seven, note 2). Off everywhere else, which is the board's own
  /// borderless group.
  final bool outlined;

  /// The rule between rows.
  static const Key hairlineKey = Key('inset-group-hairline');

  /// The hairline's inset and the minimum row height.
  static const double rowInset = 52;

  /// The board's gap below a group, so stacked groups breathe (`.group`).
  static const double bottomMargin = 16;

  /// The board's group fill: light white at 62%, dark white at 8%.
  static Color surfaceColorFor(Brightness brightness) =>
      brightness == Brightness.dark
      ? const Color.fromRGBO(255, 255, 255, 0.08)
      : const Color.fromRGBO(255, 255, 255, 0.62);

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(
          Padding(
            padding: const EdgeInsets.only(left: rowInset),
            child: Container(
              key: hairlineKey,
              height: 1,
              color: tokens.hairline,
            ),
          ),
        );
      }
      rows.add(children[i]);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (header != null) header!,
        Container(
          margin: const EdgeInsets.only(bottom: bottomMargin),
          decoration: BoxDecoration(
            color: surfaceColorFor(Theme.of(context).brightness),
            borderRadius: BorderRadius.circular(MixtapeMetrics.groupRadius),
            border: outlined
                ? Border.all(color: tokens.hairline, width: 1)
                : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(MixtapeMetrics.groupRadius),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: rows,
            ),
          ),
        ),
      ],
    );
  }
}

/// One row inside an [InsetGroup].
class InsetRow extends StatelessWidget {
  const InsetRow({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.destructive = false,
  });

  /// An icon, drawn in plum at 22 pt.
  final Widget? leading;

  final String title;
  final String? subtitle;

  /// Replaces the default chevron.
  final Widget? trailing;

  final VoidCallback? onTap;

  /// Draws the title in err ink (Sign out, Forget, Delete).
  final bool destructive;

  /// The row's own vertical padding.
  static const double verticalPadding = 12;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final end =
        trailing ??
        (onTap == null
            ? null
            : Icon(
                Icons.chevron_right,
                size: 18,
                color: tokens.muted.withValues(alpha: 0.6),
              ));

    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: InsetGroup.rowInset),
      child: Padding(
        // 12, not 8: looser rows to go with the smaller type (smoke round
        // three, note 4).
        padding: const EdgeInsets.symmetric(
          vertical: InsetRow.verticalPadding,
          horizontal: 16,
        ),
        child: Row(
          children: [
            if (leading != null) ...[
              IconTheme.merge(
                data: IconThemeData(size: 22, color: tokens.plum),
                child: leading!,
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: destructive
                        ? tokens.rowTitle.copyWith(color: tokens.errInk)
                        : tokens.rowTitle,
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: tokens.meta.copyWith(fontSize: 12.5),
                    ),
                ],
              ),
            ),
            if (end != null) ...[const SizedBox(width: 12), end],
          ],
        ),
      ),
    );

    if (onTap == null) return row;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(onTap: onTap, child: row),
    );
  }
}
