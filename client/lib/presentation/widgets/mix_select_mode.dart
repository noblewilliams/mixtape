/// Select mode's own pieces on the Mixes tab and its Archived screen
/// (`docs/mockups/approved/2026-11-16-select-delete-mixes.md`; frames S1–S10
/// on `docs/mockups/2026-11-16-select-delete-mixes.html`, section 1): the
/// tick circle that leads each own row, the glass toolbar that takes the
/// dock's place, and the copy both screens share.
library;

import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../theme/mixtape_theme.dart';
import 'foundation/glass_segmented_control.dart';
import 'foundation/haptics.dart';
import 'foundation/liquid_glass_surface.dart';
import 'foundation/mixtape_menu.dart';

/// Keys, sizes and copy.
abstract final class MixSelect {
  /// The nav bar's ⋯ and its one item.
  static const Key moreKey = Key('mix-select-more');
  static const String moreLabel = 'More';
  static const String selectMixesLabel = 'Select mixes';
  static const Key selectMixesKey = Key('mix-select-select-mixes');

  /// Select mode's nav bar.
  static const Key selectAllKey = Key('mix-select-all');
  static const Key doneKey = Key('mix-select-done');
  static const String selectAllLabel = 'Select all';
  static const String deselectAllLabel = 'Deselect all';
  static const String doneLabel = 'Done';

  /// The toolbar.
  static const Key toolbarKey = Key('mix-select-toolbar');
  static const Key archiveKey = Key('mix-select-archive');
  static const Key deleteKey = Key('mix-select-delete');
  static const Key countKey = Key('mix-select-count');
  static const String archiveLabel = 'Archive';
  static const String unarchiveLabel = 'Unarchive';
  static const String deleteLabel = 'Delete';

  /// The confirm's buttons.
  static const Key confirmDeleteKey = Key('mix-select-confirm-delete');
  static const Key cancelKey = Key('mix-select-cancel');
  static const String cancelLabel = 'Cancel';

  /// The signed-out popover.
  static const String signInTitle = 'Sign in to delete mixes';
  static const String signInLine =
      'Mixes made before you sign in can be archived, not deleted.';
  static const String signInLabel = 'Sign in';
  static const String notNowLabel = 'Not now';
  static const Key signInKey = Key('mix-select-sign-in');
  static const Key notNowKey = Key('mix-select-not-now');

  static const String goneLine =
      'They’re gone for good, with their chats and versions. '
      'This can’t be undone.';
  static const String sharedLine = 'Their share links will stop working.';
  static const String workingLine = 'The one being made will stop.';
  static const String deleteFailed = 'Couldn’t delete. Try again.';

  /// A row in select mode, and its circle.
  static Key rowKey(String id) => ValueKey('mix-select-row-$id');
  static Key circleKey(String id) => ValueKey('mix-select-circle-$id');

  /// The column the circle takes at the row's leading edge (board `.mx.sel`).
  static const double slotWidth = 34;

  /// The circle itself (board `.tick`).
  static const double circleSize = 24;

  /// A row being deleted, while the server answers (board `.mx.gone`).
  static const double fadingOpacity = 0.25;

  /// A row select mode cannot tick: a shared mix, a mix still being started
  /// (board `.mx.off`).
  static const double offOpacity = 0.38;

  /// The toolbar's place: where the tab bar sits.
  static const double toolbarHeight = MixtapeMetrics.tabBarHeight;
  static const double toolbarBottomGap = 8;

  static String confirmTitle(int count) =>
      count == 1 ? 'Delete this mix?' : 'Delete $count mixes?';
  static String confirmAction(int count) =>
      count == 1 ? 'Delete mix' : 'Delete $count mixes';
  static String deleted(int count) =>
      count == 1 ? 'Mix deleted' : '$count mixes deleted';
  static String archived(int count, {required bool unarchive}) {
    final word = unarchive ? 'unarchived' : 'archived';
    return count == 1 ? 'Mix $word' : '$count mixes $word';
  }

  /// The toolbar's middle, and what VoiceOver hears when it changes.
  static String count(int count) => '$count selected';
}

/// The tick circle: an empty ring, or filled plum with a check (light plum
/// with a dark check in dark mode), so the state never rests on colour
/// alone. Decorative: the row says "selected" for it.
class MixSelectCircle extends StatelessWidget {
  const MixSelectCircle({super.key, required this.selected});

  final bool selected;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ExcludeSemantics(
      child: Container(
        width: MixSelect.circleSize,
        height: MixSelect.circleSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: selected ? tokens.plum : null,
          border: Border.all(
            color: selected ? tokens.plum : tokens.muted,
            width: 1.6,
          ),
        ),
        child: selected
            ? Icon(
                CupertinoIcons.checkmark,
                size: 14,
                color: dark ? const Color(0xFF1C1A1E) : Colors.white,
              )
            : null,
      ),
    );
  }
}

/// A row select mode cannot tick (a shared mix, a mix still being started):
/// dimmed, in line with the ticking rows, and deaf to touch.
class MixSelectOffRow extends StatelessWidget {
  const MixSelectOffRow({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const SizedBox(width: MixSelect.slotWidth),
      Expanded(
        child: IgnorePointer(
          child: Opacity(opacity: MixSelect.offOpacity, child: child),
        ),
      ),
    ],
  );
}

/// The glass toolbar that replaces the dock while selecting (board S2/S3):
/// Archive (or Unarchive) · "N selected" · Delete in the destructive red.
/// Archive and Delete are disabled at zero. Labels stop growing at the
/// segmented control's cap; where even then all three would not fit, the
/// count drops out first (S9).
class MixSelectToolbar extends StatelessWidget {
  const MixSelectToolbar({
    super.key,
    required this.count,
    required this.unarchive,
    required this.onArchive,
    required this.onDelete,
  });

  final int count;

  /// On Archived: Unarchive in Archive's place.
  final bool unarchive;
  final VoidCallback onArchive;

  /// Handed the Delete button's own context, so the confirm anchors to it.
  final ValueChanged<BuildContext> onDelete;

  static const double _actionPadding = 16;
  static const double _glyph = 20;
  static const double _glyphGap = 7;

  static TextStyle _labelStyle(BuildContext context) => Theme.of(context)
      .textTheme
      .bodyMedium!
      .merge(const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600));

  static TextStyle _countStyle(BuildContext context) => Theme.of(context)
      .textTheme
      .bodyMedium!
      .merge(const TextStyle(fontSize: 13, fontWeight: FontWeight.w600));

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final enabled = count > 0;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final red = dark
        ? MixtapeMenuItem.destructiveDark
        : MixtapeMenuItem.destructiveLight;
    final scaler = MediaQuery.textScalerOf(
      context,
    ).clamp(maxScaleFactor: GlassSegmentedControl.maxTextScale);
    final archiveLabel = unarchive
        ? MixSelect.unarchiveLabel
        : MixSelect.archiveLabel;
    final countText = enabled
        ? MixSelect.count(count)
        : MixSelect.selectMixesLabel;

    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: scaler),
      child: LiquidGlassSurface(
        key: MixSelect.toolbarKey,
        borderRadius: BorderRadius.circular(MixSelect.toolbarHeight / 2),
        child: SizedBox(
          height: MixSelect.toolbarHeight,
          child: LayoutBuilder(
            builder: (context, constraints) {
              double width(String text, TextStyle style) {
                final painter = TextPainter(
                  text: TextSpan(text: text, style: style),
                  textDirection: TextDirection.ltr,
                  textScaler: scaler,
                  maxLines: 1,
                )..layout();
                final w = painter.width;
                painter.dispose();
                return w;
              }

              double action(String label) =>
                  2 * _actionPadding +
                  _glyph +
                  _glyphGap +
                  width(label, _labelStyle(context));
              // `1fr auto 1fr`: the wider action sets both sides.
              final side = math.max(
                action(archiveLabel),
                action(MixSelect.deleteLabel),
              );
              final needed =
                  2 * side + width(countText, _countStyle(context)) + 8;
              final showCount = needed <= constraints.maxWidth;
              return Padding(
                padding: const EdgeInsets.all(4),
                child: Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: _ToolbarAction(
                            key: MixSelect.archiveKey,
                            icon: CupertinoIcons.archivebox,
                            label: archiveLabel,
                            ink: tokens.plum,
                            muted: tokens.muted,
                            // Archiving the selection happens at once.
                            haptic: HapticKind.destructive,
                            onPressed: enabled ? onArchive : null,
                          ),
                        ),
                      ),
                    ),
                    if (showCount)
                      Text(
                        countText,
                        key: MixSelect.countKey,
                        maxLines: 1,
                        style: _countStyle(
                          context,
                        ).copyWith(color: tokens.smoke),
                      ),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Builder(
                            builder: (anchor) => _ToolbarAction(
                              key: MixSelect.deleteKey,
                              icon: MixMenuIcons.eject,
                              label: MixSelect.deleteLabel,
                              ink: red,
                              muted: tokens.muted,
                              // Presents the confirm; its Delete plays the
                              // destructive one.
                              haptic: HapticKind.open,
                              onPressed: enabled
                                  ? () => onDelete(anchor)
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ToolbarAction extends StatelessWidget {
  const _ToolbarAction({
    super.key,
    required this.icon,
    required this.label,
    required this.ink,
    required this.muted,
    required this.haptic,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final Color ink;
  final Color muted;
  final HapticKind haptic;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final onPressed = Haptics.on(haptic, this.onPressed);
    final enabled = onPressed != null;
    final color = enabled ? ink : muted.withValues(alpha: 0.55);
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MixSelectToolbar._actionPadding,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: MixSelectToolbar._glyph, color: color),
                const SizedBox(width: MixSelectToolbar._glyphGap),
                Text(
                  label,
                  maxLines: 1,
                  style: MixSelectToolbar._labelStyle(
                    context,
                  ).copyWith(color: color),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
