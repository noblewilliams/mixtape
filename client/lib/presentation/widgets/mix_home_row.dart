import 'package:flutter/material.dart';
import 'mix_name_editor.dart';

import '../../data/dj/dj_models.dart';
import '../format/relative_time.dart';

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
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _editing || _busy ? null : widget.onOpen,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Row(
              children: [
                Expanded(
                  child: _editing
                      ? MixNameEditor(
                          sessionId: widget.session.id,
                          title: widget.session.title,
                          onSave: widget.onRename,
                          onFinished: () => setState(() => _editing = false),
                        )
                      : Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 12,
                            horizontal: 8,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.session.title,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                relativeTime(widget.session.updatedAt),
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: colors.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                ),
                if (!_editing)
                  PopupMenuButton<String>(
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
                      const PopupMenuItem(
                        value: 'rename',
                        child: Text('Rename'),
                      ),
                      PopupMenuItem(
                        value: 'status',
                        child: Text(archived ? 'Restore' : 'Archive'),
                      ),
                    ],
                    child: const SizedBox(
                      width: 48,
                      height: 48,
                      child: Icon(Icons.more_horiz),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
