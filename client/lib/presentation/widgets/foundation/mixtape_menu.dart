/// The one menu presentation in the app (smoke round three, note 8).
///
/// Every anchored Material popup — `showMenu`, `PopupMenuButton` — has been
/// replaced by a native action sheet: the founder found the boxes that dropped
/// out of a glass button clashed with everything around them. A menu is a
/// [CupertinoActionSheet] over a [showCupertinoModalPopup] barrier, destructive
/// entries in red, and always a Cancel.
///
/// Alerts go the same way but keep their own call sites: `showCupertinoDialog`
/// with a `CupertinoAlertDialog`.
library;

import 'package:flutter/cupertino.dart';

/// One entry in a [showMixtapeMenu] sheet.
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
  });

  /// What the entry says. Kept word for word from the menu it replaces.
  final String label;

  /// A second, quieter line under [label] — the promise a long entry carried
  /// in its Material item.
  final String? subtitle;

  /// What [showMixtapeMenu] returns when this entry is chosen.
  final T? value;

  /// The item's own key, kept from the menu it replaces so tests and
  /// automation still find it.
  final Key? key;

  /// Drawn in the destructive red and, on iOS, announced as such.
  final bool isDestructive;

  /// A disabled entry is dimmed and does nothing, as `enabled: false` did.
  final bool enabled;

  /// A checkable entry that is currently on: marked with a leading tick, the
  /// action sheet's stand-in for `CheckedPopupMenuItem`.
  final bool isSelected;
}

/// The Cancel entry every menu carries, for tests.
const Key mixtapeMenuCancelKey = Key('mixtape-menu-cancel');

/// Presents [actions] as the app's standard native menu.
///
/// Returns the chosen action's value, or null when the listener cancelled or
/// dismissed the sheet.
Future<T?> showMixtapeMenu<T>(
  BuildContext context, {
  required List<MixtapeMenuAction<T>> actions,
  String? title,
  String? message,
  String cancelLabel = 'Cancel',
}) => showCupertinoModalPopup<T>(
  context: context,
  builder: (sheetContext) => CupertinoActionSheet(
    title: title == null ? null : Text(title),
    message: message == null ? null : Text(message),
    actions: [
      for (final action in actions)
        CupertinoActionSheetAction(
          isDestructiveAction: action.isDestructive,
          onPressed: action.enabled
              ? () => Navigator.of(sheetContext).pop(action.value)
              // A disabled entry still has to be a sheet action — it is the
              // only child type the sheet lays out — so it swallows its tap.
              : () {},
          child: Opacity(
            opacity: action.enabled ? 1 : 0.4,
            // The entry's own key rides here, where it also carries the
            // entry's state for tests that used to read a PopupMenuItem's.
            child: MixtapeMenuItem(key: action.key, action: action),
          ),
        ),
    ],
    cancelButton: CupertinoActionSheetAction(
      key: mixtapeMenuCancelKey,
      onPressed: () => Navigator.of(sheetContext).pop(),
      child: Text(cancelLabel),
    ),
  ),
);

/// An entry's label, its tick when it is checked, and its second line.
class MixtapeMenuItem<T> extends StatelessWidget {
  const MixtapeMenuItem({super.key, required this.action});

  final MixtapeMenuAction<T> action;

  /// The tick a selected entry wears, for tests.
  static const Key tickKey = Key('mixtape-menu-tick');

  @override
  Widget build(BuildContext context) {
    final subtitle = action.subtitle;
    final label = action.isSelected
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(CupertinoIcons.check_mark, key: tickKey, size: 18),
              const SizedBox(width: 6),
              Flexible(child: Text(action.label)),
            ],
          )
        : Text(action.label);
    if (subtitle == null) return label;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        label,
        const SizedBox(height: 2),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: CupertinoTheme.of(
            context,
          ).textTheme.tabLabelTextStyle.copyWith(fontSize: 12),
        ),
      ],
    );
  }
}
