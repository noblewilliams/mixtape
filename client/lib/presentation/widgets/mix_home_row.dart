import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'mix_name_editor.dart';

import '../../data/dj/dj_models.dart';
import '../format/relative_time.dart';
import '../screens/mix_history_screen.dart' show MixHistoryScreen;
import '../theme/mixtape_theme.dart';
import 'foundation/cassette_tile.dart';
import 'foundation/flush_row.dart';
import 'foundation/mixtape_menu.dart';
import 'foundation/swipe_actions.dart';
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
    this.working = false,
    this.ready = false,
  });

  /// The DJ has a turn out on this mix: the tape's hubs turn and the line
  /// under the title says so (device smoke, 2026-11-13).
  final bool working;

  /// A reply landed that the listener has not looked at: a dot at the
  /// trailing edge until the conversation is opened.
  final bool ready;

  static const String workingSubtitle = 'The DJ is on it…';

  /// The dot, for tests.
  static Key readyKey(String id) => ValueKey('mix-ready-$id');

  /// The dot's size.
  static const double readyDotSize = 10;

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

  /// The cassette's width. 68, down from the board's 80, with more air above
  /// and below it: at 80 the tapes crowded the hairlines and the list read
  /// tight (founder, 2026-11-09).
  static const double artSize = 68;

  /// The row's padding above and below the tape.
  static const double verticalPadding = 16;

  /// The swipe panels, for tests.
  static Key moreActionKey(String id) => ValueKey('mix-swipe-more-$id');
  static Key archiveActionKey(String id) => ValueKey('mix-swipe-archive-$id');

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
        showTapeSettingsSheet(
          context,
          title: widget.session.title,
          initialColor:
              widget.session.caseColor ??
              '#${CassetteTile.caseColorFor(widget.session.id).toARGB32().toRadixString(16).substring(2)}',
          onSave: widget.onCaseColor!,
          onRename: widget.onRename,
        );
      case MixHomeRow.renameAction:
        _rename();
      case MixHomeRow.versionHistoryAction:
        _openVersionHistory();
      case MixHomeRow.statusAction:
        _changeStatus();
    }
  }

  bool get _isAlbum => widget.session.kind == SessionKind.album;

  /// Rename, Version history and Archive/Restore — the approved row menu,
  /// shared by the long-press and the legacy trailing button. An album
  /// session has no versions to browse and no tape to dress (both answer 409),
  /// so it offers Rename and Archive/Restore only.
  List<MixtapeMenuAction<String>> _menuItems(bool archived) => [
    if (widget.onCaseColor != null && !_isAlbum)
      const MixtapeMenuAction(
        value: 'tape-settings',
        label: 'Tape settings',
        icon: MixMenuIcons.tape,
      ),
    const MixtapeMenuAction(
      value: MixHomeRow.renameAction,
      label: 'Rename',
      icon: MixMenuIcons.rename,
    ),
    if (!_isAlbum)
      const MixtapeMenuAction(
        value: MixHomeRow.versionHistoryAction,
        label: 'Version history',
        icon: MixMenuIcons.history,
      ),
    MixtapeMenuAction(
      value: MixHomeRow.statusAction,
      label: archived ? 'Unarchive' : 'Archive',
      isDestructive: !archived,
      separatorBefore: true,
      icon: MixMenuIcons.archive,
    ),
  ];

  /// The board's long-press (section 5, "Long-press on a row"): the row lifts
  /// onto the sheet surface over the dim and the menu anchors under it.
  Future<void> _openActionsMenu(BuildContext rowContext, bool archived) async {
    final action = await showMixtapeMenu<String>(
      rowContext,
      actions: _menuItems(archived),
      lifted: (_) => MixtapeMenuLift(
        child: FlushRow(
          leading: _tile,
          leadingSize: MixHomeRow.artSize,
          verticalPadding: MixHomeRow.verticalPadding,
          showChevron: false,
          title: widget.session.title,
          subtitle: _subtitle,
          isFirst: true,
          onTap: () {},
        ),
      ),
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

  /// An album session names its current pick; everything else says when.
  /// While the DJ works, it says that instead.
  String get _subtitle {
    if (widget.working) return MixHomeRow.workingSubtitle;
    final pick = widget.session.pick;
    if (_isAlbum && pick != null) return '${pick.title} · ${pick.artist}';
    return relativeTime(widget.session.updatedAt);
  }

  Widget get _tile => CassetteTile(
    width: MixHomeRow.artSize,
    seedId: widget.session.id,
    title: widget.session.title,
    caseColor: tapeColor(widget.session.caseColor),
    shadow: true,
    spinning: widget.working,
  );

  /// The unread dot: plum, the app's own ink, and named for VoiceOver.
  Widget _readyDot(BuildContext context) => Semantics(
    key: MixHomeRow.readyKey(widget.session.id),
    label: 'Ready',
    child: Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Container(
        width: MixHomeRow.readyDotSize,
        height: MixHomeRow.readyDotSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: context.tokens.plum,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final archived = widget.session.status == 'archived';
    final dark = Theme.of(context).brightness == Brightness.dark;
    final id = widget.session.id;
    return _TokenScope(
      child: Builder(
        builder: (context) => SwipeActions(
          key: ValueKey('mix-swipe-$id'),
          enabled: !_editing && !_busy,
          // The list sits inside the screen's side padding; the row still
          // slides out to the screen edge, as WhatsApp's does.
          bleed: MixtapeMetrics.screenSidePadding,
          actions: [
            SwipeAction(
              key: MixHomeRow.moreActionKey(id),
              label: 'More',
              icon: CupertinoIcons.ellipsis,
              color: dark ? _moreFillDark : _moreFillLight,
              // The swipe's own box, which stays put while the row slides: the
              // menu anchors to the row at rest and lifts a copy of it, as a
              // long-press does.
              onPressed: () => _openActionsMenu(context, archived),
            ),
            SwipeAction(
              key: MixHomeRow.archiveActionKey(id),
              label: archived ? 'Unarchive' : 'Archive',
              icon: MixMenuIcons.archive,
              color: dark ? _archiveFillDark : _archiveFillLight,
              commits: true,
              onPressed: _changeStatus,
            ),
          ],
          child: Builder(builder: _buildRow),
        ),
      ),
    );
  }

  /// The swipe panels: a neutral grey More beside a violet Archive, as
  /// WhatsApp's grey sits beside its green. The violet is the app's own glow
  /// (the background's violet tint, the prism's last stripe), so the one
  /// coloured panel is still the brand's colour.
  static const Color _moreFillLight = Color(0xFF8E8A93);
  static const Color _moreFillDark = Color(0xFF48464E);
  static const Color _archiveFillLight = Color(0xFF6E5C8F);
  static const Color _archiveFillDark = Color(0xFF604EAA);

  Widget _buildRow(BuildContext context) {
    final archived = widget.session.status == 'archived';
    if (_editing) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          vertical: MixHomeRow.verticalPadding,
        ),
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
      // No chevron (founder, 2026-11-09); the actions live on long-press and
      // the swipe.
      onLongPress: _busy ? null : () => _openActionsMenu(context, archived),
      child: FlushRow(
        leading: _tile,
        leadingSize: MixHomeRow.artSize,
        verticalPadding: MixHomeRow.verticalPadding,
        showChevron: false,
        title: widget.session.title,
        subtitle: _subtitle,
        isFirst: widget.isFirst,
        onTap: _busy ? null : widget.onOpen,
        trailing: widget.ready && !widget.working
            ? _readyDot(context)
            : widget.showActionsButton
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
