import 'package:flutter/material.dart';
import 'mix_name_editor.dart';

import '../../data/dj/dj_models.dart';
import '../format/relative_time.dart';
import '../screens/mix_history_screen.dart' show MixHistoryScreen;
import '../theme/mixtape_theme.dart';
import 'foundation/cassette_tile.dart';
import 'foundation/flush_row.dart';
import 'foundation/mixtape_menu.dart';
import 'tape_palette.dart';
import 'tape_settings_dialog.dart';

/// Home owns canonical session state; this row only owns an unsaved name.
class MixHomeRow extends StatefulWidget {
  const MixHomeRow({
    super.key,
    required this.session,
    required this.onOpen,
    required this.onRename,
    required this.onArchive,
    required this.onRestore,
    this.isFirst,
    this.showActionsButton = false,
    this.onVersionHistory,
    this.onCaseColor,
  });

  final DjSession session;
  final Future<bool> Function(String)? onCaseColor;
  final VoidCallback onOpen;
  final Future<bool> Function(String) onRename;
  final Future<bool> Function() onArchive;
  final Future<bool> Function() onRestore;

  /// Whether this row opens its list, so [FlushRow] draws no hairline above
  /// it. Lazily built rows (the Mixes tab's `SliverList.builder`) have no
  /// [FlushList] to ask, so they pass `index == 0`.
  final bool? isFirst;

  /// Whether the trailing slot holds a visible actions button.
  ///
  /// The approved shell shows a chevron and puts the actions on long-press, so
  /// the default is false. A host that wants the button back — a wide layout,
  /// or a test driving the menu without a long-press — opts in.
  final bool showActionsButton;

  /// Overrides the push of [MixHistoryScreen] (tests, and any host that wants
  /// version history somewhere else).
  final VoidCallback? onVersionHistory;

  /// The board's art box; the cassette sits inside it (`.row .art .cs`).
  static const double artSize = 80;

  /// The row's actions, in menu order.
  static const String renameAction = 'rename';
  static const String versionHistoryAction = 'history';
  static const String statusAction = 'status';

  @override
  State<MixHomeRow> createState() => _MixHomeRowState();
}

class _MixHomeRowState extends State<MixHomeRow> {
  bool _editing = false;
  bool _busy = false;

  void _rename() => setState(() => _editing = true);

  void _openVersionHistory() {
    final override = widget.onVersionHistory;
    if (override != null) {
      override();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MixHistoryScreen(sessionId: widget.session.id),
      ),
    );
  }

  void _handleAction(String action) {
    switch (action) {
      case 'tape-settings':
        showDialog<void>(
          context: context,
          builder: (_) => TapeSettingsDialog(
            title: widget.session.title,
            initialColor:
                widget.session.caseColor ??
                '#${CassetteTile.caseColorFor(widget.session.id).toARGB32().toRadixString(16).substring(2)}',
            onSave: widget.onCaseColor!,
          ),
        );
      case MixHomeRow.renameAction:
        _rename();
      case MixHomeRow.versionHistoryAction:
        _openVersionHistory();
      case MixHomeRow.statusAction:
        _changeStatus();
    }
  }

  /// Rename, Version history and Archive/Restore — the approved row menu,
  /// shared by the long-press and the legacy trailing button.
  List<MixtapeMenuAction<String>> _menuItems(bool archived) => [
    if (widget.onCaseColor != null)
      const MixtapeMenuAction(value: 'tape-settings', label: 'Tape settings'),
    const MixtapeMenuAction(value: MixHomeRow.renameAction, label: 'Rename'),
    const MixtapeMenuAction(
      value: MixHomeRow.versionHistoryAction,
      label: 'Version history',
    ),
    MixtapeMenuAction(
      value: MixHomeRow.statusAction,
      label: archived ? 'Restore' : 'Archive',
      isDestructive: !archived,
    ),
  ];

  /// The board's long-press: the same menu, as the app's action sheet.
  Future<void> _openActionsMenu(BuildContext rowContext, bool archived) async {
    final action = await showMixtapeMenu<String>(
      rowContext,
      title: widget.session.title,
      actions: _menuItems(archived),
    );
    if (action != null && mounted) _handleAction(action);
  }

  Future<void> _changeStatus() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await (widget.session.status == 'archived'
          ? widget.onRestore()
          : widget.onArchive());
    } catch (_) {
      // The parent owns status errors and keeps the canonical row in place.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget get _tile => CassetteTile(
    width: MixHomeRow.artSize,
    seedId: widget.session.id,
    title: widget.session.title,
    caseColor: tapeColor(widget.session.caseColor),
    shadow: true,
  );

  @override
  Widget build(BuildContext context) {
    final archived = widget.session.status == 'archived';
    final colors = Theme.of(context).colorScheme;
    return Dismissible(
      key: ValueKey('mix-swipe-${widget.session.id}'),
      direction: archived || _editing || _busy
          ? DismissDirection.none
          : DismissDirection.endToStart,
      confirmDismiss: (_) async {
        await _changeStatus();
        // The parent removes the row only after accepting the server response.
        // Returning false also permits an unchanged row after a failed request.
        return false;
      },
      background: ColoredBox(
        color: colors.surfaceContainerHighest,
        child: const Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Icon(Icons.archive_outlined),
          ),
        ),
      ),
      child: _TokenScope(child: Builder(builder: _buildRow)),
    );
  }

  Widget _buildRow(BuildContext context) {
    final archived = widget.session.status == 'archived';
    if (_editing) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            _tile,
            const SizedBox(width: FlushRow.gap),
            Expanded(
              child: MixNameEditor(
                sessionId: widget.session.id,
                title: widget.session.title,
                onSave: widget.onRename,
                onFinished: () => setState(() => _editing = false),
              ),
            ),
          ],
        ),
      );
    }

    return GestureDetector(
      // The row keeps FlushRow's chevron; the actions live on long-press.
      onLongPress: _busy ? null : () => _openActionsMenu(context, archived),
      child: FlushRow(
        leading: _tile,
        leadingSize: MixHomeRow.artSize,
        title: widget.session.title,
        subtitle: relativeTime(widget.session.updatedAt),
        isFirst: widget.isFirst,
        onTap: _busy ? null : widget.onOpen,
        trailing: widget.showActionsButton
            ? IconButton(
                key: ValueKey('mix-actions-${widget.session.id}'),
                tooltip: 'Mix actions',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: _busy
                    ? null
                    : () => _openActionsMenu(context, archived),
                icon: Icon(Icons.more_horiz, color: context.tokens.muted),
              )
            : null,
      ),
    );
  }
}

/// Guarantees [MixtapeTokens] for the foundation widgets below.
///
/// `main.dart` always builds a [MixtapeTheme], so this only matters to widget
/// tests that still pump a bare `MaterialApp`; it is a no-op under the app's
/// own theme and should go once those tests adopt [MixtapeTheme].
class _TokenScope extends StatelessWidget {
  const _TokenScope({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (theme.extension<MixtapeTokens>() != null) return child;
    return Theme(
      data: theme.copyWith(
        extensions: [
          ...theme.extensions.values,
          theme.brightness == Brightness.dark
              ? MixtapeTokens.dark
              : MixtapeTokens.light,
        ],
      ),
      child: child,
    );
  }
}
