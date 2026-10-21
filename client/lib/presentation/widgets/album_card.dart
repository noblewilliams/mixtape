/// The album an album session offers, where a mix shows its tape card
/// (`docs/mockups/approved/2026-10-20-album-picks.md` → "Album card, native
/// (A2 to A8)"; `.album`, `.runners`, `.rrow` and `.passed` on
/// `docs/mockups/2026-10-20-album-picks-states.html`).
///
/// Flush on the conversation, no box: the cover with a soft shadow, the
/// title, the artist, the meta line (ending with the plum "New to you" mark
/// when it applies), one "why" line, then Play now and the Listen later chip.
/// Under it the runners-up open from a 44 pt row. [PassedOverRow] is the
/// muted line an earlier pick leaves in the transcript.
library;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dj/dj_models.dart';
import '../../data/musickit/musickit_bridge.dart';
import '../providers/library_sync_provider.dart';
import '../providers/onboarding_provider.dart';
import '../theme/mixtape_theme.dart';
import 'foundation/mixtape_feedback.dart';
import 'foundation/square_art.dart';
import 'foundation/status_word.dart';
import 'foundation/tape_button.dart';
import 'foundation/text_action.dart';
import 'mix_handoff.dart' show mixPlayFailureMessage;
import 'playlist_artwork.dart' show playlistArtworkUrl, playlistArtworkColor;

/// "44 min", "1 h 12 min", "2 h".
String albumLengthLabel(int durationMs) {
  final minutes = (durationMs / 60000).round();
  if (minutes < 60) return '$minutes min';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? '$h h' : '$h h $m min';
}

/// The same length in words, for VoiceOver.
String albumSpokenLength(int durationMs) {
  final minutes = (durationMs / 60000).round();
  String unit(int n, String word) => '$n $word${n == 1 ? '' : 's'}';
  if (minutes < 60) return unit(minutes, 'minute');
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? unit(h, 'hour') : '${unit(h, 'hour')} ${unit(m, 'minute')}';
}

String _songs(int n) => n == 1 ? '1 song' : '$n songs';

/// "{Type} · {year} · {n} songs · {length}", absent parts omitted.
String albumMetaLine(AlbumPick album) => [
  if (album.typeLabel.isNotEmpty) album.typeLabel,
  if (album.releaseYear != null) '${album.releaseYear}',
  if (album.trackCount != null) _songs(album.trackCount!),
  if (album.durationMs != null) albumLengthLabel(album.durationMs!),
].join(' · ');

/// The type as VoiceOver says it: "album", "live", but "EP" stays capitals.
String _spokenType(AlbumPick album) {
  final label = album.typeLabel;
  return label == label.toUpperCase() ? label : label.toLowerCase();
}

/// "{title}, by {artist}, {type}, {year}, {n} songs, {length}[, new to you]".
String albumCardLabel(AlbumPick album) => [
  album.title,
  'by ${album.artist}',
  if (album.typeLabel.isNotEmpty) _spokenType(album),
  if (album.releaseYear != null) '${album.releaseYear}',
  if (album.trackCount != null) _songs(album.trackCount!),
  if (album.durationMs != null) albumSpokenLength(album.durationMs!),
  if (album.newToThem) 'new to you',
].join(', ');

/// "{artist} · {Type} · {year}", the runner-up row's second line.
String _runnerLine(AlbumPick album) => [
  album.artist,
  if (album.typeLabel.isNotEmpty) album.typeLabel,
  if (album.releaseYear != null) '${album.releaseYear}',
].join(' · ');

const String _newToYou = 'New to you';

/// The Spotify search a Spotify-only listener is sent to: there are no
/// Spotify album ids, so artist and title it is.
/// One path segment, so a slash in a name ("AC/DC") is encoded, not a path.
Uri albumSpotifySearch(AlbumPick album) => Uri(
  scheme: 'https',
  host: 'open.spotify.com',
  pathSegments: ['search', '${album.artist} ${album.title}'],
);

class AlbumCard extends ConsumerStatefulWidget {
  const AlbumCard({
    super.key,
    required this.pick,
    required this.onToggleListenLater,
    required this.onPick,
    this.runnersUp = const [],
    this.enabled = true,
  });

  final AlbumPick pick;
  final List<AlbumPick> runnersUp;

  /// Saves or unsaves [pick] (the notifier's optimistic toggle); true when
  /// the write landed.
  final Future<bool> Function() onToggleListenLater;

  /// "Pick this" on a runner-up.
  final void Function(String albumId) onPick;

  /// False while a turn is sending: the card's writes wait for it.
  final bool enabled;

  static const Key cardKey = Key('album-card');
  static const Key coverKey = Key('album-cover');
  static const Key metaKey = Key('album-meta');
  static const Key actionsKey = Key('album-actions');
  static const Key playKey = Key('album-play-now');
  static const Key spotifyKey = Key('album-open-spotify');
  static const Key laterKey = Key('album-listen-later');
  static const Key runnersKey = Key('album-runners-toggle');
  static Key runnerKey(String id) => ValueKey('album-runner-$id');
  static Key pickKey(String id) => ValueKey('album-pick-$id');

  static const String savedToast = 'On your Listen later shelf.';

  /// `.album .cover` and its 1.5x `.cover.sm`.
  static const double coverSize = 112;
  static const double compactCoverSize = 60;

  @override
  ConsumerState<AlbumCard> createState() => _AlbumCardState();
}

class _AlbumCardState extends ConsumerState<AlbumCard> {
  bool _runnersOpen = false;
  bool _playing = false;

  Future<void> _play(String appleId) async {
    if (_playing) return;
    setState(() => _playing = true);
    try {
      await ref.read(musicKitBridgeProvider).playAlbum(appleId);
    } on MusicKitException catch (e) {
      if (mounted) {
        _toast(mixPlayFailureMessage(e.message), kind: FeedbackKind.error);
      }
    } finally {
      if (mounted) setState(() => _playing = false);
    }
  }

  Future<void> _openSpotify() async {
    var opened = false;
    try {
      opened = await ref.read(linkOpenerProvider)(
        albumSpotifySearch(widget.pick),
      );
    } catch (_) {
      opened = false;
    }
    if (!mounted || opened) return;
    _toast("couldn't open Spotify", kind: FeedbackKind.error);
  }

  Future<void> _toggleLater() async {
    final saving = !widget.pick.savedForLater;
    final albumId = widget.pick.id;
    final ok = await widget.onToggleListenLater();
    if (!mounted || !ok || !saving) return;
    // Only a save confirms; unsaving is its own answer.
    _toast(
      AlbumCard.savedToast,
      kind: FeedbackKind.success,
      actionLabel: 'Undo',
      onAction: () => _undoSave(albumId),
    );
  }

  /// The toast outlives the card on the app-level messenger: Undo acts only
  /// while this card is still up (so the conversation and its notifier are
  /// alive) and still shows the album that was saved, saved. A "Pick this"
  /// or a pop in between makes it a no-op rather than toggling the wrong
  /// album or a disposed notifier.
  void _undoSave(String albumId) {
    if (!mounted) return;
    final pick = widget.pick;
    if (pick.id != albumId || !pick.savedForLater) return;
    widget.onToggleListenLater();
  }

  void _toast(
    String message, {
    FeedbackKind kind = FeedbackKind.info,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        mixtapeSnackBar(
          message: message,
          kind: kind,
          actionLabel: actionLabel,
          onAction: onAction,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final pick = widget.pick;
    final large = MediaQuery.textScalerOf(context).scale(1) >= 1.5;
    final spotifyOnly =
        ref.watch(onboardingProvider).value?.chosenService == 'spotify';

    final title = Text(
      pick.title,
      style: tokens.rowTitle.copyWith(
        fontSize: 16.5,
        fontWeight: FontWeight.w700,
        height: 1.2,
        letterSpacing: -0.15,
      ),
    );
    final artist = Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        pick.artist,
        style: tokens.secondary.copyWith(fontSize: 13.5, color: tokens.smoke),
      ),
    );
    final meta = Padding(
      padding: const EdgeInsets.only(top: 4),
      child: _MetaLine(album: pick),
    );
    final cover = _AlbumCover(
      key: AlbumCard.coverKey,
      album: pick,
      size: large ? AlbumCard.compactCoverSize : AlbumCard.coverSize,
      radius: large ? 4 : 6,
      shadow: !large,
    );

    final header = large
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  cover,
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [title, artist],
                    ),
                  ),
                ],
              ),
              meta,
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              cover,
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [title, artist, meta],
                ),
              ),
            ],
          );

    final appleId = pick.appleId;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            key: AlbumCard.cardKey,
            container: true,
            label: albumCardLabel(pick),
            hint: pick.reason.isEmpty ? null : pick.reason,
            excludeSemantics: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                header,
                if (pick.reason.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(pick.reason, style: tokens.body),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(
              key: AlbumCard.actionsKey,
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (spotifyOnly)
                  TextAction(
                    key: AlbumCard.spotifyKey,
                    label: 'Open in Spotify',
                    underline: true,
                    onPressed: _openSpotify,
                  )
                else
                  // The tape button is 40 pt; the stop around it makes 44.
                  ConstrainedBox(
                    key: AlbumCard.playKey,
                    constraints: const BoxConstraints(
                      minHeight: MixtapeMetrics.minTarget,
                    ),
                    child: Center(
                      widthFactor: 1,
                      heightFactor: 1,
                      child: TapeButton(
                        label: 'Play now',
                        onPressed: appleId == null || _playing
                            ? null
                            : () => _play(appleId),
                      ),
                    ),
                  ),
                _ListenLaterChip(
                  key: AlbumCard.laterKey,
                  saved: pick.savedForLater,
                  onPressed: widget.enabled ? _toggleLater : null,
                ),
              ],
            ),
          ),
          if (widget.runnersUp.isNotEmpty) _runners(context),
        ],
      ),
    );
  }

  Widget _runners(BuildContext context) {
    final tokens = context.tokens;
    final reduced = MediaQuery.disableAnimationsOf(context);
    final duration = reduced
        ? Duration.zero
        : const Duration(milliseconds: 200);
    final count = widget.runnersUp.length;
    final label = count == 1
        ? 'One more it considered'
        : '${_countWord(count)} more it considered';

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: _runnersOpen,
            label: label,
            onTap: () => setState(() => _runnersOpen = !_runnersOpen),
            excludeSemantics: true,
            child: GestureDetector(
              key: AlbumCard.runnersKey,
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _runnersOpen = !_runnersOpen),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: MixtapeMetrics.minTarget,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: tokens.secondary.copyWith(
                          fontSize: 12.5,
                          color: tokens.smoke,
                        ),
                      ),
                    ),
                    AnimatedRotation(
                      turns: _runnersOpen ? 0.5 : 0,
                      duration: duration,
                      curve: Curves.easeOut,
                      child: Icon(
                        CupertinoIcons.chevron_down,
                        size: 16,
                        color: tokens.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          ClipRect(
            child: AnimatedSize(
              duration: duration,
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: _runnersOpen
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (var i = 0; i < widget.runnersUp.length; i++)
                          _RunnerRow(
                            key: AlbumCard.runnerKey(widget.runnersUp[i].id),
                            album: widget.runnersUp[i],
                            divider: i > 0,
                            onPick: widget.enabled
                                ? () => widget.onPick(widget.runnersUp[i].id)
                                : null,
                          ),
                      ],
                    )
                  : const SizedBox(width: double.infinity),
            ),
          ),
        ],
      ),
    );
  }

  static String _countWord(int n) => switch (n) {
    2 => 'Two',
    3 => 'Three',
    4 => 'Four',
    _ => '$n',
  };
}

/// The meta line: one paragraph that wraps as a whole, so the mark (and the
/// dot that leads it) moves to the next line together and never truncates.
class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.album});

  final AlbumPick album;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final style = tokens.meta;
    final line = albumMetaLine(album);
    return Text.rich(
      key: AlbumCard.metaKey,
      TextSpan(
        style: style,
        children: [
          TextSpan(text: line),
          if (album.newToThem)
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: _Mark(leading: line.isEmpty ? '' : ' · ', style: style),
            ),
        ],
      ),
    );
  }
}

/// "· New to you": the dot in the line's ink, the words in plum 600.
class _Mark extends StatelessWidget {
  const _Mark({required this.leading, required this.style});

  final String leading;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.baseline,
    textBaseline: TextBaseline.alphabetic,
    children: [
      if (leading.isNotEmpty) Text(leading, style: style),
      const StatusWord(label: _newToYou, kind: StatusKind.accent, icon: false),
    ],
  );
}

/// The Apple artwork template at the size drawn, over the artwork's own
/// background colour while it loads.
class _AlbumCover extends StatelessWidget {
  const _AlbumCover({
    super.key,
    required this.album,
    required this.size,
    required this.radius,
    this.shadow = false,
    this.opacity = 1,
  });

  final AlbumPick album;
  final double size;
  final double radius;
  final bool shadow;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final art = album.artwork;
    final bg = art?.bgColor?.replaceFirst('#', '').toLowerCase();
    Widget cover = SquareArt(
      url: playlistArtworkUrl(art?.url, size: (size * 3).round()),
      placeholder: playlistArtworkColor(bg),
      size: size,
      radius: radius,
    );
    if (opacity < 1) cover = Opacity(opacity: opacity, child: cover);
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          boxShadow: shadow
              ? [
                  BoxShadow(
                    color: isDark
                        ? const Color.fromRGBO(0, 0, 0, 0.5)
                        : const Color.fromRGBO(30, 24, 30, 0.22),
                    offset: const Offset(0, 8),
                    blurRadius: 22,
                  ),
                ]
              : null,
        ),
        child: cover,
      ),
    );
  }
}

/// `.chip` with the bookmark glyph; `.chip.on` when saved: plum fill,
/// inverted ink, "Saved for later", toggled for VoiceOver.
class _ListenLaterChip extends StatelessWidget {
  const _ListenLaterChip({super.key, required this.saved, this.onPressed});

  final bool saved;
  final VoidCallback? onPressed;

  static const BorderRadius _radius = BorderRadius.only(
    topLeft: Radius.circular(MixtapeMetrics.tapeRadiusTop),
    topRight: Radius.circular(MixtapeMetrics.tapeRadiusTop),
    bottomLeft: Radius.circular(MixtapeMetrics.tapeRadiusBottom),
    bottomRight: Radius.circular(MixtapeMetrics.tapeRadiusBottom),
  );

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final enabled = onPressed != null;
    final label = saved ? 'Saved for later' : 'Listen later';
    final ink = saved ? tokens.sheetSurface : tokens.plum;

    final chip = Container(
      constraints: const BoxConstraints(minHeight: MixtapeMetrics.chipHeight),
      padding: const EdgeInsets.symmetric(horizontal: 11),
      decoration: BoxDecoration(
        color: saved
            ? tokens.plum
            : (isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : const Color.fromRGBO(247, 244, 239, 0.60)),
        borderRadius: _radius,
        border: Border.all(
          color: saved
              ? Colors.transparent
              : (isDark
                    ? Colors.white.withValues(alpha: 0.16)
                    : const Color.fromRGBO(73, 64, 72, 0.22)),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            saved ? CupertinoIcons.bookmark_fill : CupertinoIcons.bookmark,
            size: 14,
            color: ink,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: ink,
              ),
            ),
          ),
        ],
      ),
    );

    return Semantics(
      button: true,
      enabled: enabled,
      toggled: saved,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: MixtapeMetrics.minTarget,
          ),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Opacity(opacity: enabled ? 1 : 0.5, child: chip),
          ),
        ),
      ),
    );
  }
}

/// `.rrow`: a runner-up with "Pick this", which is also its rotor action.
class _RunnerRow extends StatelessWidget {
  const _RunnerRow({
    super.key,
    required this.album,
    required this.divider,
    required this.onPick,
  });

  final AlbumPick album;
  final bool divider;
  final VoidCallback? onPick;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final spoken = [
      album.title,
      album.artist,
      if (album.typeLabel.isNotEmpty) album.typeLabel,
      if (album.releaseYear != null) '${album.releaseYear}',
      if (album.newToThem) 'new to you',
    ].join(', ');
    return Semantics(
      container: true,
      label: spoken,
      customSemanticsActions: onPick == null
          ? null
          : {const CustomSemanticsAction(label: 'Pick this'): onPick!},
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: divider
              ? Border(top: BorderSide(color: tokens.hairline))
              : null,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            children: [
              _AlbumCover(album: album, size: 48, radius: 4),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      album.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.rowTitle.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            _runnerLine(album),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: tokens.meta,
                          ),
                        ),
                        // The mark never shrinks; the who-line gives way.
                        if (album.newToThem)
                          _Mark(leading: ' · ', style: tokens.meta),
                      ],
                    ),
                  ],
                ),
              ),
              TextAction(
                key: AlbumCard.pickKey(album.id),
                label: 'Pick this',
                onPressed: onPick,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `.passed`: an earlier pick, muted at 40 pt, "Passed over" in words, with
/// "Go back" (also its rotor action), which restores it as a new version.
class PassedOverRow extends StatelessWidget {
  const PassedOverRow({super.key, required this.album, this.onGoBack});

  final AlbumPick album;
  final void Function(int version)? onGoBack;

  static Key keyFor(int version) => ValueKey('album-passed-$version');
  static Key goBackKey(int version) => ValueKey('album-go-back-$version');
  static const Key coverKey = Key('album-passed-cover');

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final goBack = onGoBack == null ? null : () => onGoBack!(album.version);
    return Semantics(
      key: keyFor(album.version),
      container: true,
      label: '${album.title}, passed over',
      customSemanticsActions: goBack == null
          ? null
          : {const CustomSemanticsAction(label: 'Go back'): goBack},
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            _AlbumCover(
              key: coverKey,
              album: album,
              size: 40,
              radius: 3,
              opacity: 0.75,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    album.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: tokens.smoke,
                    ),
                  ),
                  Text(
                    'Passed over',
                    style: tokens.meta.copyWith(color: tokens.muted),
                  ),
                ],
              ),
            ),
            TextAction(
              key: goBackKey(album.version),
              label: 'Go back',
              onPressed: goBack,
            ),
          ],
        ),
      ),
    );
  }
}
