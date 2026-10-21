/// One album on the Listen later shelf in Mixes
/// (`docs/mockups/approved/2026-10-20-album-picks.md` → "Listen later, native
/// (L1 to L3)"; `.row`, `.row.open .why` and `.row.listened` on
/// `docs/mockups/2026-10-20-album-picks-states.html`).
///
/// Flush: the cover in the 60 pt tile, the title, "{artist} · {Type} ·
/// {year}" and the chevron. Long-press (or the "Show why" rotor action)
/// expands the row in place with the "why", the prompt it was saved from and
/// "Mark listened". A listened row is muted and ends its second line with
/// "Listened {d Mon}" as a plum status word. Swipe left removes; the parent
/// owns the row's fate and the Undo toast.
///
/// The server's entry carries no "new to you" flag, so the shelf draws none.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../../data/dj/dj_models.dart';
import '../theme/mixtape_theme.dart';
import 'album_card.dart' show AlbumCover;
import 'foundation/flush_row.dart';
import 'foundation/remove_band.dart';
import 'foundation/status_word.dart';
import 'foundation/text_action.dart';

const _shortMonths = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

const _months = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// "12 Oct", "2 Oct": the day without a leading zero and the English month.
String listenedDateLabel(DateTime date) {
  final local = date.toLocal();
  return '${local.day} ${_shortMonths[local.month - 1]}';
}

/// "12 October", for VoiceOver.
String listenedSpokenDate(DateTime date) {
  final local = date.toLocal();
  return '${local.day} ${_months[local.month - 1]}';
}

String _artistAndType(ListenLaterEntry entry) =>
    [entry.artist, if (entry.typeLabel.isNotEmpty) entry.typeLabel].join(' · ');

/// "{artist} · {Type} · {year}", a null year omitted.
String listenLaterSubtitle(ListenLaterEntry entry) => [
  _artistAndType(entry),
  if (entry.releaseYear != null) '${entry.releaseYear}',
].join(' · ');

/// The type as VoiceOver says it: "album", "live", but "EP" stays capitals.
String _spokenType(ListenLaterEntry entry) {
  final label = entry.typeLabel;
  return label == label.toUpperCase() ? label : label.toLowerCase();
}

/// "{title}, {artist}, {type}[, {year}][, listened {d Month}]".
String listenLaterRowLabel(ListenLaterEntry entry) => [
  entry.title,
  entry.artist,
  if (entry.typeLabel.isNotEmpty) _spokenType(entry),
  if (entry.releaseYear != null) '${entry.releaseYear}',
  if (entry.listenedAt != null)
    'listened ${listenedSpokenDate(entry.listenedAt!)}',
].join(', ');

class ListenLaterRow extends StatefulWidget {
  const ListenLaterRow({
    super.key,
    required this.entry,
    this.savedFrom,
    this.onOpen,
    this.onMarkListened,
    this.onRemove,
    this.isFirst,
  });

  final ListenLaterEntry entry;

  /// The title of the session it was saved from, when that session is known.
  final String? savedFrom;

  /// Opens the entry's album session; null when it has none.
  final VoidCallback? onOpen;
  final Future<void> Function()? onMarkListened;

  /// Called on a swipe left; the parent drops the row (or keeps it).
  final Future<void> Function()? onRemove;

  /// See [FlushRow.isFirst].
  final bool? isFirst;

  /// The 60 pt tile the cover sits in.
  static const double coverSize = 60;

  /// The row's own semantics node (label and rotor actions).
  static Key semanticsKey(String id) => ValueKey('listen-later-row-$id');

  @override
  State<ListenLaterRow> createState() => _ListenLaterRowState();
}

class _ListenLaterRowState extends State<ListenLaterRow> {
  bool _open = false;
  bool _busy = false;

  void _toggle() => setState(() => _open = !_open);

  Future<void> _run(Future<void> Function()? action) async {
    if (action == null || _busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      // The parent says what failed; the row stays as it was.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? get _why {
    final parts = [
      if (widget.entry.reason != null && widget.entry.reason!.isNotEmpty)
        widget.entry.reason!,
      if (widget.savedFrom != null) 'Saved from "${widget.savedFrom}".',
    ];
    return parts.isEmpty ? null : parts.join(' ');
  }

  Widget _subtitle(BuildContext context) {
    final entry = widget.entry;
    final tokens = context.tokens;
    final style = tokens.meta.copyWith(fontSize: 12.5, color: tokens.muted);
    final listenedAt = entry.listenedAt;
    if (listenedAt == null) {
      return Text(
        listenLaterSubtitle(entry),
        style: style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    // The board's `small.wm`: the who truncates, the status word never does.
    return Row(
      children: [
        Flexible(
          child: Text(
            '${_artistAndType(entry)} · ',
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        StatusWord(
          label: 'Listened ${listenedDateLabel(listenedAt)}',
          kind: StatusKind.accent,
          icon: false,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final tokens = context.tokens;
    final listened = entry.listened;
    final markListened = listened || widget.onMarkListened == null
        ? null
        : () => _run(widget.onMarkListened);
    final why = _why;

    Widget cover = AlbumCover(
      artwork: entry.artwork,
      size: ListenLaterRow.coverSize,
      radius: 4,
    );
    if (listened) cover = Opacity(opacity: 0.7, child: cover);

    final row = Semantics(
      key: ListenLaterRow.semanticsKey(entry.id),
      container: true,
      button: widget.onOpen != null,
      label: listenLaterRowLabel(entry),
      onTap: widget.onOpen,
      onLongPress: _toggle,
      customSemanticsActions: {
        if (widget.onOpen != null)
          const CustomSemanticsAction(label: 'Open'): widget.onOpen!,
        const CustomSemanticsAction(label: 'Show why'): _toggle,
        if (markListened != null)
          const CustomSemanticsAction(label: 'Mark listened'): markListened,
        if (widget.onRemove != null)
          const CustomSemanticsAction(label: 'Remove'): () =>
              _run(widget.onRemove),
      },
      child: ExcludeSemantics(
        child: GestureDetector(
          onLongPress: _toggle,
          child: FlushRow(
            leading: cover,
            leadingSize: ListenLaterRow.coverSize,
            title: entry.title,
            titleColor: listened ? tokens.muted : null,
            subtitleWidget: _subtitle(context),
            isFirst: widget.isFirst,
            onTap: widget.onOpen,
          ),
        ),
      ),
    );

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        row,
        if (_open && (why != null || markListened != null))
          Padding(
            padding: const EdgeInsets.only(
              left: ListenLaterRow.coverSize + FlushRow.gap,
              bottom: FlushRow.verticalPadding,
            ),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                if (why != null)
                  Text(
                    why,
                    style: tokens.meta.copyWith(
                      fontSize: 13,
                      height: 1.4,
                      color: tokens.smoke,
                    ),
                  ),
                if (markListened != null)
                  TextAction(label: 'Mark listened', onPressed: markListened),
              ],
            ),
          ),
      ],
    );

    return Dismissible(
      key: ValueKey('listen-later-swipe-${entry.id}'),
      direction: widget.onRemove == null || _busy
          ? DismissDirection.none
          : DismissDirection.endToStart,
      confirmDismiss: (_) async {
        await _run(widget.onRemove);
        // The provider drops the row; a failed removal leaves it in place.
        return false;
      },
      // The arrangement screen's swipe, unchanged (board L2).
      movementDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 200),
      background: const RemoveBand(),
      child: content,
    );
  }
}
