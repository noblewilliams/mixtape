/// A mix someone shared (spec `2026-11-13-shared-mixes-design.md` →
/// Recipient in the app; board `docs/mockups/2026-11-13-shared-mixes.html`,
/// frames R1–R7, approved in `docs/mockups/approved/2026-11-13-shared-mixes.md`).
///
/// The tape screen's layout, read-only: the cassette in the share's colour,
/// the title, "From Ada", the songs and the listener's own mix actions
/// ([MixActions]). No composer, no swipe, no grips, no rename, no history;
/// the header is Back only. It reads `GET /shared/:token` with or without a
/// session, so it works before first run.
///
/// * The sender's own link opens their conversation instead.
/// * The share is saved to the listener's Mixes once, through
///   [pendingShareSaveProvider], which waits for a session when there is
///   none yet.
/// * No platform chosen yet: the Apple Music pair shows, and the first tap
///   asks "Where do you listen?" before going on.
/// * Nothing played or saved here counts as the listener's evidence
///   ([MixHandoff.mixRecordsEvidence]).
/// * A stopped or unknown link reads "This mix isn't shared anymore.", with
///   Remove only when the listener has it saved ([SharedMixScreen.fromMixes]).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dj/dj_api.dart';
import '../../data/dj/dj_models.dart';
import '../../data/playback/playback_controller.dart' show sharedPlaybackPrefix;
import '../providers/auth_provider.dart';
import '../providers/dj_providers.dart';
import '../providers/library_sync_provider.dart';
import '../providers/music_platform_provider.dart';
import '../providers/onboarding_provider.dart';
import '../providers/pending_share_save_provider.dart';
import '../theme/mixtape_theme.dart';
import '../widgets/foundation/cassette_tile.dart';
import '../widgets/foundation/empty_state.dart';
import '../widgets/foundation/glass_cluster.dart';
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/label_chip.dart';
import '../widgets/foundation/mixtape_feedback.dart';
import '../widgets/mix_handoff.dart';
import '../widgets/spotify_handoff_sheets.dart';
import '../widgets/tape_header.dart';
import '../widgets/tape_palette.dart';
import '../widgets/track_row.dart';
import 'chat_screen.dart';

/// "From Ada", or "From a friend" when the sender cleared their name.
String sharedMixByline(String? sharerName) {
  final name = sharerName?.trim();
  return 'From ${name == null || name.isEmpty ? 'a friend' : name}';
}

/// "10 songs · 41 min": the tape's count line without a version, which is
/// the sender's and means nothing here.
String sharedMixMetaLine(List<QueueTrack> queue) => [
  '${queue.length} song${queue.length == 1 ? '' : 's'}',
  ?tapeDurationLabel(queue),
].join(' · ');

/// The share's songs as the rows and actions read them. Ids are made up and
/// stable (`<token>:<index>`); nothing here ever goes back to the server.
List<QueueTrack> sharedMixQueue(SharedMix mix) => [
  for (var i = 0; i < mix.tracks.length; i++)
    QueueTrack(
      position: i,
      trackId: '${mix.token}:$i',
      appleId: mix.tracks[i].appleId,
      title: mix.tracks[i].title,
      artist: mix.tracks[i].artist,
      durationMs: mix.tracks[i].durationMs,
      artworkUrl: mix.tracks[i].artwork?.url,
      artworkWidth: mix.tracks[i].artwork?.width,
      artworkHeight: mix.tracks[i].artwork?.height,
      artworkBgColor: mix.tracks[i].artwork?.bgColor,
    ),
];

class SharedMixScreen extends ConsumerStatefulWidget {
  const SharedMixScreen({
    super.key,
    required this.token,
    this.fromMixes = false,
  });

  final String token;

  /// Opened from a "From Ada" row: the listener has it saved already, so
  /// nothing is saved again, and a stopped share offers Remove.
  final bool fromMixes;

  static const Key backKey = Key('shared-back');
  static const Key loadingKey = Key('shared-loading');
  static const Key goneKey = Key('shared-gone');
  static const Key removeKey = Key('shared-remove');
  static const Key retryKey = Key('shared-retry');
  static const Key navTitleKey = Key('shared-nav-title');

  static const String goneMessage = SharedMixGoneException.message;
  static const String removeLabel = 'Remove';
  static const String removeFailedMessage =
      "Couldn't remove this mix. Try again.";

  /// R7: the faded default cassette.
  static const double goneCassetteWidth = 120;

  @override
  ConsumerState<SharedMixScreen> createState() => _SharedMixScreenState();
}

enum _Phase { loading, loaded, gone, failed }

class _SharedMixScreenState extends ConsumerState<SharedMixScreen>
    with MixHandoff<SharedMixScreen> {
  _Phase _phase = _Phase.loading;
  SharedMix? _mix;
  List<QueueTrack> _queue = const [];
  bool _saveRequested = false;
  bool _removing = false;
  int _load = 0;

  final _scroll = ScrollController();
  final _headerKey = GlobalKey();
  bool _titleShown = false;

  @override
  String get mixSessionId => '$sharedPlaybackPrefix${widget.token}';

  @override
  bool get mixRecordsEvidence => false;

  /// The header's colour, the default included, so Now Playing matches it.
  @override
  String? get mixCaseColor => tapeHex(_caseColor(_mix?.caseColor));

  static Color _caseColor(String? hex) =>
      tapeColor(hex) ?? CassetteTile.caseColors.first;

  @override
  void showMixSnack(String message, {FeedbackKind kind = FeedbackKind.info}) =>
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(mixtapeSnackBar(message: message, kind: kind));

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_syncTitle);
    unawaited(_fetch());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _syncTitle() {
    final header = _headerKey.currentContext?.findRenderObject();
    final height = header is RenderBox && header.hasSize
        ? header.size.height
        : 0.0;
    final shown = height > 0 && _scroll.hasClients
        ? _scroll.offset >= height - 24
        : false;
    if (shown != _titleShown) setState(() => _titleShown = shown);
  }

  Future<void> _fetch() async {
    final load = ++_load;
    if (_phase != _Phase.loading) setState(() => _phase = _Phase.loading);
    final api = ref.read(djApiProvider);
    try {
      final mix = await api.getSharedMix(widget.token);
      if (!mounted || load != _load) return;
      final sessionId = mix.sessionId;
      if (mix.isOwner && sessionId != null) {
        // The sender's own link: their conversation, where Share lives.
        unawaited(
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(
              builder: (_) => ChatScreen(sessionId: sessionId),
            ),
          ),
        );
        return;
      }
      setState(() {
        _mix = mix;
        _queue = sharedMixQueue(mix);
        _phase = _Phase.loaded;
      });
      _saveOnce();
    } on SharedMixGoneException {
      if (!mounted || load != _load) return;
      setState(() => _phase = _Phase.gone);
    } catch (_) {
      if (!mounted || load != _load) return;
      setState(() => _phase = _Phase.failed);
    }
  }

  /// Once per screen, and not for a mix opened from Mixes (already saved).
  void _saveOnce() {
    if (_saveRequested || widget.fromMixes) return;
    _saveRequested = true;
    unawaited(ref.read(pendingShareSaveProvider.notifier).hold(widget.token));
  }

  /// R3: with no platform chosen the Apple pair shows; the first tap asks
  /// where the listener listens. Apple Music goes on with the tap; Spotify
  /// swaps the bar to its own action.
  Future<void> _onApple(VoidCallback action) async {
    final platform = ref.read(musicPlatformProvider.notifier);
    await platform.ready;
    if (!mounted) return;
    if (ref.read(musicPlatformProvider) != null) return action();
    final answer = await askWhereYouListen(context);
    if (!mounted || answer == null) return;
    await platform.choose(answer);
    if (!mounted || answer != MusicPlatform.apple) return;
    action();
  }

  Future<void> _openInSpotify(QueueTrack track) async {
    var opened = false;
    try {
      opened = await ref.read(linkOpenerProvider)(mixSpotifySearch(track));
    } catch (_) {
      opened = false;
    }
    if (!mounted) return;
    if (!opened) {
      showMixSnack("couldn't open Spotify", kind: FeedbackKind.error);
      return;
    }
    noteSpotifyOutput();
  }

  Future<void> _remove() async {
    if (_removing) return;
    setState(() => _removing = true);
    try {
      await ref.read(djApiProvider).removeSharedMix(widget.token);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      showMixSnack(
        SharedMixScreen.removeFailedMessage,
        kind: FeedbackKind.error,
      );
    } finally {
      if (mounted) setState(() => _removing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Kept listened while the screen is open, so a session that appears
    // meanwhile saves the share (the app's root keeps it beyond that).
    ref.listen(pendingShareSaveProvider, (_, _) {});
    // Read non-blocking by Create playlist's author prefill; signed out
    // there is no account to ask.
    if (ref.watch(authProvider) == AuthStatus.session) {
      ref.watch(accountNameProvider);
    }

    return switch (_phase) {
      _Phase.loading => _shell(
        title: '',
        bottomBar: _bar(const [], enabled: false),
        body: const _Loading(key: SharedMixScreen.loadingKey),
      ),
      _Phase.failed => _shell(
        title: '',
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: LoadErrorState(
              title: "Couldn't load this mix",
              body: 'Check your connection and try again.',
              retryKey: SharedMixScreen.retryKey,
              onRetry: () => unawaited(_fetch()),
            ),
          ),
        ),
      ),
      _Phase.gone => _shell(
        title: '',
        body: _Gone(
          onRemove: widget.fromMixes
              ? (_removing ? null : () => unawaited(_remove()))
              : null,
        ),
      ),
      _Phase.loaded => _loaded(_mix!),
    };
  }

  Widget _loaded(SharedMix mix) {
    final spotify = ref.watch(musicPlatformProvider) == MusicPlatform.spotify;
    return _shell(
      title: mix.title,
      showTitle: _titleShown,
      bottomBar: _queue.isEmpty ? null : _bar(_queue, title: mix.title),
      body: CustomScrollView(
        controller: _scroll,
        slivers: [
          SliverToBoxAdapter(
            child: KeyedSubtree(
              key: _headerKey,
              child: TapeHeader(
                caseColor: _caseColor(mix.caseColor),
                title: mix.title,
                byline: sharedMixByline(mix.sharerName),
                meta: sharedMixMetaLine(_queue),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(
              MixtapeMetrics.screenSidePadding,
              0,
              MixtapeMetrics.screenSidePadding,
              24,
            ),
            sliver: SliverList.builder(
              itemCount: _queue.length,
              itemBuilder: (context, index) {
                final track = _queue[index];
                return TrackRow(
                  key: TrackRow.rowKey(track.trackId),
                  number: index + 1,
                  track: track,
                  expanded: false,
                  isFirst: index == 0,
                  showGrip: false,
                  onOpenInSpotify: spotify
                      ? () => unawaited(_openInSpotify(track))
                      : null,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// `.sticky`: the listener's own mix actions, as on their mixes.
  Widget _bar(
    List<QueueTrack> queue, {
    String title = '',
    bool enabled = true,
  }) {
    const keys = MixHandoffKeys.shared;
    return TapeBar(
      reason: MixPlayReason(keys: keys, queue: queue),
      primary: MixActions(
        keys: keys,
        queue: queue,
        enabled: enabled,
        spacing: 10,
        isPlayingThisMix: isPlayingThisMix,
        onPlay: () => unawaited(
          _onApple(
            () => unawaited(playMix(queue: queue, version: 0, title: title)),
          ),
        ),
        onOpenNowPlaying: openNowPlaying,
        onCreatePlaylist: () => unawaited(
          _onApple(
            () => unawaited(
              createPlaylist(queue: queue, defaultName: title, keys: keys),
            ),
          ),
        ),
        onCreateSpotifyPlaylist: () => unawaited(createSpotifyPlaylist(queue)),
        creatingPlaylist: savingPlaylist,
        sharing: sharingMix,
        sendingToMusic: sendingToMusic,
      ),
    );
  }

  /// The tape screen's chrome: the glow, Back alone in the header, floating
  /// toasts above the bar.
  Widget _shell({
    required String title,
    required Widget body,
    bool showTitle = false,
    Widget? bottomBar,
  }) {
    final theme = Theme.of(context);
    return GradientBackground(
      child: Theme(
        data: theme.copyWith(
          snackBarTheme: theme.snackBarTheme.copyWith(
            behavior: SnackBarBehavior.floating,
            insetPadding: const EdgeInsets.all(16),
          ),
        ),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          bottomNavigationBar: bottomBar,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SafeArea(
                bottom: false,
                child: _TopBar(
                  title: title,
                  titleShown: showTitle,
                  onBack: () => Navigator.of(context).maybePop(),
                ),
              ),
              Expanded(
                child: SafeArea(
                  top: false,
                  bottom: bottomBar == null,
                  child: body,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Back on the left, nothing on the right (no ⋯: it would hold one item);
/// the small title fades in once the cassette has scrolled away.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.titleShown,
    required this.onBack,
  });

  final String title;
  final bool titleShown;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Row(
        children: [
          GlassCluster(
            children: [
              GlassButton(
                key: SharedMixScreen.backKey,
                icon: Icons.arrow_back_ios_new,
                label: 'Back',
                onPressed: onBack,
              ),
            ],
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: AnimatedOpacity(
                key: SharedMixScreen.navTitleKey,
                opacity: titleShown ? 1 : 0,
                duration: reduced
                    ? Duration.zero
                    : const Duration(milliseconds: 180),
                child: ExcludeSemantics(
                  excluding: !titleShown,
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.tokens.smallTitle,
                  ),
                ),
              ),
            ),
          ),
          // Balances Back so the title stays centred.
          const SizedBox(width: MixtapeMetrics.minTarget),
        ],
      ),
    );
  }
}

/// R4: the default cassette with its hubs turning, skeleton text and rows.
class _Loading extends StatelessWidget {
  const _Loading({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final bone = tokens.muted.withValues(alpha: 0.18);
    Widget bar(double widthFactor, double height) => FractionallySizedBox(
      widthFactor: widthFactor,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: bone,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
    return Semantics(
      label: 'Loading mix',
      liveRegion: true,
      child: ExcludeSemantics(
        child: ListView(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(
            horizontal: MixtapeMetrics.screenSidePadding,
          ),
          children: [
            const SizedBox(height: 4),
            Center(
              child: Transform.rotate(
                angle: TapeHeader.tilt,
                child: const CassetteTile(
                  width: TapeHeader.defaultCassetteWidth,
                  spinning: true,
                  shadow: true,
                ),
              ),
            ),
            const SizedBox(height: 20),
            Center(child: bar(0.62, 22)),
            const SizedBox(height: 8),
            Center(child: bar(0.22, 12)),
            const SizedBox(height: 6),
            Center(child: bar(0.34, 12)),
            const SizedBox(height: 22),
            for (var i = 0; i < 5; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    const SizedBox(width: TrackRow.numberWidth),
                    const SizedBox(width: TrackRow.gap),
                    Container(
                      width: TrackRow.artSize,
                      height: TrackRow.artSize,
                      decoration: BoxDecoration(
                        color: bone,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: TrackRow.gap),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          bar(0.7, 12),
                          const SizedBox(height: 6),
                          bar(0.4, 10),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// R7: the faded default cassette, the contract line and, only when the
/// listener has it saved, Remove.
class _Gone extends StatelessWidget {
  const _Gone({required this.onRemove});

  /// Null: no save to remove, so Back is the only way on.
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Center(
      key: SharedMixScreen.goneKey,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(40, 0, 40, 120),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Transform.rotate(
              angle: TapeHeader.tilt,
              child: const Opacity(
                opacity: 0.4,
                child: CassetteTile(width: SharedMixScreen.goneCassetteWidth),
              ),
            ),
            const SizedBox(height: 24),
            Semantics(
              liveRegion: true,
              child: Text(
                SharedMixScreen.goneMessage,
                textAlign: TextAlign.center,
                style: tokens.section.copyWith(color: tokens.text),
              ),
            ),
            if (onRemove != null) ...[
              const SizedBox(height: 18),
              LabelChip(
                key: SharedMixScreen.removeKey,
                label: SharedMixScreen.removeLabel,
                onPressed: onRemove,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
