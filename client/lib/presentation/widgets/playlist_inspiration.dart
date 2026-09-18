/// Starting a mix from a playlist: the attachment chip both Home and the
/// conversation wear, and the picker sheet behind its Replace action
/// (`docs/mockups/approved/2026-09-17-mobile-home-states.md` → Playlist
/// attached, Picker; frames W2 and W3 on
/// `docs/mockups/2026-09-17-mobile-home-states.html`; plan task 3.3).
///
/// Reading and choosing never writes: the picker returns a choice and the
/// caller decides what to do with it. Null means dismissed, never detach.
library;

import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/playlists/playlist_api.dart';
import '../../data/playlists/playlist_context_models.dart';
import '../../data/playlists/playlist_models.dart';
import '../providers/auth_provider.dart';
import '../providers/playlist_providers.dart';
import '../theme/mixtape_theme.dart';
import 'foundation/flush_row.dart';
import 'foundation/inset_group.dart';
import 'foundation/mixtape_sheet.dart';
import 'foundation/status_word.dart';
import 'playlist_artwork.dart';
import 'foundation/mixtape_menu.dart';

class PlaylistInspirationChoice {
  const PlaylistInspirationChoice(
    this.playlist, {
    required this.excludeSourceTracks,
  });
  final PlaylistSummary playlist;
  final bool excludeSourceTracks;
  InitialPlaylistSeed get seed => InitialPlaylistSeed(
    playlistId: playlist.id,
    excludeSourceTracks: excludeSourceTracks,
  );
}

/// The board's source label on a picker row ("Apple Music", "Spotify import").
String playlistSourceLabel(String? source) => switch (source) {
  'apple' => 'Apple Music',
  'spotify_export' => 'Spotify import',
  _ => 'Imported playlist',
};

/// `41 songs · Apple Music`.
String playlistInspirationSubtitle(PlaylistSummary playlist) =>
    '${playlist.entryCount} ${playlist.entryCount == 1 ? 'song' : 'songs'} · '
    '${playlistSourceLabel(playlist.source)}';

/// The picker sheet's copy, keys and rules, so screens and tests name the
/// same things.
abstract final class PlaylistPicker {
  static const String title = 'Start from a playlist';
  static const String searchHint = 'Search your playlists';
  static const String excludeLabel = "Exclude the playlist's own songs";
  static const String excludeHint = 'Only songs like them, none from it';
  static const String notEnoughLabel = 'Not enough';
  static const String emptyLabel = 'No matching playlists.';
  static const String failedLabel = 'Couldn’t load playlists.';

  /// Fewer matched songs than this and a playlist stays visible but cannot be
  /// chosen — the same floor the conversation's seed status uses.
  static const int minimumSongs = 3;

  static const Key sheetKey = Key('playlist-picker-sheet');

  /// The shared sheet draws the handle now; the key points at it so callers
  /// and tests keep one name.
  static const Key handleKey = MixtapeSheet.handleKey;
  static const Key listKey = Key('playlist-picker-list');
  static const Key searchKey = Key('playlist-search');
  static const Key excludeKey = Key('playlist-exclude');
  static const Key retryKey = Key('playlist-picker-retry');

  /// `.sheet`: a 26 pt top radius over Home.
  static const double topRadius = 26;

  /// The strip of Home the sheet leaves showing.
  static const double topInset = 84;

  /// `.sheet .row`: the 44 pt square motif.
  static const double artSize = 44;

  static Key rowKey(String id) => ValueKey('playlist-choice-$id');

  static bool canChoose(PlaylistSummary playlist) =>
      playlist.entryCount >= minimumSongs;
}

/// Opens the picker over the current screen.
///
/// [anchor] and [anchorResolver] are ignored: the picker was a floating panel
/// anchored to the composer until task 3.3 made it the board's sheet. They stay
/// in the signature so callers that still measure their composer keep working.
Future<PlaylistInspirationChoice?> showPlaylistInspirationPicker(
  BuildContext context,
  WidgetRef ref, {
  Rect? anchor,
  Rect Function()? anchorResolver,
  InitialPlaylistSeed? selected,
}) {
  final api = ref.read(playlistApiProvider);
  return showMixtapeSheet<PlaylistInspirationChoice>(
    context,
    isScrollControlled: true,
    builder: (_) => _PlaylistPicker(api: api, selected: selected),
  );
}

/// What an attachment chip is saying (`.attach .chip`, `.chip.warn` and
/// `.chip.err` on `docs/mockups/2026-09-17-mobile-conversation-states.html`,
/// frame A2).
enum InspirationChipTone {
  /// "Inspired by: Late nights" — a usable selection.
  ready,

  /// The playlist is gone. Its name stays visible and Replace/Detach remain.
  unavailable,

  /// Too few matched songs to use as inspiration; it cannot be sent.
  insufficient,
}

enum _ChipAction { replace, exclude, detach }

/// The attachment chip Home and the conversation share
/// (`docs/mockups/approved/2026-09-17-mobile-home-states.md` → Playlist
/// attached; frame W2).
///
/// A tape label with the reel hole naming the exact playlist. Given
/// [onToggleExclude] it carries the board's menu — Replace, Exclude its songs
/// (checked when the flag is on), Detach — and tapping it opens that menu;
/// without one it stays the plain chip the conversation has today, tapping
/// through to [onPick] with a detach cross of its own.
class InspirationChip extends StatelessWidget {
  const InspirationChip({
    super.key,
    required this.name,
    this.tone = InspirationChipTone.ready,
    this.onPick,
    this.onDetach,
    this.excludeSourceTracks = false,
    this.onToggleExclude,
  });

  /// Null asks for a playlist ("+ Playlist"); a name offers to replace it.
  final String? name;
  final InspirationChipTone tone;

  /// Pick or replace. Null makes the chip inert (busy, or writes blocked).
  final VoidCallback? onPick;

  /// Detach. Null hides it — an insufficient selection still offers it, per
  /// the record; a busy one does not.
  final VoidCallback? onDetach;

  /// Whether the mix is being asked to leave the playlist's own songs out.
  final bool excludeSourceTracks;

  /// Flips [excludeSourceTracks]. Null leaves the chip without a menu.
  final VoidCallback? onToggleExclude;

  static const Key chipKey = Key('inspiration-chip');
  static const Key detachKey = Key('inspiration-detach');
  static const Key replaceItemKey = Key('inspiration-replace');
  static const Key excludeItemKey = Key('inspiration-exclude');
  static const Key detachItemKey = Key('inspiration-detach-item');
  static const Key menuNoteKey = Key('inspiration-menu-note');

  static const String replaceLabel = 'Replace';
  static const String excludeLabel = 'Exclude its songs';
  static const String detachLabel = 'Detach';

  /// The header on an unsendable selection's menu.
  static const String insufficientNote =
      'Too few matched songs to send — replace it.';

  /// The board's warm paper, borrowed from `LabelChip` so the chips match.
  static const Color _lightFill = Color.fromRGBO(247, 244, 239, 0.60);

  static const BorderRadius _radius = BorderRadius.only(
    topLeft: Radius.circular(MixtapeMetrics.tapeRadiusTop),
    topRight: Radius.circular(MixtapeMetrics.tapeRadiusTop),
    bottomLeft: Radius.circular(MixtapeMetrics.tapeRadiusBottom),
    bottomRight: Radius.circular(MixtapeMetrics.tapeRadiusBottom),
  );

  /// The chip's own words, so the caller never has to assemble them.
  String get label => switch ((name, tone)) {
    (null, _) => '+ Playlist',
    (final n?, InspirationChipTone.ready) => 'Inspired by: $n',
    (final n?, InspirationChipTone.unavailable) => '$n · unavailable',
    (final n?, InspirationChipTone.insufficient) => '$n · too few songs',
  };

  Color ink(BuildContext context) => switch (tone) {
    InspirationChipTone.ready => context.tokens.plum,
    InspirationChipTone.unavailable => context.tokens.warnInk,
    InspirationChipTone.insufficient => context.tokens.errInk,
  };

  /// The menu only exists for a selection that can be replaced or let go.
  bool get _hasMenu =>
      name != null &&
      onToggleExclude != null &&
      (onPick != null || onDetach != null);

  Future<void> _openMenu(BuildContext context) async {
    final action = await showMixtapeMenu<_ChipAction>(
      context,
      actions: [
        // Not an action but a word of explanation, which the sheet can only
        // carry as a disabled entry; kept keyed as the menu item was.
        if (tone == InspirationChipTone.insufficient)
          const MixtapeMenuAction(
            key: menuNoteKey,
            enabled: false,
            isDestructive: true,
            label: insufficientNote,
          ),
        if (onPick != null)
          const MixtapeMenuAction(
            key: replaceItemKey,
            value: _ChipAction.replace,
            label: replaceLabel,
          ),
        // Excluding the source only means anything while the playlist can
        // still be read.
        if (tone == InspirationChipTone.ready)
          MixtapeMenuAction(
            key: excludeItemKey,
            value: _ChipAction.exclude,
            isSelected: excludeSourceTracks,
            label: excludeLabel,
          ),
        if (onDetach != null)
          const MixtapeMenuAction(
            key: detachItemKey,
            value: _ChipAction.detach,
            label: detachLabel,
          ),
      ],
    );
    switch (action) {
      case _ChipAction.replace:
        onPick?.call();
      case _ChipAction.exclude:
        onToggleExclude?.call();
      case _ChipAction.detach:
        onDetach?.call();
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tint = ink(context);
    final menu = _hasMenu;
    final enabled = menu || onPick != null;
    final cross = !menu && onDetach != null;

    final chip = Container(
      constraints: const BoxConstraints(minHeight: MixtapeMetrics.chipHeight),
      padding: EdgeInsets.only(left: 11, right: cross ? 2 : 11),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withValues(alpha: 0.08) : _lightFill,
        borderRadius: _radius,
        border: Border.all(color: tint.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (tone == InspirationChipTone.insufficient)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: Icon(Icons.error_outline, size: 14, color: tint),
            )
          else
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: SizedBox.square(
                dimension: 11,
                child: CustomPaint(painter: _ReelHole(tint)),
              ),
            ),
          Flexible(
            child: ExcludeSemantics(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: tint,
                ),
              ),
            ),
          ),
          // The board's `.attach .chip .x`: the more glyph, because the chip
          // opens a menu rather than detaching on the spot.
          if (menu)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Icon(Icons.more_horiz, size: 16, color: tint),
            ),
          if (cross)
            Semantics(
              button: true,
              label: 'Detach playlist inspiration',
              // `excludeSemantics` drops the detector's own tap action, and a
              // node with no action cannot be activated by VoiceOver. Declare
              // it here.
              onTap: onDetach,
              excludeSemantics: true,
              child: GestureDetector(
                key: detachKey,
                behavior: HitTestBehavior.opaque,
                onTap: onDetach,
                child: SizedBox.square(
                  dimension: MixtapeMetrics.chipHeight,
                  child: Center(
                    child: Icon(Icons.close, size: 16, color: tint),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: GestureDetector(
        key: chipKey,
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? (menu ? () => _openMenu(context) : onPick) : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: MixtapeMetrics.minTarget,
          ),
          child: Center(
            widthFactor: 1,
            child: Opacity(opacity: enabled ? 1 : 0.5, child: chip),
          ),
        ),
      ),
    );
  }
}

/// The tape reel's hole, as `LabelChip` draws it, in the chip's own ink.
class _ReelHole extends CustomPainter {
  const _ReelHole(this.ink);

  final Color ink;

  static const Color _edge = Color.fromRGBO(73, 64, 72, 0.35);
  static const int _spokes = 8;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final wedge = Rect.fromCircle(center: center, radius: radius - 1);
    final paint = Paint()..color = ink;
    const sweep = 18 * math.pi / 180;
    const step = 2 * math.pi / _spokes;
    for (var i = 0; i < _spokes; i++) {
      canvas.drawArc(wedge, i * step, sweep, true, paint);
    }
    canvas.drawCircle(
      center,
      radius * 0.35,
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = radius * 0.2,
    );
    canvas.drawCircle(
      center,
      radius - 0.5,
      Paint()
        ..color = _edge
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_ReelHole oldDelegate) => oldDelegate.ink != ink;
}

/// The picker, as the board's sheet: search, the playlists as flush rows with
/// their exact identities, pagination on scroll, and the exclude toggle at the
/// foot. Dismissal — outside tap, drag down, Back — returns null.
class _PlaylistPicker extends ConsumerStatefulWidget {
  const _PlaylistPicker({required this.api, this.selected});
  final PlaylistApi api;
  final InitialPlaylistSeed? selected;
  @override
  ConsumerState<_PlaylistPicker> createState() => _PlaylistPickerState();
}

class _PlaylistPickerState extends ConsumerState<_PlaylistPicker> {
  final _search = TextEditingController();
  Timer? _debounce;
  List<PlaylistSummary> _playlists = [];
  String? _cursor;
  bool _loading = true;
  bool _failed = false;
  bool _exclude = false;
  int _request = 0;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _exclude = widget.selected?.excludeSourceTracks ?? false;
    _load(reset: true);
  }

  bool get _signedIn => ref.read(authProvider) == AuthStatus.signedIn;

  Future<void> _load({required bool reset}) async {
    if (!reset && _loading) return;
    final request = ++_request;
    setState(() {
      _loading = true;
      _failed = false;
      if (reset) {
        _playlists = [];
        _cursor = null;
      }
    });
    try {
      final page = await widget.api.list(
        query: _search.text.trim().isEmpty ? null : _search.text.trim(),
        cursor: reset ? null : _cursor,
      );
      if (!mounted || request != _request || !_signedIn) return;
      setState(() {
        final seen = _playlists.map((p) => p.id).toSet();
        _playlists = [
          ..._playlists,
          ...page.playlists.where((p) => seen.add(p.id)),
        ];
        _cursor = page.nextCursor;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || request != _request || !_signedIn) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  /// The board's pagination: the next page comes in as the list runs out,
  /// with no button to press.
  void _loadMoreOnScroll() {
    if (_loading || _failed || _cursor == null) return;
    _load(reset: false);
  }

  void _query(String _) {
    _debounce?.cancel();
    _request++;
    setState(() {
      _loading = true;
      _failed = false;
      _playlists = [];
      _cursor = null;
    });
    _debounce = Timer(
      const Duration(milliseconds: 200),
      () => _load(reset: true),
    );
  }

  @override
  void dispose() {
    _request++;
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    if (auth != AuthStatus.signedIn && !_closing) {
      _closing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    }
    final media = MediaQuery.of(context);
    final tokens = context.tokens;
    final keyboard = media.viewInsets.bottom;
    // Whatever is left under the keyboard, less the strip of Home the board
    // keeps visible above the sheet.
    final available = media.size.height - keyboard;
    // A sheet under 200% text keeps the board's strip of Home above it; one
    // that has to fit AX text with the keyboard up takes what it needs.
    final maxHeight = math.max(
      200.0,
      available -
          (MediaQuery.textScalerOf(context).scale(20) > 30
              ? 24
              : PlaylistPicker.topInset),
    );
    // Too little room for both the title and the list — a short sheet, or a
    // title that has grown to five lines at 200% text: the title goes, as
    // Home's hint does when the panel crowds it.
    final compact =
        maxHeight < 320 || MediaQuery.textScalerOf(context).scale(20) > 30;

    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: ConstrainedBox(
        key: PlaylistPicker.sheetKey,
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            MixtapeMetrics.screenSidePadding,
            2,
            MixtapeMetrics.screenSidePadding,
            12,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!compact)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(PlaylistPicker.title, style: tokens.section),
                ),
              _searchField(tokens),
              Flexible(child: _list(tokens)),
              _excludeRow(compact: compact),
            ],
          ),
        ),
      ),
    );
  }

  /// `.search`: a quiet capsule, not a bordered form field.
  Widget _searchField(MixtapeTokens tokens) => Container(
    constraints: const BoxConstraints(minHeight: 38),
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: BoxDecoration(
      color: const Color.fromRGBO(120, 110, 120, 0.14),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Row(
      children: [
        Icon(Icons.search, size: 18, color: tokens.muted),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            key: PlaylistPicker.searchKey,
            controller: _search,
            maxLength: 200,
            onChanged: _query,
            style: tokens.body,
            cursorColor: tokens.plum,
            decoration: InputDecoration(
              hintText: PlaylistPicker.searchHint,
              hintStyle: tokens.body.copyWith(color: tokens.muted),
              counterText: '',
              isDense: true,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 9),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _list(MixtapeTokens tokens) =>
      NotificationListener<ScrollNotification>(
        onNotification: (note) {
          if (note.metrics.axis == Axis.vertical &&
              note.metrics.extentAfter < 240) {
            _loadMoreOnScroll();
          }
          return false;
        },
        child: ListView(
          key: PlaylistPicker.listKey,
          padding: const EdgeInsets.only(top: 4),
          children: [
            for (var i = 0; i < _playlists.length; i++)
              _row(_playlists[i], isFirst: i == 0),
            if (_playlists.isEmpty && !_loading && !_failed)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  PlaylistPicker.emptyLabel,
                  style: tokens.secondary.copyWith(color: tokens.muted),
                ),
              ),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_failed) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  PlaylistPicker.failedLabel,
                  style: tokens.secondary.copyWith(color: tokens.errInk),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: PlaylistPicker.retryKey,
                  onPressed: () => _load(reset: _playlists.isEmpty),
                  child: const Text('Retry'),
                ),
              ),
            ],
          ],
        ),
      );

  /// One playlist: exact identity, its source, and — under the floor — the
  /// warn word that says why it cannot be chosen.
  Widget _row(PlaylistSummary playlist, {required bool isFirst}) {
    final tokens = context.tokens;
    final enough = PlaylistPicker.canChoose(playlist);
    final selected = widget.selected?.playlistId == playlist.id;
    final row = FlushRow(
      key: PlaylistPicker.rowKey(playlist.id),
      isFirst: isFirst,
      leading: PlaylistArtwork(
        urlTemplate: playlist.artworkUrlTemplate,
        bgColor: playlist.artworkBgColor,
        size: PlaylistPicker.artSize,
        borderRadius: MixtapeMetrics.tileRadius,
      ),
      leadingSize: PlaylistPicker.artSize,
      title: playlist.name,
      subtitle: playlistInspirationSubtitle(playlist),
      trailing: enough
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected) Icon(Icons.check, size: 18, color: tokens.plum),
                Icon(
                  Icons.chevron_right,
                  size: 20,
                  color: tokens.muted.withValues(alpha: 0.6),
                ),
              ],
            )
          : const StatusWord(
              label: PlaylistPicker.notEnoughLabel,
              kind: StatusKind.warn,
            ),
      onTap: enough
          ? () {
              if (!_signedIn) return;
              Navigator.of(context).pop(
                PlaylistInspirationChoice(
                  playlist,
                  excludeSourceTracks: _exclude,
                ),
              );
            }
          : null,
    );
    // Visible, readable, and plainly not on offer.
    return enough ? row : Opacity(opacity: 0.55, child: row);
  }

  /// The board's `.grow` row: the exclude flag the choice carries with it.
  /// Drawn on the sheet itself, not on a group's own surface.
  ///
  /// The toggle stays at the foot of the sheet whatever the text scale, so
  /// [compact] trades the row's second line — and the last of its growth —
  /// for keeping both it and the list on screen.
  Widget _excludeRow({required bool compact}) {
    final row = Padding(
      padding: const EdgeInsets.only(top: 6),
      child: InsetRow(
        title: PlaylistPicker.excludeLabel,
        subtitle: compact ? null : PlaylistPicker.excludeHint,
        onTap: () => setState(() => _exclude = !_exclude),
        trailing: Switch.adaptive(
          key: PlaylistPicker.excludeKey,
          value: _exclude,
          onChanged: (value) => setState(() => _exclude = value),
        ),
      ),
    );
    return compact
        ? MediaQuery.withClampedTextScaling(maxScaleFactor: 1.4, child: row)
        : row;
  }
}
