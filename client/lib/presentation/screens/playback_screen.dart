/// Now Playing, and the listening preferences behind its More menu
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md` → Now Playing,
/// Background, Prism; frame P1 and `.np*` in
/// `docs/mockups/2026-09-17-mobile-shell-r3.html`; plan task 6.1).
///
/// The shell pushes this onto the current tab's navigator from the
/// mini-player and hides the dock for it, so it reads as a sheet: a drag
/// handle, no title bar, and a small Close chevron for anyone who does not
/// use the back gesture.
///
/// It keeps its own ground. The board swaps the screen gradient's glow for
/// the artwork's dominant colours over a dark fall with light text, in both
/// system themes — so the whole sheet builds under [MixtapeTheme.dark] rather
/// than the ambient theme.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dj/dj_models.dart';
import '../../data/playback/playback_controller.dart';
import '../providers/library_sync_provider.dart';
import '../providers/playback_provider.dart';
import '../theme/mixtape_theme.dart';
import '../widgets/energy_journey.dart';
import '../widgets/mix_energy_summary.dart';
import '../widgets/now_playing_scrubber.dart';
import '../widgets/playlist_artwork.dart';
import '../widgets/foundation/cassette_tile.dart';
import '../widgets/foundation/glass_cluster.dart';
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/inset_group.dart';
import '../widgets/foundation/section_word.dart';
import '../widgets/foundation/square_art.dart';
import '../widgets/foundation/tape_button.dart';
import 'queue_screen.dart';

/// What the More menu offers.
enum _NowPlayingMenu { repeat, stop, listening }

class PlaybackScreen extends ConsumerWidget {
  const PlaybackScreen({super.key});

  /// The board's empty-artwork mark, mono and capitalised.
  static const String artworkPlaceholder = 'ALBUM ARTWORK';

  /// The mini-player's rule, on the bigger surface: a track Apple Music will
  /// not play here says so where the artist would be, and only Next works.
  static const String unavailableLine = 'Not available in your region';

  static const String sentToMusicMessage =
      'Playing in Music. Listening there is not observed.';
  static const String sendFailedMessage = 'Could not send to Music.';
  static const String nothingPlayingLine = 'Nothing is playing yet.';

  /// The board's gutter, either side of everything on the sheet.
  static const double sidePadding = 26;

  /// Artwork is the screen width less this — the two gutters.
  static const double artworkInset = sidePadding * 2;
  static const double artworkRadius = 8;

  /// The cassette on the mix line.
  static const double mixLineCassetteWidth = 22;

  /// The More button's circle, inside a 44 pt target.
  static const double moreDiameter = 34;

  /// Transport targets, and the play/pause glyph.
  static const double transportTarget = 64;
  static const double transportGlyph = 38;
  static const double transportPlayGlyph = 48;
  static const double transportGap = 36;

  /// The bottom action columns.
  static const double actionColumn = 64;
  static const double actionGap = 28;

  static const Key dragHandleKey = Key('now-playing-handle');
  static const Key closeKey = Key('now-playing-close');
  static const Key moreKey = Key('now-playing-more');
  static const Key previousKey = Key('now-playing-previous');
  static const Key playPauseKey = Key('now-playing-play-pause');
  static const Key nextKey = Key('now-playing-next');
  static const Key shapeKey = Key('now-playing-shape');
  static const Key upNextKey = Key('now-playing-up-next');
  static const Key sendToMusicKey = Key('now-playing-send-to-music');
  static const Key connectKey = Key('now-playing-connect');
  static const Key errorLineKey = Key('now-playing-error');

  /// Both messages the controller writes about Apple Music itself start with
  /// its name; every other error it writes is transient.
  static const String connectErrorMark = 'Apple Music';

  /// The two colours the background glows with: the track's stored artwork
  /// colour and a darker, less saturated companion. Null keeps the token
  /// glows, which is what a track with no colour gets.
  @visibleForTesting
  static List<Color>? artworkColorsFor(QueueTrack? track) {
    final base = playlistArtworkColor(track?.artworkBgColor);
    if (base == null) return null;
    final hsl = HSLColor.fromColor(base);
    return [
      base,
      hsl
          .withSaturation((hsl.saturation * 0.55).clamp(0.0, 1.0))
          .withLightness((hsl.lightness * 0.45).clamp(0.0, 1.0))
          .toColor(),
    ];
  }

  /// Everything the sheet draws EXCEPT the playing position. The position
  /// ticks about once a second; rebuilding artwork, the cassette and the
  /// actions that often would be a waste, so the sheet listens for this and
  /// the scrubber listens for the position on its own.
  static ({
    String? sessionId,
    String title,
    int version,
    String error,
    bool busy,
    int? unavailableIndex,
    int? index,
    String status,
    List<QueueTrack> tracks,
  })
  sheetSnapshot(PlaybackController player) => (
    sessionId: player.sessionId,
    title: player.title,
    version: player.version,
    error: player.error,
    busy: player.busy,
    unavailableIndex: player.unavailableIndex,
    index: player.sample.index,
    status: player.sample.status,
    // Identity: the controller replaces the list rather than editing it.
    tracks: player.tracks,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playbackProvider);
    return Theme(
      data: MixtapeTheme.dark(),
      // The sheet keeps the dark ground in both system themes, so the status
      // bar's glyphs have to be told to stay light over it.
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: _PlayerListener(
          player: player,
          select: sheetSnapshot,
          builder: (context, _) => _NowPlaying(player: player, ref: ref),
        ),
      ),
    );
  }
}

/// Rebuilds [builder] only when [select] reports something new about the
/// player. One ChangeNotifier drives the whole sheet; this is how the parts
/// of it that do not care about the position stay still while it ticks.
class _PlayerListener<T> extends StatefulWidget {
  const _PlayerListener({
    required this.player,
    required this.select,
    required this.builder,
  });

  final PlaybackController player;
  final T Function(PlaybackController player) select;
  final Widget Function(BuildContext context, T value) builder;

  @override
  State<_PlayerListener<T>> createState() => _PlayerListenerState<T>();
}

class _PlayerListenerState<T> extends State<_PlayerListener<T>> {
  late T _value = widget.select(widget.player);

  @override
  void initState() {
    super.initState();
    widget.player.addListener(_sync);
  }

  @override
  void didUpdateWidget(_PlayerListener<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.player, widget.player)) {
      oldWidget.player.removeListener(_sync);
      widget.player.addListener(_sync);
    }
    _value = widget.select(widget.player);
  }

  @override
  void dispose() {
    widget.player.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    final next = widget.select(widget.player);
    if (next != _value && mounted) setState(() => _value = next);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}

class _NowPlaying extends StatelessWidget {
  const _NowPlaying({required this.player, required this.ref});

  final PlaybackController player;

  /// The screen's own [WidgetRef], for reads inside callbacks. Anything that
  /// must be *watched* uses a nested [Consumer] instead, because this builder
  /// runs again on every player notification, outside the widget's build.
  final WidgetRef ref;

  /// The track the listener is looking at — the one the player could not
  /// play first, exactly as the mini-player resolves it.
  int get _index => player.unavailableIndex ?? player.sample.index ?? 0;

  QueueTrack? get _track =>
      _index >= 0 && _index < player.tracks.length ? player.tracks[_index] : null;

  bool get _unavailable => player.unavailableIndex != null;

  bool get _playing => player.sample.status == 'playing';

  /// The Apple Music access path the previous player screen offered, and
  /// still does: no tracks to play, or an error the controller wrote about
  /// Apple Music itself (authorisation refused, or a start it could not make).
  ///
  /// Transient trouble — observation dropping out, an interrupted command, a
  /// stop that did not land — is NOT that: it says so on a line above the
  /// transport and leaves the sheet playing.
  bool get _needsConnection =>
      !_unavailable && player.error.startsWith(PlaybackScreen.connectErrorMark);

  @override
  Widget build(BuildContext context) {
    final track = _track;
    final showPlayer = track != null && !_needsConnection;

    return GradientBackground(
      artworkColors: PlaybackScreen.artworkColorsFor(track),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(context),
              Expanded(
                child: showPlayer
                    ? _player(context, track)
                    : _connect(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// A drag handle and a Close chevron. No title bar: the song is the title.
  Widget _header(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Stack(
      alignment: Alignment.center,
      children: [
        Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Container(
              key: PlaybackScreen.dragHandleKey,
              width: 36,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: GlassButton(
            key: PlaybackScreen.closeKey,
            icon: Icons.keyboard_arrow_down,
            label: 'Close',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
      ],
    ),
  );

  /// Nothing to play, or Apple Music is not connected: the board's centred
  /// state, with the error the controller wrote and one way back in.
  Widget _connect(BuildContext context) {
    final tokens = context.tokens;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: PlaybackScreen.sidePadding,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              player.error.isEmpty
                  ? PlaybackScreen.nothingPlayingLine
                  : player.error,
              textAlign: TextAlign.center,
              style: tokens.body.copyWith(color: tokens.smoke),
            ),
            const SizedBox(height: 20),
            TapeButton(
              key: PlaybackScreen.connectKey,
              label: 'Connect Apple Music',
              onPressed: player.busy || player.sessionId == null
                  ? null
                  : player.reconnect,
            ),
          ],
        ),
      ),
    );
  }

  Widget _player(BuildContext context, QueueTrack track) => ListView(
    padding: const EdgeInsets.fromLTRB(
      PlaybackScreen.sidePadding,
      22,
      PlaybackScreen.sidePadding,
      24,
    ),
    children: [
      _artwork(context, track),
      const SizedBox(height: 24),
      _meta(context, track),
      const SizedBox(height: 10),
      _mixLine(context),
      const SizedBox(height: 18),
      _scrubber(track),
      if (player.error.isNotEmpty) _errorLine(context),
      const SizedBox(height: 22),
      _transport(),
      const SizedBox(height: 34),
      _actions(context),
    ],
  );

  Widget _artwork(BuildContext context, QueueTrack track) {
    final url = playlistArtworkUrl(track.artworkUrl, size: 900);
    final base = playlistArtworkColor(track.artworkBgColor);
    return LayoutBuilder(
      builder: (context, constraints) {
        // The board's artwork is the screen width less 52 — which is exactly
        // the list's own 26 pt gutters, already taken off here.
        final side = constraints.maxWidth;
        return Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(PlaybackScreen.artworkRadius),
              boxShadow: const [
                BoxShadow(
                  color: Color.fromRGBO(0, 0, 0, 0.5),
                  offset: Offset(0, 20),
                  blurRadius: 50,
                ),
              ],
            ),
            child: SquareArt(
              url: url,
              size: side,
              radius: PlaybackScreen.artworkRadius,
              placeholderGradient: base == null
                  ? null
                  : [base, Color.lerp(base, Colors.black, 0.45)!],
              child: url == null
                  ? Text(
                      PlaybackScreen.artworkPlaceholder,
                      textAlign: TextAlign.center,
                      style: NowPlayingScrubber.timeStyle.copyWith(
                        letterSpacing: 1.44,
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                    )
                  : null,
            ),
          ),
        );
      },
    );
  }

  Widget _meta(BuildContext context, QueueTrack track) {
    final tokens = context.tokens;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tokens.smallTitle,
              ),
              const SizedBox(height: 2),
              Text(
                _unavailable ? PlaybackScreen.unavailableLine : track.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tokens.body.copyWith(color: tokens.muted),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _more(context),
      ],
    );
  }

  Widget _more(BuildContext context) {
    final tokens = context.tokens;
    return PopupMenuButton<_NowPlayingMenu>(
      key: PlaybackScreen.moreKey,
      tooltip: 'More',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      onSelected: (value) => switch (value) {
        _NowPlayingMenu.repeat => player.command('repeat'),
        _NowPlayingMenu.stop => player.stop(),
        _NowPlayingMenu.listening => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const ListeningPreferencesScreen(),
          ),
        ),
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: _NowPlayingMenu.repeat,
          child: Text('Repeat song'),
        ),
        PopupMenuItem(
          value: _NowPlayingMenu.stop,
          // While a command is in flight, stopping is how it is cancelled —
          // the word HEAD's player used for exactly this call.
          child: Text(player.busy ? 'Cancel' : 'Stop'),
        ),
        const PopupMenuItem(
          value: _NowPlayingMenu.listening,
          child: Text('Listening preferences'),
        ),
      ],
      child: SizedBox.square(
        dimension: MixtapeMetrics.minTarget,
        child: Center(
          child: Container(
            width: PlaybackScreen.moreDiameter,
            height: PlaybackScreen.moreDiameter,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.more_horiz, size: 20, color: tokens.text),
          ),
        ),
      ),
    );
  }

  /// The mix, as one muted line: a 22 pt cassette and "mix · n of count".
  Widget _mixLine(BuildContext context) {
    final tokens = context.tokens;
    if (player.sessionId == null || player.tracks.isEmpty) {
      return const SizedBox.shrink();
    }
    return Row(
      children: [
        CassetteTile(
          width: PlaybackScreen.mixLineCassetteWidth,
          seedId: player.sessionId,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '${player.title} · ${_index + 1} of ${player.tracks.length}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tokens.meta.copyWith(color: tokens.muted),
          ),
        ),
      ],
    );
  }

  Widget _scrubber(QueueTrack track) {
    final duration = track.durationMs ?? 0;
    // The player channel takes seconds; the controller already speaks it.
    final canSeek = !_unavailable && !player.busy && duration > 0;
    return _PlayerListener<double>(
      player: player,
      select: (player) => player.sample.positionMs,
      builder: (context, positionMs) => NowPlayingScrubber(
        positionMs: positionMs,
        durationMs: duration,
        onSeek: canSeek
            ? (seconds) => player.command('seek', seconds: seconds)
            : null,
      ),
    );
  }

  /// Trouble the sheet can keep playing through, said once and quietly.
  Widget _errorLine(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        player.error,
        key: PlaybackScreen.errorLineKey,
        textAlign: TextAlign.center,
        style: tokens.meta.copyWith(color: tokens.muted),
      ),
    );
  }

  Widget _transport() {
    // An unavailable track leaves Next alone, as the mini-player does.
    final enabled = !player.busy && !_unavailable;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _TransportButton(
          key: PlaybackScreen.previousKey,
          icon: Icons.skip_previous,
          label: 'Previous song',
          onPressed: enabled ? () => player.command('previous') : null,
        ),
        const SizedBox(width: PlaybackScreen.transportGap),
        _TransportButton(
          key: PlaybackScreen.playPauseKey,
          icon: _playing ? Icons.pause : Icons.play_arrow,
          label: _playing ? 'Pause' : 'Play',
          glyph: PlaybackScreen.transportPlayGlyph,
          onPressed: enabled
              ? () => player.command(_playing ? 'pause' : 'resume')
              : null,
        ),
        const SizedBox(width: PlaybackScreen.transportGap),
        _TransportButton(
          key: PlaybackScreen.nextKey,
          icon: Icons.skip_next,
          label: 'Next song',
          onPressed: player.busy ? null : () => player.command('next'),
        ),
      ],
    );
  }

  Widget _actions(BuildContext context) {
    final sessionId = player.sessionId;
    final enabled = !_unavailable && sessionId != null;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Consumer(
          builder: (context, ref, _) {
            final energy = enabled
                ? ref.watch(
                    mixEnergyProvider((
                      id: sessionId,
                      version: player.version,
                    )),
                  )
                : null;
            final detail = energy != null && energy.hasValue
                ? energy.value
                : null;
            final shape = _shapeOf(detail);
            return _NowPlayingAction(
              key: PlaybackScreen.shapeKey,
              icon: Icons.show_chart,
              label: 'Shape',
              onPressed: shape == null
                  ? null
                  : () => _openShape(context, detail!),
            );
          },
        ),
        const SizedBox(width: PlaybackScreen.actionGap),
        _NowPlayingAction(
          key: PlaybackScreen.upNextKey,
          icon: Icons.queue_music,
          label: 'Up next',
          // The board draws Up next as the one lit action: it is where this
          // mix lives.
          active: true,
          onPressed: enabled
              ? () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => QueueScreen(sessionId: sessionId),
                  ),
                )
              : null,
        ),
        const SizedBox(width: PlaybackScreen.actionGap),
        _NowPlayingAction(
          key: PlaybackScreen.sendToMusicKey,
          icon: Icons.ios_share,
          label: 'Send to Music',
          onPressed: enabled && !player.busy && player.tracks.isNotEmpty
              ? () => _sendToMusic(context)
              : null,
        ),
      ],
    );
  }

  /// The mix's energy shape, if this version has one the sheet can show.
  EnergyArc? _shapeOf(Map<String, dynamic>? detail) {
    if (detail == null || detail['energyJourney'] is! Map) return null;
    return EnergyArc.values
        .where((arc) => arc.name == detail['energyArc'])
        .firstOrNull;
  }

  void _openShape(BuildContext context, Map<String, dynamic> detail) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            PlaybackScreen.sidePadding,
            8,
            PlaybackScreen.sidePadding,
            20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionWord('Shape'),
              EnergyAssessment(detail: detail),
            ],
          ),
        ),
      ),
    );
  }

  /// The existing handoff, copy unchanged: the app player stops first, so two
  /// players are never observing the same listener at once.
  Future<void> _sendToMusic(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final ids = [
      for (final track in player.tracks)
        if (track.appleId != null) track.appleId!,
    ];
    await player.stop();
    try {
      await ref.read(musicKitBridgeProvider).playQueue(ids);
      messenger.showSnackBar(
        const SnackBar(content: Text(PlaybackScreen.sentToMusicMessage)),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text(PlaybackScreen.sendFailedMessage)),
      );
    }
  }
}

/// One 64 pt round transport target, white on the artwork gradient.
class _TransportButton extends StatelessWidget {
  const _TransportButton({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
    this.glyph = PlaybackScreen.transportGlyph,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final double glyph;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: SizedBox.square(
          dimension: PlaybackScreen.transportTarget,
          child: Center(
            child: Opacity(
              opacity: enabled ? 1 : 0.35,
              child: Icon(icon, size: glyph, color: tokens.text),
            ),
          ),
        ),
      ),
    );
  }
}

/// One bottom action: glyph over a small label, 64 pt wide.
class _NowPlayingAction extends StatelessWidget {
  const _NowPlayingAction({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  /// The lit action; the rest are muted (`.np-acts button.on`).
  final bool active;

  /// The board's 10.5 pt label.
  static const double labelSize = 10.5;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final enabled = onPressed != null;
    final color = active ? tokens.text : tokens.muted;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: MixtapeMetrics.minTarget,
            ),
            child: SizedBox(
              width: PlaybackScreen.actionColumn,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 24, color: color),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: labelSize,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PlaybackMini extends ConsumerWidget {
  const PlaybackMini({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playbackProvider);
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        if (player.sessionId == null) return const SizedBox.shrink();
        final index = player.unavailableIndex ?? player.sample.index ?? 0;
        final track = index < player.tracks.length
            ? player.tracks[index]
            : null;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: ListTile(
            title: Text(
              track?.title ?? player.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              player.busy
                  ? 'Getting ready…'
                  : player.error.isNotEmpty
                  ? 'Playback unavailable'
                  : player.sample.status == 'playing'
                  ? 'Playing'
                  : 'Paused',
            ),
            trailing: const Icon(Icons.open_in_full),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PlaybackScreen()),
            ),
          ),
        );
      },
    );
  }
}

class ListeningPreferencesScreen extends ConsumerStatefulWidget {
  const ListeningPreferencesScreen({super.key});
  @override
  ConsumerState<ListeningPreferencesScreen> createState() =>
      _ListeningPreferencesState();
}

class _ListeningPreferencesState
    extends ConsumerState<ListeningPreferencesScreen> {
  bool busy = false;
  String message = '';
  String? clearId;
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(playbackProvider).initialize());
  }

  Future<void> save(bool enabled) async {
    setState(() => busy = true);
    try {
      await ref.read(playbackProvider).setLearning(enabled);
      if (mounted) {
        setState(
          () => message = enabled
              ? 'Listening learning is on.'
              : 'Listening learning is off.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'Could not save. Collection is paused until you try again.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> clear() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear learned listening?'),
        content: const Text(
          'Remove listening activity collected for learning. Imported history, mixes and written preferences stay.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear learned listening'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => busy = true);
    clearId ??= playbackUuid();
    try {
      await ref.read(playbackProvider).clear(clearId!);
      if (mounted) {
        setState(() {
          message = 'Learned listening cleared.';
          clearId = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'Could not confirm clearing. Retry to check the same request.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playbackProvider);
    final tokens = context.tokens;
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) => GradientBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(title: const Text('Listening preferences')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              children: [
                Text('Let listening shape your mixes.', style: tokens.section),
                const SizedBox(height: 8),
                Text(
                  'Patterns in skips, repeats and listening help the DJ adapt. One skipped song does not mean you dislike it.',
                  style: tokens.secondary,
                ),
                const SizedBox(height: 16),
                InsetGroup(
                  children: [
                    InsetRow(
                      title: 'Learn from my listening in Mixtape',
                      trailing: Switch(
                        value: player.preferences?['enabled'] == true,
                        onChanged: busy ? null : save,
                      ),
                    ),
                    InsetRow(
                      title: 'Clear learned listening',
                      destructive: true,
                      trailing: const SizedBox.shrink(),
                      onTap: busy ? null : clear,
                    ),
                  ],
                ),
                Text(
                  'Imported history and preferences you told the DJ stay separate.',
                  style: tokens.secondary,
                ),
                if (message.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(message, style: tokens.body),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
