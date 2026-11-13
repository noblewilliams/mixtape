/// The mix handoff: everything that takes a finished arrangement OUT of this
/// app — Play (the app's own Apple player, falling back to the Music app),
/// Create playlist (an Apple Music playlist with a remembered author), and,
/// for a Spotify device, Create playlist on Spotify (the song list copied,
/// then TuneMyMusic's paste-a-list page builds the Spotify playlist;
/// decisions 2026-11-06).
///
/// Locked by `docs/mockups/approved/2026-09-17-mobile-arrangement-states.md`
/// (Create playlist) and, for the fixed per-platform actions, by
/// `docs/mockups/approved/2026-11-09-one-platform-play.md`. Drawn on
/// two screens: the conversation
/// (`screens/chat_screen.dart`) and the arrangement
/// (`screens/queue_screen.dart`). Both carried byte-near copies of this until
/// plan task 5.3; the copy, the gating and the toasts now live here once so
/// they cannot drift apart again.
///
/// Three pieces:
///
/// * pure copy builders and gating rules ([mixPlaySuccessMessage] and
///   friends, [mixActionsDisabledReason]) — no widgets, no providers;
/// * [MixHandoff], a mixin on `ConsumerState` holding the actions
///   themselves, their in-flight guards and their toasts;
/// * [MixActions], [MixPlayReason] and [MixSaveDialog], the surfaces they
///   drive.
///
/// Each host screen keeps its own keys and its own toast geometry
/// ([MixHandoffKeys], `showMixSnack`) — the arrangement's toast sits inside
/// that screen's local SnackBar theme and the conversation's sets its own
/// margin, so the message is shared but the presentation stays where it was.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart'
    show
        CupertinoActivityIndicator,
        CupertinoAlertDialog,
        CupertinoTheme,
        CupertinoDialogAction,
        CupertinoTextField,
        showCupertinoDialog;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dj/dj_api.dart' show DjApi;
import '../../data/dj/dj_models.dart';
import '../../data/listening/listening_models.dart' show FunnelEventType;
import '../../data/musickit/musickit_bridge.dart';
import '../../data/playback/playback_controller.dart' show PlaybackStart;
import '../providers/device_providers.dart';
import '../providers/dj_providers.dart';
import '../providers/funnel_provider.dart';
import '../providers/library_sync_provider.dart';
import '../providers/music_platform_provider.dart';
import '../providers/onboarding_provider.dart';
import '../providers/playback_provider.dart';
import '../screens/playback_screen.dart';
import '../theme/mixtape_theme.dart';
import 'foundation/alert_field_box.dart';
import 'foundation/label_chip.dart';
import 'foundation/mixtape_feedback.dart';
import 'foundation/service_marks.dart';
import 'foundation/tape_button.dart';
import 'spotify_handoff_sheets.dart';

export '../providers/music_platform_provider.dart' show MusicPlatform;

/// The page Create playlist on Spotify opens, matching the web rail's TRANSFER_TOOL_URL
/// (`web/src/components/QueuePanel.tsx`): TuneMyMusic's free-text-to-Spotify
/// transfer, which takes a pasted song list and builds a Spotify playlist.
/// Spotify's own API is closed to apps our size (five test users), so this is
/// the way a mix becomes a real Spotify playlist (decisions 2026-11-06).
final mixTransferToolUrl = Uri.https(
  'www.tunemymusic.com',
  '/transfer/freetext-to-spotify',
);

/// What Create playlist on Spotify copies: one "Artist - Title" line per song, every
/// song — TuneMyMusic searches Spotify by name, so a song with no Spotify id
/// still belongs in the list.
String mixTransferText(List<QueueTrack> queue) =>
    [for (final t in queue) '${t.artist} - ${t.title}'].join('\n');

/// Written beside Play / Create playlist when nothing in the mix has an
/// Apple Music match.
const mixNoAppleMatchReason = "these tracks aren't in Apple Music";

String mixPlaySuccessMessage(int skipped) => skipped > 0
    ? 'Playing in Apple Music · $skipped song${skipped == 1 ? '' : 's'} '
          'skipped (not in Apple Music)'
    : 'Playing in Apple Music';

String mixPlayFailureMessage(String reason) => "Couldn't play — $reason";

/// Play here's failure toast when neither the app's player nor the Music
/// app could play, and Apple said the account has no subscription.
const mixPlaySubscriptionMessage = 'Playing needs an Apple Music subscription.';

/// Play here when neither player could start it for any other reason. Plain
/// on purpose: the Music app's reason is Apple's raw error text
/// ("MPMusicPlayerControllerErrorDomain error 6"), which tells a listener
/// nothing.
const mixPlayFallbackFailedMessage = "Apple Music couldn't play this mix.";

String mixSaveSuccessMessage(int added, int failed) => failed > 0
    ? 'Saved $added songs to Apple Music ($failed failed)'
    : 'Saved $added songs to Apple Music';

/// The bridge's message carries Apple's actual failure reason (see
/// `MusicKitBridge._fromPlatform`) — hiding it behind a generic string made
/// real device failures undiagnosable.
String mixSaveFailureMessage(String reason) =>
    "Couldn't save the playlist — $reason";

String mixSpotifyCopiedMessage(int count) => count == 1
    ? 'Copied 1 song · paste it in, then rename “My Playlist”'
    : 'Copied $count songs · paste them in, then rename “My Playlist”';

const mixSpotifyFailureMessage = "couldn't copy the songs";

/// Null when Play/Create are actionable; otherwise the reason they are not,
/// written beside them rather than hidden in a tooltip: a mix whose tracks
/// are ALL missing an Apple Music match can't be played or saved at all (a
/// partial match still works — the filtered track count is reported in the
/// success toast instead). An arrangement that does not exist yet needs no
/// reason: the arrangement screen doesn't build the row at all, and the
/// conversation draws the actions simply disabled.
String? mixActionsDisabledReason(List<QueueTrack> queue) =>
    queue.isNotEmpty && queue.every((t) => t.appleId == null)
    ? mixNoAppleMatchReason
    : null;

/// Where a row with no Spotify id sends a Spotify listener: a search by
/// artist and title. One path segment, so a slash in a name is encoded.
Uri mixSpotifySearch(QueueTrack track) => Uri(
  scheme: 'https',
  host: 'open.spotify.com',
  pathSegments: ['search', '${track.artist} ${track.title}'],
);

/// The widget keys and the alert title each host screen puts on the shared
/// surfaces. Two screens draw the same row and the same alert; their keys
/// are what the two test suites (and VoiceOver's own ordering) already know
/// them by, so they travel with the screen rather than with the widget.
@immutable
class MixHandoffKeys {
  const MixHandoffKeys({
    required this.playNow,
    required this.createPlaylist,
    required this.spotifyPlaylist,
    required this.reason,
    required this.nameField,
    required this.authorField,
    required this.saveConfirm,
    required this.saveDialogTitle,
  });

  /// Apple Music's Play (Playing while the app's player is on this mix).
  final Key playNow;

  /// Apple Music's Create playlist.
  final Key createPlaylist;

  /// Spotify's one action, Create playlist through TuneMyMusic.
  final Key spotifyPlaylist;
  final Key reason;
  final Key nameField;
  final Key authorField;
  final Key saveConfirm;
  final String saveDialogTitle;

  /// The Playing meter on Play, for tests.
  static const Key meterKey = TapeButton.meterKey;

  /// `screens/queue_screen.dart`.
  static const arrangement = MixHandoffKeys(
    playNow: Key('play-here-button'),
    createPlaylist: Key('save-button'),
    spotifyPlaylist: Key('share-button'),
    reason: Key('actions-reason'),
    nameField: Key('playlist-name-field'),
    authorField: Key('playlist-author-field'),
    saveConfirm: Key('save-confirm-button'),
    saveDialogTitle: 'Save as playlist',
  );

  /// `screens/chat_screen.dart`.
  static const conversation = MixHandoffKeys(
    playNow: Key('chat-play-now'),
    createPlaylist: Key('chat-create-playlist'),
    spotifyPlaylist: Key('chat-share'),
    reason: Key('chat-actions-reason'),
    nameField: Key('chat-playlist-name'),
    authorField: Key('chat-playlist-author'),
    saveConfirm: Key('chat-playlist-save'),
    saveDialogTitle: 'Create playlist',
  );

  /// `screens/shared_mix_screen.dart`.
  static const shared = MixHandoffKeys(
    playNow: Key('shared-play'),
    createPlaylist: Key('shared-create-playlist'),
    spotifyPlaylist: Key('shared-spotify-playlist'),
    reason: Key('shared-actions-reason'),
    nameField: Key('shared-playlist-name'),
    authorField: Key('shared-playlist-author'),
    saveConfirm: Key('shared-playlist-save'),
    saveDialogTitle: 'Create playlist',
  );
}

/// The handoff actions, mixed into the screen that draws them so they
/// keep that screen's `ref`, `context` and in-flight guards.
///
/// A host supplies [mixSessionId] (the mix these actions belong to) and
/// [showMixSnack] (its own toast geometry); everything else is shared.
mixin MixHandoff<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// The session these actions act on — the id every event and playlist
  /// receipt is bound to.
  String get mixSessionId;

  /// The host's toast. Deliberately the host's own: the arrangement and the
  /// conversation each place the floating bar differently.
  void showMixSnack(String message, {FeedbackKind kind = FeedbackKind.info});

  /// Whether these actions count as the listener's own evidence: session
  /// events, playlist receipts and listening on the app's player. False on
  /// a shared mix (spec 2026-11-13 shared-mixes), which is someone else's
  /// and has no session of the listener's to bind them to.
  bool get mixRecordsEvidence => true;

  bool _sendingToMusic = false;
  bool _savingPlaylist = false;
  bool _sharingMix = false;

  /// True while the Send to Music bridge call is in flight.
  bool get sendingToMusic => _sendingToMusic;

  /// True from opening the save alert until it closes.
  bool get savingPlaylist => _savingPlaylist;

  /// True while the Spotify playlist handoff is in hand (its explainer, the
  /// copy and the tool's page).
  bool get sharingMix => _sharingMix;

  /// Fire-and-forget `POST /sessions/:id/events` — see
  /// `docs/superpowers/plans/2026-08-30-p4-taste-learning.md` Task 4. Posted
  /// exactly once per SUCCESSFUL play/save (never on failure, never on a
  /// rebuild), and any failure here is swallowed silently: the endpoint is
  /// purely a taste-learning signal, never allowed to degrade the handoff
  /// that already succeeded on the user's device. The save call site
  /// additionally only fires this when `result.added > 0` — a save that added
  /// zero tracks isn't evidence the user liked anything in this mix, and
  /// would be a false taste signal.
  void postMixEvent(String type) {
    if (!mixRecordsEvidence) return;
    unawaited(() async {
      try {
        await ref.read(djApiProvider).postSessionEvent(mixSessionId, type);
      } catch (_) {
        // Silent by design — no retry, no surfaced error.
      }
    }());
  }

  /// The once-only `first_output` funnel milestone: the FIRST SPOTIFY output
  /// action (plan: funnel events) — an "Open in Spotify" tap or a share the
  /// listener carried through. Play and Save are Apple outputs and post
  /// nothing here; they have their own session events. Same fire-and-forget
  /// contract as [postMixEvent]; the once-ness lives in [FunnelMilestones].
  void noteSpotifyOutput() => ref
      .read(funnelMilestonesProvider)
      .recordOnce(FunnelEventType.firstOutput);

  /// Whether the app's own player is on THIS mix — the Play now button then
  /// reads Playing and carries its meter.
  bool isPlayingThisMix() {
    final player = ref.read(playbackProvider);
    return player.sessionId == mixSessionId &&
        (player.sample.status == 'playing' ||
            player.sample.status == 'waiting');
  }

  /// Play now: the app-owned Apple player takes the arrangement and the Now
  /// Playing screen opens over it. Nothing on the list changes.
  ///
  /// The player starts FIRST and Now Playing opens only once it plays. The
  /// alternative (open at once, pop on failure) slides a screen showing the
  /// failure out from under the toast, and leaves it behind the system access
  /// prompt. Starting first stays responsive: the controller marks the mix
  /// `waiting` before the native call, so Play reads Playing from the tap.
  ///
  /// When the app's player cannot play it (access refused, a song it cannot
  /// find, a native failure) the mix goes to the Music app instead, which
  /// played where this did not; no error screen (decision 4 of
  /// `docs/superpowers/specs/2026-11-09-one-platform-play-design.md`). No
  /// subscription tries the Music app too, and only if that also fails says
  /// why.
  Future<void> playHere(ChatState state, List<QueueTrack> queue) => playMix(
    queue: queue,
    version: state.queueVersion,
    title: state.session.title,
  );

  /// [playHere] for a mix that is not a [ChatState] (a shared mix): the
  /// version and title the player shows, and the songs in order.
  Future<void> playMix({
    required List<QueueTrack> queue,
    required int version,
    required String title,
  }) async {
    final player = ref.read(playbackProvider);
    // Read up front: the listener may leave while Apple answers, and a
    // failed start must still be cleaned up and still reach the Music app.
    final music = ref.read(musicKitBridgeProvider);
    final api = ref.read(djApiProvider);
    final sessionId = mixSessionId;
    final outcome = await player.start(
      sessionId,
      version,
      title,
      queue,
      record: mixRecordsEvidence,
    );
    switch (outcome) {
      case PlaybackStart.superseded:
        return;
      case PlaybackStart.started:
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute<void>(builder: (_) => const PlaybackScreen()),
        );
      case PlaybackStart.unavailable:
      case PlaybackStart.subscriptionRequired:
        player.release();
        await _handToMusic(
          queue,
          music: music,
          api: api,
          sessionId: sessionId,
          record: mixRecordsEvidence,
          failureMessage: outcome == PlaybackStart.subscriptionRequired
              ? mixPlaySubscriptionMessage
              : mixPlayFallbackFailedMessage,
        );
    }
  }

  /// "Playing" was tapped: Now Playing opens over the screen, and the
  /// player is left exactly as it is.
  void openNowPlaying() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(builder: (_) => const PlaybackScreen()),
    );
  }

  /// Send to Music: the mix goes to Apple Music's own player, which reports
  /// how many songs it had no match for.
  ///
  /// [failureMessage] replaces the Music app's own reason when it fails, for
  /// a caller that knows the real cause (Play here with no subscription).
  Future<void> sendToMusic(List<QueueTrack> queue, {String? failureMessage}) =>
      _handToMusic(
        queue,
        music: ref.read(musicKitBridgeProvider),
        api: ref.read(djApiProvider),
        sessionId: mixSessionId,
        record: mixRecordsEvidence,
        failureMessage: failureMessage,
      );

  /// [sendToMusic] with its dependencies already in hand, so it finishes
  /// (and posts its event) even when the screen has gone; only the toast
  /// and the in-flight flag need the screen.
  Future<void> _handToMusic(
    List<QueueTrack> queue, {
    required MusicKitBridge music,
    required DjApi api,
    required String sessionId,
    required bool record,
    String? failureMessage,
  }) async {
    if (_sendingToMusic) return;
    _sendingToMusic = true;
    if (mounted) setState(() {});
    try {
      final ids = [
        for (final t in queue)
          if (t.appleId != null) t.appleId!,
      ];
      final skipped = queue.length - ids.length;
      await music.playQueue(ids);
      // As [postMixEvent], fire-and-forget and silent.
      if (record) {
        unawaited(
          api.postSessionEvent(sessionId, 'played').catchError((Object _) {}),
        );
      }
      if (!mounted) return;
      showMixSnack(mixPlaySuccessMessage(skipped), kind: FeedbackKind.success);
    } on MusicKitException catch (e) {
      // A plain failureMessage hides Apple's reason from the listener; keep
      // it in the device log so a failure stays diagnosable.
      if (failureMessage != null) debugPrint('Music app hand-off: ${e.message}');
      if (!mounted) return;
      showMixSnack(
        failureMessage ?? mixPlayFailureMessage(e.message),
        kind: FeedbackKind.error,
      );
    } finally {
      _sendingToMusic = false;
      if (mounted) setState(() {});
    }
  }

  /// Create playlist: the shared [MixSaveDialog], prefilled and remembered.
  ///
  /// Author prefill: the name typed on this device last time wins, then the
  /// account's display name (GET /me — read non-blocking: the fetch was
  /// started by the host's `build`, and a still-loading/absent value just
  /// means an empty field; per dj_providers' warning we never await a
  /// provider future across auth transitions). Blank falls back to 'mixtape'
  /// on save.
  Future<void> createPlaylist({
    required List<QueueTrack> queue,
    required String defaultName,
    required MixHandoffKeys keys,
  }) async {
    if (_savingPlaylist) return;
    setState(() => _savingPlaylist = true);
    try {
      String? storedAuthor;
      try {
        storedAuthor = await ref.read(authorStoreProvider).read();
      } catch (_) {
        storedAuthor = null; // a device that can't remember is not a failure
      }
      if (!mounted) return;
      final accountName = ref.read(accountNameProvider).value;
      await showCupertinoDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) => MixSaveDialog(
          keys: keys,
          defaultName: defaultName,
          newToYouCount: queue.where((track) => track.newToYou).length,
          defaultAuthor:
              (storedAuthor != null && storedAuthor.isNotEmpty
                  ? storedAuthor
                  : accountName) ??
              '',
          onConfirm: (name, author) => _confirmSave(
            dialogContext: dialogContext,
            queue: queue,
            rawName: name,
            defaultName: defaultName,
            rawAuthor: author,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _savingPlaylist = false);
    }
  }

  /// Runs the actual bridge call for a confirmed save — called by
  /// [MixSaveDialog] itself, which owns the double-tap guard on its Save
  /// button (each tap would otherwise create a NEW playlist; there's no way
  /// to dedupe after the fact). Always resolves the alert (pops it) on both
  /// success and failure, then reports the outcome as a toast on the screen
  /// underneath.
  Future<void> _confirmSave({
    required BuildContext dialogContext,
    required List<QueueTrack> queue,
    required String rawName,
    required String defaultName,
    required String rawAuthor,
  }) async {
    final trimmed = rawName.trim();
    final name = trimmed.isEmpty ? defaultName : trimmed;
    // Attribution: without an explicit author Apple shows the Xcode product
    // name ("Runner"). The user's typed name wins; blank falls back to the
    // app name. Remembered (even if the save then fails) so the next alert
    // prefills it — it's the user's name, not per-playlist data.
    final trimmedAuthor = rawAuthor.trim();
    final author = trimmedAuthor.isEmpty ? 'mixtape' : trimmedAuthor;
    if (trimmedAuthor.isNotEmpty) {
      try {
        await ref.read(authorStoreProvider).write(trimmedAuthor);
      } catch (_) {
        // Remembering the name is a nicety; never block the save on it.
      }
    }
    final ids = [
      for (final t in queue)
        if (t.appleId != null) t.appleId!,
    ];
    final creationApi = ref.read(djApiProvider);
    final creationSessionId = mixSessionId;
    final receipt = mixRecordsEvidence;
    try {
      final result = await ref
          .read(musicKitBridgeProvider)
          .createPlaylist(
            name,
            ids,
            author: author,
            description: 'made by mixtape',
            onCreated: (libraryId) {
              if (!receipt) return;
              // Bind to the originating mix, not a screen/account that may
              // have changed while Apple was creating the playlist.
              unawaited(
                creationApi
                    .recordPlaylistCreation(creationSessionId, libraryId)
                    .catchError((Object _) {}),
              );
            },
          );
      // A zero-added save is a false taste signal, not evidence of a like —
      // see [postMixEvent].
      if (result.added > 0) postMixEvent('saved_playlist');
      if (dialogContext.mounted) Navigator.of(dialogContext).pop();
      if (!mounted) return;
      showMixSnack(
        mixSaveSuccessMessage(result.added, result.failed),
        kind: result.added > 0 ? FeedbackKind.success : FeedbackKind.error,
      );
    } on MusicKitException {
      // Keep the entered name and author next to the recovery message.
      rethrow;
    }
  }

  /// Create playlist on Spotify: the song list goes to the clipboard and
  /// TuneMyMusic's paste-a-list page opens to build the Spotify playlist.
  /// The first time on a device an explainer says so before anything
  /// happens; Cancel there is no output at all.
  Future<void> createSpotifyPlaylist(List<QueueTrack> queue) async {
    if (_sharingMix) return;
    setState(() => _sharingMix = true);
    try {
      final store = ref.read(musicPlatformStoreProvider);
      var seen = false;
      try {
        seen = await store.spotifyIntroSeen();
      } catch (_) {
        // A device that cannot remember explains every time.
      }
      if (!mounted) return;
      if (!seen) {
        final go = await confirmSpotifyHandoff(context, queue.length);
        if (!mounted || !go) return;
        try {
          await store.markSpotifyIntroSeen();
        } catch (_) {
          // Remembering is a nicety.
        }
      }
      await ref.read(clipboardWriterProvider).copy(mixTransferText(queue));
      noteSpotifyOutput();
      try {
        await ref.read(linkOpenerProvider)(mixTransferToolUrl);
      } catch (_) {
        // The songs are already copied; a browser that won't open isn't
        // worth a second message on top of the confirmation.
      }
      if (!mounted) return;
      showMixSnack(
        mixSpotifyCopiedMessage(queue.length),
        kind: FeedbackKind.success,
      );
    } catch (_) {
      if (!mounted) return;
      showMixSnack(mixSpotifyFailureMessage, kind: FeedbackKind.error);
    } finally {
      if (mounted) setState(() => _sharingMix = false);
    }
  }
}

/// The mix actions (`docs/mockups/approved/2026-11-09-one-platform-play.md`),
/// fixed by the device's platform and identical on the conversation's strip
/// and the tape's bar. No arrow, no menu: nothing changes on a tap but Play
/// becoming Playing.
///
/// * Apple Music (and a platform not chosen yet): Play, which reads Playing
///   with the prism meter while the app's player is on this mix and then
///   opens Now Playing, beside Create playlist. Both share the row, Play on
///   the left; with no Apple Music match both stay, inert, and
///   [MixPlayReason] says why.
/// * Spotify: one full-width tape, Create playlist with the Spotify mark,
///   read as "Create Spotify playlist". There is no Play.
///
/// At accessibility text sizes the pair stacks, each full width.
class MixActions extends ConsumerWidget {
  const MixActions({
    super.key,
    required this.keys,
    required this.queue,
    required this.isPlayingThisMix,
    required this.onPlay,
    required this.onOpenNowPlaying,
    required this.onCreatePlaylist,
    required this.onCreateSpotifyPlaylist,
    this.enabled = true,
    this.creatingPlaylist = false,
    this.sharing = false,
    this.sendingToMusic = false,
    this.spacing = 8,
  });

  final MixHandoffKeys keys;

  /// The arrangement this mix currently has; empty until the DJ makes one.
  final List<QueueTrack> queue;

  /// False while the host is busy: the actions go inert in place.
  final bool enabled;

  final bool Function() isPlayingThisMix;
  final VoidCallback onPlay;

  /// "Playing" was tapped: the app player is already on this mix.
  final VoidCallback onOpenNowPlaying;
  final VoidCallback onCreatePlaylist;
  final VoidCallback onCreateSpotifyPlaylist;

  /// The Apple save alert is up.
  final bool creatingPlaylist;

  /// The Spotify handoff is in hand.
  final bool sharing;

  /// The mix is on its way to the Music app (Play's fallback): Play is inert
  /// so a second tap cannot start it twice.
  final bool sendingToMusic;

  /// The gap between the pair: `.strip .acts { gap: 8px }`,
  /// `.sticky { gap: 10px }`.
  final double spacing;

  static const String playLabel = 'Play';
  static const String playingLabel = 'Playing';
  static const String playingHint = 'Opens Now Playing';
  static const String createPlaylistLabel = 'Create playlist';
  static const String spotifyPlaylistSemantics = 'Create Spotify playlist';

  /// `.tape.sp .mk`.
  static const double markSize = 18;

  /// From here on the pair stacks (the strip's own threshold).
  static const double stackScale = 1.5;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final platform = ref.watch(musicPlatformProvider) ?? MusicPlatform.apple;
    final ink = context.tokens.tapeInk;
    if (platform == MusicPlatform.spotify) {
      return TapeButton(
        key: keys.spotifyPlaylist,
        label: createPlaylistLabel,
        semanticsLabel: spotifyPlaylistSemantics,
        fill: true,
        leading: SpotifyMark(size: markSize, color: ink),
        onPressed: enabled && !sharing && queue.isNotEmpty
            ? onCreateSpotifyPlaylist
            : null,
      );
    }

    final live =
        enabled && queue.isNotEmpty && mixActionsDisabledReason(queue) == null;
    final stacked =
        MediaQuery.textScalerOf(context).scale(100) / 100 >= stackScale;
    final create = LabelChip(
      key: keys.createPlaylist,
      label: createPlaylistLabel,
      fill: true,
      onPressed: live && !creatingPlaylist ? onCreatePlaylist : null,
    );
    return ListenableBuilder(
      listenable: ref.read(playbackProvider),
      builder: (context, _) {
        final player = ref.read(playbackProvider);
        // A start in flight marks the mix `waiting` before Apple answers, and
        // may yet fail and go to the Music app: until it settles, Play is
        // inert and never reads Playing (nor opens an empty Now Playing).
        final starting = player.busy;
        final playing = !starting && isPlayingThisMix();
        final play = TapeButton(
          key: keys.playNow,
          label: playing ? playingLabel : playLabel,
          semanticsHint: playing ? playingHint : null,
          playing: playing,
          fill: true,
          leading: Icon(Icons.play_arrow_rounded, size: 16, color: ink),
          onPressed: playing
              ? onOpenNowPlaying
              : (live && !starting && !sendingToMusic ? onPlay : null),
        );
        if (stacked) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              play,
              SizedBox(height: spacing),
              create,
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: play),
            SizedBox(width: spacing),
            Expanded(child: create),
          ],
        );
      },
    );
  }
}

/// The muted line an Apple Music mix carries when Play and Create playlist
/// cannot work: no Apple Music match at all. Draws nothing otherwise, and
/// nothing for a Spotify device, whose one action always works.
class MixPlayReason extends ConsumerWidget {
  const MixPlayReason({super.key, required this.keys, required this.queue});

  final MixHandoffKeys keys;
  final List<QueueTrack> queue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(musicPlatformProvider) == MusicPlatform.spotify) {
      return const SizedBox.shrink();
    }
    final reason = mixActionsDisabledReason(queue);
    if (reason == null) return const SizedBox.shrink();
    final tokens = context.tokens;
    return Text(
      reason,
      key: keys.reason,
      style: tokens.meta.copyWith(color: tokens.muted),
    );
  }
}

/// The save alert's second helper line, when the mix holds new songs.
String mixSaveNewToYouLine(int count) => count == 1
    ? '1 song here is new to you. Saving adds it to your Apple Music library.'
    : '$count songs here are new to you. Saving adds them to your Apple Music library.';

/// P3's native alert: the mix title as the default name, and "Your name"
/// remembered for next time.
class MixSaveDialog extends StatefulWidget {
  const MixSaveDialog({
    super.key,
    required this.keys,
    required this.defaultName,
    required this.defaultAuthor,
    required this.onConfirm,
    this.newToYouCount = 0,
  });

  final MixHandoffKeys keys;
  final String defaultName;
  final String defaultAuthor;

  /// Songs in the mix from outside the listener's library; saving adds them
  /// to it, so the alert says so when there are any.
  final int newToYouCount;
  final Future<void> Function(String name, String author) onConfirm;

  @override
  State<MixSaveDialog> createState() => _MixSaveDialogState();
}

class _MixSaveDialogState extends State<MixSaveDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.defaultName,
  );
  late final TextEditingController _author = TextEditingController(
    text: widget.defaultAuthor,
  );
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _author.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    // Guards a double-tap: each tap would otherwise create a NEW playlist.
    if (_submitting || _name.text.trim().isEmpty) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.onConfirm(_name.text, _author.text);
    } on MusicKitException catch (error) {
      if (mounted) {
        setState(() => _error = mixSaveFailureMessage(error.message));
      }
    } catch (error, stack) {
      // onConfirm resolves both outcomes it knows about — a save and Apple's
      // refusal — by popping this alert itself. Anything else reaching here
      // is unexpected, and the button's callback discards this future, so
      // rethrowing would lose it as an unhandled async error: report it to
      // the app's error handler instead.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'mixtape',
          context: ErrorDescription('while saving a mix as a playlist'),
        ),
      );
    } finally {
      // onConfirm pops this alert itself on both the success and the
      // MusicKit-failure path, so normally this widget is already gone and
      // the line below never runs. It matters for the third path: anything
      // else thrown (an offline store, a programming error) leaves the alert
      // open, and without this the listener would be stranded on a dead
      // spinner with Cancel disabled and no way out.
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Not `context.tokens`: this alert is pumped by hosts that build a bare
    // `MaterialApp`, and a helper line is not worth an assertion.
    final helper = CupertinoTheme.of(
      context,
    ).textTheme.tabLabelTextStyle.copyWith(fontSize: 12);
    return CupertinoAlertDialog(
      title: Text(widget.keys.saveDialogTitle),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          AlertFieldBox(
            child: CupertinoTextField(
              key: widget.keys.nameField,
              controller: _name,
              onChanged: (_) => setState(() {}),
              autofocus: true,
              enabled: !_submitting,
              placeholder: 'Playlist name',
            ),
          ),
          const SizedBox(height: 10),
          AlertFieldBox(
            child: CupertinoTextField(
              key: widget.keys.authorField,
              controller: _author,
              enabled: !_submitting,
              placeholder: 'Your name',
            ),
          ),
          const SizedBox(height: 6),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  style: helper.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ),
          Text(
            'Shown under the playlist in Apple Music',
            textAlign: TextAlign.start,
            style: helper,
          ),
          if (widget.newToYouCount > 0) ...[
            const SizedBox(height: 6),
            Text(
              mixSaveNewToYouLine(widget.newToYouCount),
              textAlign: TextAlign.start,
              style: helper,
            ),
          ],
        ],
      ),
      actions: [
        CupertinoDialogAction(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        CupertinoDialogAction(
          key: widget.keys.saveConfirm,
          isDefaultAction: true,
          onPressed: _submitting || _name.text.trim().isEmpty ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CupertinoActivityIndicator(radius: 8),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}
