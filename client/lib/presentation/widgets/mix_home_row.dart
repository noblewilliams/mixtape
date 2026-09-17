import 'package:flutter/material.dart';
import 'mix_name_editor.dart';

import '../../data/dj/dj_models.dart';
import '../format/relative_time.dart';
import '../theme/mixtape_theme.dart';
import 'foundation/cassette_tile.dart';
import 'foundation/flush_row.dart';
import 'foundation/square_art.dart';

/// Home owns canonical session state; this row only owns an unsaved name.
class MixHomeRow extends StatefulWidget {
  const MixHomeRow({
    super.key,
    required this.session,
    required this.onOpen,
    required this.onRename,
    required this.onArchive,
    required this.onRestore,
  });

  final DjSession session;
  final VoidCallback onOpen;
  final Future<bool> Function(String) onRename;
  final Future<bool> Function() onArchive;
  final Future<bool> Function() onRestore;

  /// The board's art box; the cassette sits inside it (`.row .art .cs`).
  static const double artSize = 60;

  // Phase 2.3: the Mixes list should pass `isFirst: index == 0` down to this
  // row's [FlushRow], so a lazily built first row draws no hairline above it.

  @override
  State<MixHomeRow> createState() => _MixHomeRowState();
}

class _MixHomeRowState extends State<MixHomeRow> {
  bool _editing = false;
  bool _busy = false;

  void _rename() => setState(() => _editing = true);

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

  Widget get _tile => SquareArt(
    size: MixHomeRow.artSize,
    child: CassetteTile(
      width: MixHomeRow.artSize - 6,
      seedId: widget.session.id,
    ),
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

    return FlushRow(
      leading: _tile,
      leadingSize: MixHomeRow.artSize,
      title: widget.session.title,
      subtitle: relativeTime(widget.session.updatedAt),
      onTap: _busy ? null : widget.onOpen,
      trailing: PopupMenuButton<String>(
        key: ValueKey('mix-actions-${widget.session.id}'),
        tooltip: 'Mix actions',
        enabled: !_busy,
        constraints: const BoxConstraints(minWidth: 140),
        onSelected: (action) {
          if (action == 'rename') {
            _rename();
          } else {
            _changeStatus();
          }
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'rename', child: Text('Rename')),
          PopupMenuItem(
            value: 'status',
            child: Text(archived ? 'Restore' : 'Archive'),
          ),
        ],
        child: SizedBox(
          width: 48,
          height: 48,
          child: Icon(Icons.more_horiz, color: context.tokens.muted),
        ),
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
