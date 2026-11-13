/// The arrangement: the ordered mix behind one conversation
/// (`docs/mockups/approved/2026-09-17-mobile-arrangement-states.md`, frames
/// R1–R3 / P1–P3 / E1–E4 in
/// `docs/mockups/2026-09-17-mobile-arrangement-states.html`).
///
/// Reorder, remove (with Undo), read the DJ's reasons, then play it here,
/// send it to Music, or turn it into a playlist. Server-canonical, like every
/// other queue mutation in this app: reorder/remove/insert post an op and
/// re-render from the response rather than editing local state optimistically.
///
/// Spotify (plan `2026-09-02-listening-export-p2-spotify-import.md`,
/// Outputs): a row with a Spotify id trades its grip for "Open in Spotify";
/// a corpus-mode session carries the "Not personal yet" block above the
/// list. A Spotify device ([MusicPlatform.spotify],
/// `docs/mockups/approved/2026-11-09-one-platform-play.md`) gets the one
/// Spotify Create playlist on the bar and an Open on every row (a search
/// when there is no id).
///
/// Every mutation goes through one FIFO of [_QueueIntent]s rather than
/// firing straight at the provider — see [_QueueScreenState._enqueue] for
/// the invariants that buys (one op in flight at a time, positions resolved
/// against the queue as it stands when the op is posted, and rows un-hidden
/// when their own op settles rather than on a version change).
library;

import 'package:mixtape/presentation/widgets/foundation/mixtape_feedback.dart';
import 'dart:async';

import 'package:flutter/cupertino.dart'
    show
        CupertinoAlertDialog,
        CupertinoDialogAction,
        CupertinoTextField,
        showCupertinoDialog;
import 'package:flutter/material.dart';
import '../widgets/foundation/alert_field_box.dart';
import '../widgets/open_tape_settings.dart';
import '../widgets/mix_share.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dj/dj_models.dart';
import '../providers/dj_providers.dart';
import '../providers/library_sync_provider.dart';
import '../providers/mix_operation_gate.dart';
import '../providers/music_platform_provider.dart';
import '../providers/onboarding_provider.dart';
import '../theme/mixtape_theme.dart';
import '../widgets/foundation/empty_state.dart';
import '../widgets/foundation/cassette_tile.dart';
import '../widgets/foundation/glass_cluster.dart';
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/remove_band.dart';
import '../widgets/mix_handoff.dart';
import '../widgets/mix_tape_colour.dart';
import '../widgets/music_door.dart';
import '../widgets/tape_header.dart';
import '../widgets/track_row.dart';
import 'chat_screen.dart' show remakeInConversation;
import 'mix_history_screen.dart';
import '../widgets/foundation/mixtape_menu.dart';

/// The conflict copy from the approved board. The provider's own
/// [staleQueueTransientMessage] is shared with the conversation screen, so it
/// is translated here rather than changed underneath that screen.
const arrangementConflictMessage =
    'This mix changed elsewhere. Showing the latest version.';

/// The arrangement screen, pushed inside a tab [Navigator] (the shell hides
/// the dock for it), so it draws its own chrome and never assumes it is the
/// root route.
class QueueScreen extends ConsumerStatefulWidget {
  const QueueScreen({super.key, required this.sessionId});

  final String sessionId;

  /// The empty state's illustration size, as on Mixes.
  static const double emptyCassetteWidth = 140;

  /// How long Undo stays on screen after a removal.
  static const Duration undoDuration = Duration(seconds: 5);

  @override
  ConsumerState<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends ConsumerState<QueueScreen>
    with MixHandoff<QueueScreen> {
  final Set<String> _expandedTrackIds = {};

  /// Rows filtered out of the render even though the server still has them.
  /// [Dismissible] requires a swiped item to be gone from the underlying
  /// list by the very next build or it asserts ("A dismissed Dismissible
  /// widget is still part of the tree") — but this screen is
  /// server-canonical (no optimistic data edits), so the REAL removal only
  /// lands once the queue-ops response comes back.
  ///
  /// Entries are per-track and SETTLE-BASED: one is added when a gesture
  /// enqueues an intent and removed in that intent's `finally`, whatever
  /// the outcome. Never cleared wholesale on a version change — a version
  /// bump from an unrelated source (a concurrent DJ turn) would otherwise
  /// resurrect a just-dismissed row in the same frame it was dismissed,
  /// tripping exactly the assertion above; and a non-stale applyOps failure
  /// leaves the version UNCHANGED, so version-triggered clearing would
  /// strand the row invisible forever while it still exists server-side.
  final Set<String> _hiddenTrackIds = {};

  /// Serialized queue mutations, oldest first. See [_enqueue] for why they
  /// run strictly one at a time and why they're expressed as intents
  /// (track ids) rather than as ready-made positional ops.
  final List<_QueueIntent> _intents = [];
  bool _draining = false;

  /// The tape screen scrolls as one; once the cassette header has scrolled
  /// away, the small title fades into the navigation bar.
  final _scroll = ScrollController();
  final _headerKey = GlobalKey();
  bool _titleShown = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_syncTitle);
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

  @override
  String get mixSessionId => widget.sessionId;

  @override
  void showMixSnack(String message, {FeedbackKind kind = FeedbackKind.info}) =>
      _showSnack(context, message, kind: kind);

  void _toggleReason(String trackId) {
    setState(() {
      if (!_expandedTrackIds.add(trackId)) _expandedTrackIds.remove(trackId);
    });
  }

  /// Queue mutation invariants, all of which fall out of running intents
  /// through a single FIFO:
  ///
  /// * **One in flight at a time.** A second gesture never posts against a
  ///   version the first gesture is about to bump, so rapid swipes can't
  ///   409 and be silently discarded — the later intent simply waits and
  ///   uses the fresh version.
  /// * **Positions resolve at EXECUTION time, from the provider's current
  ///   queue** — never from the visible list at gesture time, which omits
  ///   hidden rows and would therefore point a 0-based server position at
  ///   the wrong track. If the intent's track is gone by then (a DJ turn
  ///   removed it, say), the intent is skipped rather than mis-targeted.
  /// * **Hiding is settle-based.** The gesture hides its row immediately
  ///   (Dismissible's hard requirement) and the intent un-hides that
  ///   specific id when it settles, so a failed removal reappears.
  void _enqueue(_QueueIntent intent) {
    _intents.add(intent);
    if (!_draining) _drain();
  }

  Future<void> _drain() async {
    _draining = true;
    try {
      while (_intents.isNotEmpty && mounted) {
        // Unforeseen-exception guard, same shape as ChatScreen's `_send`:
        // [ChatNotifier.applyOps] resolves every error it knows about into
        // a transientError and never rethrows, so this catch exists purely
        // so an entirely unanticipated one can't become an unhandled async
        // error that also strands every intent still queued behind it.
        try {
          await _run(_intents.removeAt(0));
        } catch (_) {
          if (mounted) {
            _showSnack(
              context,
              'something unexpected happened',
              kind: FeedbackKind.error,
            );
          }
        }
      }
    } finally {
      _draining = false;
    }
  }

  Future<void> _run(_QueueIntent intent) async {
    try {
      final queue = ref.read(chatProvider(widget.sessionId)).value?.queue;
      if (queue == null) return;
      final op = intent.resolve(queue);
      if (op == null) return; // the intent no longer means anything — drop it
      await ref.read(chatProvider(widget.sessionId).notifier).applyOps([op]);
    } finally {
      // Runs on success, failure, and the skipped-intent paths above: the
      // row this intent owned is either genuinely gone from the queue now
      // (so un-hiding is a harmless no-op) or was never removed, in which
      // case it has to come back rather than stay stuck invisible.
      if (mounted) {
        setState(() => _hiddenTrackIds.remove(intent.trackId));
      }
    }
  }

  /// A full swipe removes at once and the toast offers Undo, which re-adds
  /// the song where it was through the same versioned op — but only when the
  /// server understands `insert` ([ChatState.supportsInsert]); against an
  /// older deploy the toast simply names the song.
  void _handleDismiss(QueueTrack track, {required bool supportsInsert}) {
    final canonical =
        ref.read(chatProvider(widget.sessionId)).value?.queue ??
        const <QueueTrack>[];
    final oldPosition = canonical.indexWhere((t) => t.trackId == track.trackId);
    // An ANCHOR, not a number: the song that followed this one (null when it
    // was last). An earlier removal still in flight would shift a bare
    // position, so [_InsertIntent] resolves this against the queue as it
    // stands when the Undo is actually posted, exactly as a move does.
    final followerId = (oldPosition >= 0 && oldPosition + 1 < canonical.length)
        ? canonical[oldPosition + 1].trackId
        : null;
    setState(() => _hiddenTrackIds.add(track.trackId));
    _enqueue(_RemoveIntent(track.trackId));

    final canUndo = supportsInsert && oldPosition >= 0;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        mixtapeSnackBar(
          message: 'Removed "${track.title}"',
          kind: FeedbackKind.info,
          duration: QueueScreen.undoDuration,
          actionLabel: canUndo ? 'Undo' : null,
          onAction: canUndo
              ? () => _enqueue(
                  _InsertIntent(track.trackId, beforeTrackId: followerId),
                )
              : null,
        ),
      );
  }

  /// [newIndex] arrives in [ReorderableListView]'s own pre-removal indexing:
  /// moving an item DOWN reports an index one past where it actually lands
  /// once the dragged item is taken out of the list, so it's decremented by
  /// one in that case.
  void _handleReorder(List<QueueTrack> visible, int oldIndex, int newIndex) {
    var adjusted = newIndex;
    if (adjusted > oldIndex) adjusted -= 1;
    _moveTo(visible, oldIndex, adjusted);
  }

  /// The move is expressed as an ANCHOR (the id of the row the dragged one
  /// should land in front of, or null for "at the end") rather than a bare
  /// index, because [visible] is the on-screen list — which omits any row
  /// hidden by an intent that hasn't settled yet — while the op needs a
  /// position in the server's full queue. [_MoveIntent] re-derives that
  /// position from the current queue when it runs.
  void _moveTo(List<QueueTrack> visible, int oldIndex, int newIndex) {
    if (newIndex == oldIndex) return;
    final rest = [
      for (var i = 0; i < visible.length; i++)
        if (i != oldIndex) visible[i].trackId,
    ];
    _enqueue(
      _MoveIntent(
        visible[oldIndex].trackId,
        beforeTrackId: newIndex < rest.length ? rest[newIndex] : null,
      ),
    );
  }

  /// `spotify:track:<id>` when the Spotify app answers the probe (the scheme
  /// is declared under LSApplicationQueriesSchemes in Info.plist, or iOS
  /// says no regardless), else the https link, which Safari or the App Store
  /// banner handles. A probe that throws counts as "cannot".
  Future<void> _openInSpotify(
    BuildContext screenContext,
    QueueTrack track,
  ) async {
    final id = track.spotifyId;
    // No id: the https search, which the Spotify app claims as a universal
    // link when it is installed.
    final app = id == null ? null : Uri.parse('spotify:track:$id');
    var canOpenApp = false;
    if (app != null) {
      try {
        canOpenApp = await ref.read(linkProbeProvider)(app);
      } catch (_) {
        canOpenApp = false;
      }
    }
    if (!mounted) return;
    final target = canOpenApp
        ? app!
        : id == null
        ? mixSpotifySearch(track)
        : Uri.https('open.spotify.com', '/track/$id');
    var opened = false;
    try {
      opened = await ref.read(linkOpenerProvider)(target);
    } catch (_) {
      opened = false;
    }
    if (!mounted) return;
    if (!opened) {
      if (screenContext.mounted) {
        _showSnack(
          screenContext,
          "couldn't open Spotify",
          kind: FeedbackKind.error,
        );
      }
      return;
    }
    noteSpotifyOutput();
  }

  void _showSnack(
    BuildContext context,
    String message, {
    FeedbackKind kind = FeedbackKind.info,
  }) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(mixtapeSnackBar(message: message, kind: kind));
  }

  void _openHistory() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            MixHistoryScreen(sessionId: widget.sessionId, fromTape: true),
      ),
    );
  }

  /// The More menu, the same as the conversation's: Share and Stop sharing
  /// ([MixShare]), Version history, Tape settings, Rename, then Archive or
  /// Restore behind a separator.
  Future<void> _openMore(BuildContext anchor) async {
    final chat = ref.read(chatProvider(widget.sessionId)).value;
    final archived = chat?.session.status == 'archived';
    final sharing = MixShare.menuActions(chat);
    final origin = MixShare.originOf(anchor);
    final action = await showMixtapeMenu<String>(
      anchor,
      actions: [
        ...sharing,
        MixtapeMenuAction(
          value: 'history',
          label: 'Version history',
          icon: MixMenuIcons.history,
          separatorBefore: sharing.isNotEmpty,
        ),
        const MixtapeMenuAction(
          value: 'tape-settings',
          label: 'Tape settings',
          icon: MixMenuIcons.tape,
        ),
        const MixtapeMenuAction(
          value: 'rename',
          label: 'Rename',
          icon: MixMenuIcons.rename,
        ),
        MixtapeMenuAction(
          value: 'status',
          label: archived ? 'Restore' : 'Archive',
          isDestructive: !archived,
          separatorBefore: true,
          icon: MixMenuIcons.archive,
        ),
      ],
    );
    if (!mounted || action == null) return;
    final shared = await MixShare.handle(
      context,
      ref,
      widget.sessionId,
      action,
      origin: origin,
      onError: (message) =>
          _showSnack(context, message, kind: FeedbackKind.error),
    );
    if (shared || !mounted) return;
    if (action == 'history') return _openHistory();
    if (action == 'rename') return _openRenameDialog();
    if (action == 'tape-settings') {
      return openTapeSettings(context, ref, widget.sessionId);
    }
    final notifier = ref.read(chatProvider(widget.sessionId).notifier);
    final ok = await notifier.setArchived(!archived);
    if (!mounted) return;
    _showSnack(
      context,
      ok
          ? (archived ? 'Mix restored' : 'Mix archived')
          : "Couldn't update this mix. Try again.",
      kind: ok ? FeedbackKind.success : FeedbackKind.error,
    );
  }

  Future<void> _openRenameDialog() async {
    final current =
        ref.read(chatProvider(widget.sessionId)).value?.session.title ?? '';
    final controller = TextEditingController(text: current);
    final name = await showCupertinoDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text('Rename mix'),
        content: Padding(
          padding: const EdgeInsets.only(top: 14),
          child: AlertFieldBox(
            child: CupertinoTextField(
              key: const Key('rename-field'),
              controller: controller,
              autofocus: true,
              placeholder: 'Mix name',
            ),
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            key: const Key('rename-confirm-button'),
            isDefaultAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || name == null || name.trim().isEmpty) return;
    await ref.read(chatProvider(widget.sessionId).notifier).rename(name);
  }

  @override
  Widget build(BuildContext context) {
    final chatAsync = ref.watch(chatProvider(widget.sessionId));
    final operation = ref.watch(mixOperationProvider(widget.sessionId));
    // Kick off the /me fetch as soon as the screen opens so the account
    // name is (usually) resolved by the time the save dialog reads it
    // non-blocking — see _openSaveDialog.
    ref.watch(accountNameProvider);
    // Same reason, for the same reader: [FunnelMilestones] reads the
    // onboarding state synchronously (it never awaits a user-scoped
    // provider), so an output action can only post its milestone if the
    // read has landed. The service gate has normally loaded it long before
    // this screen opens; watching keeps it loaded and current here too.
    ref.watch(onboardingProvider);

    ref.listen(chatProvider(widget.sessionId), (previous, next) {
      final state = next.value;
      if (state == null) return;

      // Drop expansion state for tracks that have left the queue, so a
      // trackId can't accumulate here forever (and can't silently
      // re-expand if the DJ ever re-adds the same track later). Mutated
      // without setState deliberately: the very provider change that
      // triggered this listener also rebuilds this widget via ref.watch,
      // and setState from a listener can land mid-build.
      final liveIds = {for (final t in state.queue) t.trackId};
      _expandedTrackIds.removeWhere((id) => !liveIds.contains(id));

      // ChatScreen keeps its own transientError listener and is still
      // mounted underneath this route, so both would fire for one error and
      // queue two identical snackbars. Only the route actually on top shows
      // it, but it is ALWAYS cleared — leaving it in state (e.g. while this
      // screen's save dialog covers both routes) would let copyWith carry
      // it forward until some later, unrelated event surfaces it out of
      // context. Both listeners fire with the same captured `state`, so the
      // non-top screen clearing first can't stop the top one from showing.
      if (state.transientError != null) {
        if (ModalRoute.of(context)?.isCurrent == true) {
          // A version conflict says so in the arrangement's own words.
          final message = state.transientError == staleQueueTransientMessage
              ? arrangementConflictMessage
              : state.transientError!;
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              mixtapeSnackBar(message: message, kind: FeedbackKind.error),
            );
        }
        ref.read(chatProvider(widget.sessionId).notifier).clearTransientError();
      }
    });

    // Same defensive ordering as ChatScreen: hasError checked before
    // isLoading/hasValue so a Riverpod retry-in-progress doesn't sit on a
    // bare spinner, and hasValue checked so a live list mid-background-
    // refresh-failure never blanks out to the full-screen error.
    if (chatAsync.hasError && !chatAsync.hasValue) {
      return _shell(
        title: '',
        body: _ErrorState(
          onRetry: () => ref.invalidate(chatProvider(widget.sessionId)),
        ),
      );
    }

    if (!chatAsync.hasValue) {
      return _shell(
        title: '',
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final state = chatAsync.value!;

    // [visibleQueue] — not state.queue — drives EVERY surface on this
    // screen: the list, the empty state, whether Play/Create are actionable,
    // and the ids handed to Apple Music. A row the user has just swiped
    // away shouldn't play or be saved into a playlist just because its
    // removal hasn't round-tripped yet.
    final visibleQueue = state.queue
        .where((t) => !_hiddenTrackIds.contains(t.trackId))
        .toList();

    final reducedMotion = MediaQuery.disableAnimationsOf(context);

    final caseColour = watchMixTapeColour(
      ref,
      widget.sessionId,
      saved: state.session.caseColor,
    );

    return _shell(
      title: state.session.title,
      hasContent: true,
      bottomBar: visibleQueue.isEmpty
          ? null
          : _stickyBar(state, visibleQueue),
      // One scroll view: the cassette header scrolls away with the songs,
      // and at 200% text nothing is pinned that could crowd the list out.
      body: CustomScrollView(
        controller: _scroll,
        slivers: [
          if (visibleQueue.isNotEmpty)
            SliverToBoxAdapter(
              child: KeyedSubtree(
                key: _headerKey,
                child: TapeHeader(
                  caseColor: caseColour,
                  title: state.session.title,
                  meta: tapeMetaLine(
                    visibleQueue.length,
                    tapeDurationLabel(visibleQueue),
                    state.queueVersion,
                  ),
                ),
              ),
            ),
          if (state.session.notPersonal)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: MixtapeMetrics.screenSidePadding,
                ),
                // Remake runs in the conversation, where the listener sees
                // it happen; it waits while this mix has a turn out.
                child: _NotPersonalBlock(
                  onRemake: state.sending || operation != null
                      ? null
                      : () => remakeInConversation(context, widget.sessionId),
                ),
              ),
            ),
          if (visibleQueue.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyState(),
            )
          else ...[
            SliverPadding(
              padding: const EdgeInsets.symmetric(
                horizontal: MixtapeMetrics.screenSidePadding,
              ),
              sliver: SliverReorderableList(
                itemCount: visibleQueue.length,
                onReorder: (oldIndex, newIndex) =>
                    _handleReorder(visibleQueue, oldIndex, newIndex),
                // The board's lifted row, rebuilt rather than wrapped so the
                // raised treatment belongs to the row itself. Reduced motion
                // drops the spring: the row simply appears lifted.
                proxyDecorator: (child, index, animation) =>
                    // The list can ask for a proxy one frame after a removal
                    // shortened the queue; the child it hands back is still
                    // the right thing to draw.
                    index >= visibleQueue.length
                    ? child
                    : _row(
                        state,
                        visibleQueue,
                        index,
                        lifted: true,
                        reducedMotion: reducedMotion,
                      ),
                itemBuilder: (context, index) => _row(
                  state,
                  visibleQueue,
                  index,
                  reducedMotion: reducedMotion,
                ),
              ),
            ),
            // `.hint`: under the last song, not beside the counts.
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                child: Text(
                  tapeHint,
                  key: const Key('arrangement-hint'),
                  textAlign: TextAlign.center,
                  style: context.tokens.meta.copyWith(
                    color: context.tokens.muted,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Chrome shared by every state: the gradient, the glass header buttons,
  /// the floating SnackBars (no dock on this route, so they sit 16 pt in)
  /// and, once there are songs, the bar that stays at the bottom.
  Widget _shell({
    required String title,
    required Widget body,
    bool hasContent = false,
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
          // As the bottom bar, so floating toasts land above it rather than
          // over Play.
          bottomNavigationBar: bottomBar,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SafeArea(
                bottom: false,
                child: _TopBar(
                  title: title,
                  // No cassette header (loading, empty, failed): the bar carries it.
                  titleShown: _titleShown || bottomBar == null,
                  onBack: () => Navigator.of(context).maybePop(),
                  onMore: hasContent ? _openMore : null,
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

  /// `.sticky`: the mix actions, which stay put while the songs scroll —
  /// the same ones the conversation's strip carries. Any reason Play cannot
  /// work sits above the bar.
  Widget _stickyBar(ChatState state, List<QueueTrack> visibleQueue) {
    const keys = MixHandoffKeys.arrangement;
    return TapeBar(
      reason: MixPlayReason(keys: keys, queue: visibleQueue),
      primary: MixActions(
        keys: keys,
        queue: visibleQueue,
        spacing: 10,
        isPlayingThisMix: isPlayingThisMix,
        onPlay: () => unawaited(playHere(state, visibleQueue)),
        onOpenNowPlaying: openNowPlaying,
        onCreatePlaylist: () => unawaited(
          createPlaylist(
            queue: visibleQueue,
            defaultName: state.session.title,
            keys: keys,
          ),
        ),
        onCreateSpotifyPlaylist: () =>
            unawaited(createSpotifyPlaylist(visibleQueue)),
        creatingPlaylist: savingPlaylist,
        sharing: sharingMix,
        sendingToMusic: sendingToMusic,
      ),
    );
  }

  Widget _row(
    ChatState state,
    List<QueueTrack> visibleQueue,
    int index, {
    bool lifted = false,
    required bool reducedMotion,
  }) {
    final track = visibleQueue[index];
    // Every row opens in Spotify on a Spotify device: the exact track when
    // we hold its id, a search for it otherwise.
    final opensInSpotify =
        track.spotifyId != null ||
        ref.watch(musicPlatformProvider) == MusicPlatform.spotify;
    final row = TrackRow(
      number: index + 1,
      track: track,
      expanded: _expandedTrackIds.contains(track.trackId),
      onTap: () => _toggleReason(track.trackId),
      isFirst: index == 0,
      lifted: lifted,
      dragIndex: (lifted || opensInSpotify) ? null : index,
      onOpenInSpotify: opensInSpotify
          ? () => _openInSpotify(context, track)
          : null,
      onMoveUp: index == 0
          ? null
          : () => _moveTo(visibleQueue, index, index - 1),
      onMoveDown: index == visibleQueue.length - 1
          ? null
          : () => _moveTo(visibleQueue, index, index + 1),
    );
    if (lifted) {
      return KeyedSubtree(key: ValueKey('lifted-${track.trackId}'), child: row);
    }
    return Dismissible(
      key: ValueKey('dismissible-${track.trackId}'),
      direction: DismissDirection.endToStart,
      movementDuration: reducedMotion
          ? Duration.zero
          : const Duration(milliseconds: 200),
      background: const RemoveBand(),
      onDismissed: (_) =>
          _handleDismiss(track, supportsInsert: state.supportsInsert),
      child: row,
    );
  }
}

/// One queued queue-mutation, held in terms of TRACK IDS rather than
/// positions. The gesture that creates it knows what the user meant ("drop
/// this track", "put this track in front of that one"); the 0-based server
/// position that expresses it is only correct against the queue as it
/// stands when the op is actually posted, which is what [resolve] computes.
sealed class _QueueIntent {
  const _QueueIntent(this.trackId);

  /// The track this intent acts on — and the id un-hidden once it settles.
  final String trackId;

  /// The op to post against [queue] (the provider's current, canonical
  /// queue, in server order), or null if the intent no longer means
  /// anything and should be skipped.
  QueueOp? resolve(List<QueueTrack> queue);
}

class _RemoveIntent extends _QueueIntent {
  const _RemoveIntent(super.trackId);

  @override
  QueueOp? resolve(List<QueueTrack> queue) {
    final from = queue.indexWhere((t) => t.trackId == trackId);
    // Already gone (a DJ turn dropped it first) — removing "its" position
    // now would delete whichever track has since moved into that slot.
    return from < 0 ? null : QueueOp.remove(from);
  }
}

/// Undo: put the removed track back in front of whatever followed it. The
/// intent is dropped if the track is somehow back already — inserting a
/// duplicate is a 400, not a no-op — and an anchor that has itself since
/// left the queue lands the song at the end rather than losing the Undo.
class _InsertIntent extends _QueueIntent {
  const _InsertIntent(super.trackId, {required this.beforeTrackId});

  /// The track the restored one should land in front of; null means "at the
  /// end of the queue".
  final String? beforeTrackId;

  @override
  QueueOp? resolve(List<QueueTrack> queue) {
    if (queue.any((t) => t.trackId == trackId)) return null;
    final anchor = beforeTrackId == null
        ? -1
        : queue.indexWhere((t) => t.trackId == beforeTrackId);
    return QueueOp.insert(anchor < 0 ? queue.length : anchor, trackId);
  }
}

class _MoveIntent extends _QueueIntent {
  const _MoveIntent(super.trackId, {required this.beforeTrackId});

  /// The track the dragged one should land in front of; null means "at the
  /// end of the queue".
  final String? beforeTrackId;

  @override
  QueueOp? resolve(List<QueueTrack> queue) {
    final from = queue.indexWhere((t) => t.trackId == trackId);
    if (from < 0) return null;
    // The server applies move as splice-out-then-splice-in, so `to` indexes
    // the queue WITHOUT the dragged track — build that list and locate the
    // anchor in it.
    final rest = [
      for (final t in queue)
        if (t.trackId != trackId) t.trackId,
    ];
    final int to;
    if (beforeTrackId == null) {
      to = rest.length;
    } else {
      final anchor = rest.indexOf(beforeTrackId!);
      if (anchor < 0) return null; // the landing spot itself is gone
      to = anchor;
    }
    return from == to ? null : QueueOp.move(from, to);
  }
}

/// Back on the left and More on the right, each its own glass button. The
/// small title sits between them only once the cassette header has scrolled
/// away (board section 2).
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.titleShown,
    required this.onBack,
    required this.onMore,
  });

  final String title;
  final bool titleShown;
  final VoidCallback onBack;
  final Future<void> Function(BuildContext anchor)? onMore;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final reduced = MediaQuery.disableAnimationsOf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Row(
        children: [
          GlassCluster(
            children: [
              GlassButton(
                key: const Key('arrangement-back'),
                icon: Icons.arrow_back_ios_new,
                label: 'Back',
                onPressed: onBack,
              ),
            ],
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              // Hidden from VoiceOver too while it is invisible: the header
              // already reads the title.
              child: AnimatedOpacity(
                key: const Key('arrangement-nav-title'),
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
                    style: tokens.smallTitle,
                  ),
                ),
              ),
            ),
          ),
          GlassCluster(
            children: [
              Builder(
                builder: (anchor) => GlassButton(
                  key: const Key('arrangement-more'),
                  icon: Icons.more_horiz,
                  label: 'More',
                  onPressed: onMore == null ? null : () => onMore!(anchor),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// E4: only when there is nothing on screen at all — a list already shown
/// survives a failed refresh with a toast.
class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: LoadErrorState(
        title: "Couldn't load this tape",
        body: 'Check your connection and try again. The mix itself is safe.',
        retryKey: const Key('queue-retry'),
        onRetry: onRetry,
      ),
    ),
  );
}

/// E3: a conversation that has not produced an arrangement yet.
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Center(
      key: const Key('queue-empty'),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CassetteTile(width: QueueScreen.emptyCassetteWidth),
            const SizedBox(height: 18),
            Text(
              'Nothing on the tape yet',
              textAlign: TextAlign.center,
              style: tokens.section,
            ),
            const SizedBox(height: 6),
            Text(
              'Ask the DJ for a mix and it will show up here.',
              textAlign: TextAlign.center,
              style: tokens.secondary,
            ),
          ],
        ),
      ),
    );
  }
}

/// The corpus-mode block (plan: Copy — "Not personal yet" wherever a session
/// has `notPersonal`): the music door's tape layout, the bold label over the
/// line and its action, with a hairline under it (approval
/// `docs/mockups/approved/2026-11-09-add-your-music-loop.md`, frame 1D). The
/// tape is its own screen, so the action can show here and in the
/// conversation without showing twice at once.
class _NotPersonalBlock extends StatelessWidget {
  const _NotPersonalBlock({required this.onRemake});

  /// "Remake with my music"; null draws it disabled.
  final VoidCallback? onRemake;

  @override
  Widget build(BuildContext context) => MusicDoor(
    key: const Key('not-personal-banner'),
    notPersonal: true,
    layout: MusicDoorLayout.tape,
    onRemake: onRemake,
  );
}
