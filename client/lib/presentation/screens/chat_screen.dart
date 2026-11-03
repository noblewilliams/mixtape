/// The conversation: talking to the DJ about one mix
/// (`docs/mockups/approved/2026-09-17-mobile-conversation-states.md`, frames
/// C1–C3 / F1–F3 / A1–A3 in
/// `docs/mockups/2026-09-17-mobile-conversation-states.html`; the frame itself
/// is locked by `docs/mockups/approved/2026-09-17-mobile-shell.md`).
///
/// Glass back and action clusters over a small title, flush turns on the
/// gradient, and a bottom panel holding the attachments, the composer and the
/// mix actions. Pushed inside a tab [Navigator] — the shell hides the dock for
/// it — so it draws its own chrome and never assumes it is the root route.
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
import '../widgets/ai_consent_sheet.dart';
import '../widgets/open_tape_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_client.dart';
import '../../data/dj/dj_models.dart';
import '../../data/playlists/playlist_context_models.dart';
import '../providers/dj_providers.dart';
import '../providers/keep_mixes_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/library_sync_provider.dart';
import '../providers/playlist_context_provider.dart';
import '../providers/shell_providers.dart';
import '../providers/mix_operation_gate.dart';
import '../theme/mixtape_theme.dart';
import '../widgets/album_card.dart';
import '../widgets/lyric_turn.dart';
import '../widgets/energy_journey.dart';
import '../widgets/foundation/glass_cluster.dart';
import '../widgets/foundation/idea_pill.dart';
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/liquid_glass_surface.dart';
import '../widgets/foundation/tape_button.dart';
import '../widgets/foundation/text_action.dart';
import '../widgets/home_panel.dart' show HomePanel;
import '../widgets/keep_sheet.dart';
import '../widgets/mix_energy_summary.dart';
import '../widgets/mix_handoff.dart';
import '../widgets/mix_prompt_input.dart';
import '../widgets/mix_tape_colour.dart';
import '../widgets/playlist_inspiration.dart';
import '../widgets/tape_strip.dart';
import '../widgets/version_marker.dart';
import 'mix_history_screen.dart';
import 'queue_screen.dart';
import '../widgets/foundation/mixtape_menu.dart';

/// The toast a selection changed somewhere else earns: the canonical seed is
/// adopted, the arrangement and the unsent draft are left alone, and the
/// listener is told (approved record → Attachment chips).
String inspirationChangedMessage(String? name) =>
    '${name ?? 'The inspiration'} changed elsewhere. '
    'Showing the current selection.';

class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.sessionId, this.initialError});

  final String sessionId;

  /// Set only when Home navigates here after a create-session failure that
  /// still persisted a session row (see `dj_providers.dart`'s
  /// `sessionStarterProvider` doc comment) — the server's error message,
  /// which never made it into the transcript itself. Seeded once, as a
  /// synthetic error turn, right after the initial load (see
  /// [_ChatScreenState.build]'s one-shot seed). Does not change the screen's
  /// contract otherwise: every other caller passes null.
  final String? initialError;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen>
    with MixHandoff<ChatScreen> {
  final _scrollController = ScrollController();
  final _textController = TextEditingController();
  final _promptFocus = FocusNode();
  final _composerKey = GlobalKey();
  final _panelKey = GlobalKey();

  int _lastMessageCount = -1;
  bool _seededInitialError = false;
  bool _keepSheetChecked = false;

  /// A send waiting on the AI-consent sheet.
  bool _askingConsent = false;
  bool _changingStatus = false;

  @override
  String get mixSessionId => widget.sessionId;

  @override
  void showMixSnack(String message, {FeedbackKind kind = FeedbackKind.info}) =>
      _snack(message, kind: kind);

  /// The panel's measured height, which the transcript pads for. The panel
  /// floats over the transcript (and rides the keyboard), so the list cannot
  /// lay itself out against it — it is measured after the frame instead.
  double _panelHeight = 0;
  bool _measuring = false;

  @override
  void dispose() {
    _scrollController.dispose();
    _textController.dispose();
    _promptFocus.dispose();
    super.dispose();
  }

  void _measurePanel() {
    if (_measuring) return;
    _measuring = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measuring = false;
      if (!mounted) return;
      final box = _panelKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      if ((box.size.height - _panelHeight).abs() < 0.5) return;
      setState(() => _panelHeight = box.size.height);
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  /// Unforeseen-exception guard: [ChatNotifier.send] already resolves every
  /// error type it knows about into an error turn and never rethrows — this
  /// catch-all exists purely so an entirely unanticipated exception can't
  /// become an unhandled async error with a bricked composer.
  ///
  /// [fromComposer] gates clearing the draft: true when the composer's own
  /// send fired this (the just-sent text IS the draft, safe to clear), false
  /// for a resend (which resends a DIFFERENT, already-sent turn's text —
  /// clearing the controller here would silently wipe whatever new draft the
  /// user has since started typing).
  Future<void> _send(String text, {bool fromComposer = false}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty ||
        ref.read(mixOperationProvider(widget.sessionId)) != null ||
        ref.read(sessionPlaylistContextProvider(widget.sessionId)).writing ||
        ref.read(chatProvider(widget.sessionId)).value?.sending == true ||
        _askingConsent) {
      return;
    }
    // Nothing reaches the DJ before the listener has agreed; Not now keeps
    // the draft in the composer.
    _askingConsent = true;
    final agreed = await confirmAiConsent(context);
    _askingConsent = false;
    if (!agreed || !mounted) return;
    if (fromComposer) _textController.clear();
    try {
      await ref.read(chatProvider(widget.sessionId).notifier).send(trimmed);
    } on AiConsentRequiredException {
      // Enforcement is on and `/me` was out of date: the turn was taken
      // back. The text goes back in the composer, the sheet asks, and
      // Agree sends it again.
      if (!mounted) return;
      if (fromComposer && _textController.text.isEmpty) {
        _textController.text = trimmed;
      }
      _askingConsent = true;
      final again = await confirmAiConsentAfterRefusal(context);
      _askingConsent = false;
      if (!again || !mounted) return;
      await _send(
        fromComposer ? _textController.text : trimmed,
        fromComposer: fromComposer,
      );
    } catch (_) {
      if (!mounted) return;
      _snack('something unexpected happened', kind: FeedbackKind.error);
    }
  }

  /// Floating, 16 pt in: there is no dock on this route for a toast to clear,
  /// and the app-level [ScaffoldMessenger] builds the bar against the app's
  /// own theme, so the geometry is set here rather than in a local theme.
  void _snack(
    String message, {
    SnackBarAction? action,
    FeedbackKind kind = FeedbackKind.info,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      mixtapeSnackBar(
        message: message,
        kind: kind,
        actionLabel: action?.label,
        onAction: action?.onPressed,
      ),
    );
  }

  Future<void> _pickInspiration() async {
    final contextState = ref.read(
      sessionPlaylistContextProvider(widget.sessionId),
    );
    if (!contextState.canSelect ||
        ref.read(mixOperationProvider(widget.sessionId)) != null) {
      return;
    }
    final seed = contextState.seed;
    final box = _composerKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final initialRect = box.localToGlobal(Offset.zero) & box.size;
    Rect composerRect() {
      final current = _composerKey.currentContext?.findRenderObject();
      return current is RenderBox && current.attached
          ? current.localToGlobal(Offset.zero) & current.size
          : initialRect;
    }

    final choice = await showPlaylistInspirationPicker(
      context,
      ref,
      anchor: initialRect,
      anchorResolver: composerRect,
      selected: seed?.playlistId == null
          ? null
          : InitialPlaylistSeed(
              playlistId: seed!.playlistId!,
              excludeSourceTracks: seed.excludeSourceTracks,
            ),
    );
    if (!mounted || choice == null) return;
    await ref
        .read(sessionPlaylistContextProvider(widget.sessionId).notifier)
        .select(
          playlistId: choice.seed.playlistId,
          excludeSourceTracks: choice.seed.excludeSourceTracks,
        );
  }

  void _openArrangement() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => QueueScreen(sessionId: widget.sessionId),
      ),
    );
  }

  void _openHistory({int? version}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MixHistoryScreen(
          sessionId: widget.sessionId,
          initialVersion: version,
        ),
      ),
    );
  }

  /// The More menu (board section 2, the same on the tape): Version history,
  /// Tape settings, Rename, then Archive or Restore behind a separator. An
  /// album session keeps Rename and Archive only: it has no versions to
  /// browse and no tape to dress.
  Future<void> _actions(BuildContext anchor) async {
    final session = ref.read(chatProvider(widget.sessionId)).value?.session;
    final archived = session?.status == 'archived';
    final album = session?.kind == SessionKind.album;
    final action = await showMixtapeMenu<String>(
      anchor,
      actions: [
        if (!album)
          const MixtapeMenuAction(value: 'history', label: 'Version history'),
        if (!album)
          const MixtapeMenuAction(
            value: 'tape-settings',
            label: 'Tape settings',
          ),
        const MixtapeMenuAction(value: 'rename', label: 'Rename'),
        MixtapeMenuAction(
          value: 'status',
          label: archived ? 'Restore' : 'Archive',
          isDestructive: !archived,
          separatorBefore: true,
        ),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'history') return _openHistory();
    if (action == 'rename') return _rename();
    if (action == 'tape-settings') {
      return openTapeSettings(context, ref, widget.sessionId);
    }
    await _setArchived(archived);
  }

  /// Archiving changes status only: the conversation stays open and editable,
  /// and Undo puts it back.
  Future<void> _setArchived(bool archived) async {
    if (_changingStatus) return;
    setState(() => _changingStatus = true);
    final notifier = ref.read(chatProvider(widget.sessionId).notifier);
    final ok = await notifier.setArchived(!archived);
    if (!mounted) return;
    setState(() => _changingStatus = false);
    final sessions = ref.read(sessionsProvider.notifier);
    _snack(
      ok
          ? (archived ? 'Mix restored' : 'Mix archived')
          : 'Couldn’t update this mix. Try again.',
      kind: ok ? FeedbackKind.success : FeedbackKind.error,
      action: ok && !archived
          ? SnackBarAction(
              label: 'Undo',
              onPressed: () async {
                if (mounted) {
                  await notifier.setArchived(false);
                } else {
                  await sessions.unarchive(widget.sessionId);
                }
              },
            )
          : null,
    );
  }

  /// The native alert, with the current title preselected.
  Future<void> _rename() async {
    final session = ref.read(chatProvider(widget.sessionId)).value?.session;
    final current = session?.title ?? '';
    final name = await showCupertinoDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (_) => _RenameDialog(
        title: current,
        heading: session?.kind == SessionKind.album ? 'Rename' : 'Rename mix',
      ),
    );
    if (!mounted || name == null || name.trim().isEmpty) return;
    final ok = await ref
        .read(chatProvider(widget.sessionId).notifier)
        .rename(name);
    if (!mounted || ok) return;
    _snack('Couldn’t rename this mix. Try again.', kind: FeedbackKind.error);
  }

  Future<void> _expireSession(SessionPlaylistContextState expected) async {
    if (!mounted ||
        !identical(
          ref.read(sessionPlaylistContextProvider(widget.sessionId)),
          expected,
        )) {
      return;
    }
    try {
      await ref.read(authProvider.notifier).signOut();
    } catch (_) {
      if (!mounted ||
          !identical(
            ref.read(sessionPlaylistContextProvider(widget.sessionId)),
            expected,
          )) {
        return;
      }
      _snack('Couldn’t sign out. Try again.', kind: FeedbackKind.error);
    }
  }

  /// The line under the attachment row when the chip alone cannot say it.
  String? _inspirationStatus(SessionPlaylistContextState contextState) {
    if (contextState.error case ApiException(statusCode: 401)) {
      return 'Your session expired. Sign in again.';
    }
    if (contextState.loading) return 'Loading inspiration…';
    if (contextState.seed == null) {
      return 'Couldn’t read the current inspiration.';
    }
    if (contextState.error != null) {
      return 'Check the current inspiration before trying again.';
    }
    return switch (contextState.seed!.status) {
      PlaylistSeedStatus.unavailable => 'Replace or detach it to use one.',
      PlaylistSeedStatus.insufficientProfile =>
        'At least 3 matched recordings are needed.',
      _ => null,
    };
  }

  /// The seed could not be read (or its last read failed): offer another
  /// read rather than letting the listener write blind.
  bool _canReloadInspiration(SessionPlaylistContextState state) =>
      state.seed == null || state.error != null;

  InspirationChipTone _chipTone(SessionPlaylistContextState state) =>
      switch (state.seed?.status) {
        PlaylistSeedStatus.unavailable => InspirationChipTone.unavailable,
        PlaylistSeedStatus.insufficientProfile =>
          InspirationChipTone.insufficient,
        _ => InspirationChipTone.ready,
      };

  @override
  Widget build(BuildContext context) {
    final chatAsync = ref.watch(chatProvider(widget.sessionId));
    final inspiration = ref.watch(
      sessionPlaylistContextProvider(widget.sessionId),
    );
    final operation = ref.watch(mixOperationProvider(widget.sessionId));
    // Kick off the /me fetch as soon as the conversation opens, so the
    // account name is resolved by the time the save dialog reads it
    // non-blocking (see [_createPlaylist]). Any failure resolves to null.
    ref.watch(accountNameProvider);
    _measurePanel();

    ref.listen(sessionPlaylistContextProvider(widget.sessionId), (
      previous,
      next,
    ) {
      if (next.error case ApiException(statusCode: 401)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              identical(
                ref.read(sessionPlaylistContextProvider(widget.sessionId)),
                next,
              )) {
            _expireSession(next);
          }
        });
      }
      // A selection made somewhere else: the canonical seed has already been
      // adopted (the arrangement and the unsent draft are untouched), so the
      // only thing left is to say so. A write from THIS screen is excluded by
      // `previous.writing` — that transition is the listener's own doing.
      final before = previous?.seed;
      final after = next.seed;
      if (before != null &&
          after != null &&
          !(previous?.writing ?? false) &&
          !next.writing &&
          after.revision != before.revision &&
          ModalRoute.of(context)?.isCurrent == true) {
        _snack(inspirationChangedMessage(after.name ?? before.name));
      }
    });

    ref.listen(chatProvider(widget.sessionId), (previous, next) {
      final state = next.value;
      if (state == null) return;

      // Display guarded on being the top route: QueueScreen watches the
      // same provider and runs the same listener, so with the arrangement
      // pushed over this screen one error would otherwise queue two
      // identical snackbars. Clearing is unconditional — a transientError
      // left in state gets carried forward by copyWith and would surface
      // later against an unrelated event. Both listeners see the same
      // captured `state`, so either clearing first can't hide it from the
      // other.
      if (state.transientError != null) {
        if (ModalRoute.of(context)?.isCurrent == true) {
          _snack(state.transientError!, kind: FeedbackKind.error);
        }
        ref.read(chatProvider(widget.sessionId).notifier).clearTransientError();
      }

      // The working cassette takes the DJ's next line's place: bring it
      // into view as the send starts, as a new turn would be.
      final wasSending = previous?.value?.sending ?? false;
      if (state.sending != wasSending) _scrollToBottom();

      if (state.messages.length != _lastMessageCount) {
        _lastMessageCount = state.messages.length;
        _scrollToBottom();
      }
    });

    // One-shot initialError seeding, done from build() rather than a
    // listener: ref.listen only fires on CHANGES, so if the provider were
    // already warm at mount a listener-based seed would sit dormant and then
    // land on the next unrelated emission — appending the error turn out of
    // order. build() sees the current state on the very first frame.
    // Post-frame because mutating a provider during build is illegal; the
    // flag flips synchronously first, so re-entrant rebuilds can never
    // schedule a duplicate.
    if (!_seededInitialError &&
        widget.initialError != null &&
        chatAsync.hasValue) {
      _seededInitialError = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref
            .read(chatProvider(widget.sessionId).notifier)
            .seedInitialError(widget.initialError!);
      });
    }

    // The Keep this mix sheet (board A6), once the new mix it was offered
    // for is on screen: an anonymous listener's first mix with content this
    // app session (see [KeepSheetNotifier]). Checked once per screen, from
    // build for the same reason as the seed above.
    if (!_keepSheetChecked && chatAsync.hasValue) {
      _keepSheetChecked = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (ref.read(keepSheetProvider.notifier).take(widget.sessionId)) {
          unawaited(showKeepSheet(context));
        }
      });
    }

    // ...and when a follow-up turn fills a refused mix while it is open.
    ref.listen<KeepSheetState>(keepSheetProvider, (previous, next) {
      if (!_keepSheetChecked || next.shown) return;
      if (next.offeredFor != widget.sessionId) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (ref.read(keepSheetProvider.notifier).take(widget.sessionId)) {
          unawaited(showKeepSheet(context));
        }
      });
    });

    // Riverpod 3 retries a throwing build() with backoff; during that retry
    // the state is technically AsyncLoading but still carries the last error
    // forward. Checking hasError FIRST — rather than isLoading — means the
    // listener sees the could-not-open state immediately instead of a
    // skeleton that silently retries for several seconds.
    //
    // `!chatAsync.hasValue` is load-bearing: the SAME retrying AsyncLoading
    // state also retains a PREVIOUS value when one exists (a live transcript
    // whose background refetch just failed). Never let a failed refetch blank
    // out a transcript the listener is already looking at — that surfaces as
    // a brief toast instead (the transientError listener above).
    if (chatAsync.hasError && !chatAsync.hasValue) {
      return _frame(
        title: '',
        body: _CouldNotOpen(
          onRetry: () => ref.invalidate(chatProvider(widget.sessionId)),
        ),
      );
    }

    if (!chatAsync.hasValue) {
      // F2: chrome from the first frame, skeleton turns only. The title comes
      // from the Mixes list the listener just tapped, so it is already there
      // while the transcript loads — the board's "Opening <title>".
      final title = _knownTitle();
      return _frame(
        title: title ?? '',
        body: _SkeletonTurns(title: title),
        panel: _panel(state: null, inspiration: inspiration, busy: true),
      );
    }

    final state = chatAsync.value!;
    final busy = state.sending || operation != null || inspiration.writing;

    return _frame(
      title: state.session.title,
      notPersonal: state.session.notPersonal,
      onMore: _changingStatus ? null : _actions,
      body: _transcript(state, busy: busy),
      panel: _panel(state: state, inspiration: inspiration, busy: busy),
    );
  }

  /// Chrome shared by every state: the gradient, the header (Back, the
  /// title, More), the floating SnackBars (no dock on this route, so they sit
  /// 16 pt in) and the panel floating over the transcript.
  Widget _frame({
    required String title,
    required Widget body,
    bool notPersonal = false,
    Future<void> Function(BuildContext anchor)? onMore,
    Widget? panel,
  }) {
    return GradientBackground(
      child: Builder(
        builder: (context) => Scaffold(
          backgroundColor: Colors.transparent,
          // The panel rides the keyboard itself, as Home's does.
          resizeToAvoidBottomInset: false,
          body: Stack(
            children: [
              SafeArea(
                bottom: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _TopBar(
                      title: title,
                      notPersonal: notPersonal,
                      onBack: () => Navigator.of(context).maybePop(),
                      onMore: onMore,
                    ),
                    Expanded(child: body),
                  ],
                ),
              ),
              if (panel != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: KeyedSubtree(key: _panelKey, child: panel),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Whether this mix has a tape yet: before the first one, the working
  /// cassette wears the default case.
  bool _hasTape(ChatState state) =>
      state.queue.isNotEmpty || state.queueVersion > 0;

  /// The colour every cassette of this mix wears.
  Color _tapeColour(ChatState state) => watchMixTapeColour(
    ref,
    widget.sessionId,
    saved: state.session.caseColor,
  );

  /// The turns as lyrics, scrolled to the last one. Each version-changing
  /// reply is followed by its marker; the current version's reads
  /// "current" (the strip below holds it, so there is no tape card).
  Widget _transcript(ChatState state, {required bool busy}) {
    if (state.kind == SessionKind.album) {
      return _albumTranscript(state, busy: busy);
    }
    final currentVersion = state.queueVersion;
    final colour = _tapeColour(state);

    // The LATEST message carrying the current version gets the current
    // marker; every other version-bearing message gets an earlier one.
    int? liveIndex;
    for (var i = state.messages.length - 1; i >= 0; i--) {
      if (state.messages[i].message.queueVersion == currentVersion) {
        liveIndex = i;
        break;
      }
    }

    List<Widget> current() => [
      VersionMarker(
        key: VersionMarker.keyFor(currentVersion),
        version: currentVersion,
        caseColor: colour,
        songs: state.queue.length,
        current: true,
      ),
      if (currentVersion > 0)
        MixEnergySummary(sessionId: widget.sessionId, version: currentVersion),
    ];

    final lastUser = _lastUserIndex(state);
    int? pinnedFrom;
    final items = <Widget>[];
    for (var i = 0; i < state.messages.length; i++) {
      if (i == lastUser) pinnedFrom = items.length;
      items.add(_turn(state, i, busy: busy));
      final version = state.messages[i].message.queueVersion;
      if (version == null) continue;
      if (i == liveIndex) {
        // The server tags version-changed messages even when a turn EMPTIES
        // the queue; a marker for an empty tape would point at nothing.
        if (state.queue.isNotEmpty) items.addAll(current());
      } else {
        items.add(
          VersionMarker(
            key: VersionMarker.keyFor(version),
            version: version,
            caseColor: colour,
            onOpen: () => _openHistory(version: version),
          ),
        );
      }
    }
    // A current version no message carries (a restore writes none).
    if (liveIndex == null && state.queue.isNotEmpty && currentVersion > 0) {
      items.addAll(current());
    }
    // C3's one quiet line under the last turn, in the words the arrangement's
    // own corpus-mode block uses. The title carries "Not personal yet"; this
    // is the explanation that goes with it.
    if (state.session.notPersonal) items.add(const _NotPersonalLine());
    if (state.sending) {
      items.add(WorkingCassette(caseColor: _hasTape(state) ? colour : null));
    }

    return _list(items, pinnedFrom: pinnedFrom);
  }

  /// Where the latest exchange starts: the last thing the listener said.
  static int? _lastUserIndex(ChatState state) {
    for (var i = state.messages.length - 1; i >= 0; i--) {
      final message = state.messages[i];
      if (!message.isError && message.message.role == 'user') return i;
    }
    return null;
  }

  /// The transcript list: no repaint boundary per turn, so each one repaints
  /// as it scrolls and [LyricFade] can fade it; the top fades out under the
  /// header. Items from [pinnedFrom] on — the latest exchange, with the
  /// working cassette or a failed line — stay at full ink.
  Widget _list(List<Widget> items, {int? pinnedFrom}) {
    return ShaderMask(
      key: const Key('chat-transcript-mask'),
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: const [Color(0x00000000), Color(0xFF000000)],
        stops: [0, (_topFade / rect.height).clamp(0.0, 1.0)],
      ).createShader(rect),
      child: ListView.builder(
        controller: _scrollController,
        addRepaintBoundaries: false,
        padding: EdgeInsets.fromLTRB(
          _lyricSidePadding,
          _topFade,
          _lyricSidePadding,
          _panelHeight + 16,
        ),
        itemCount: items.length,
        itemBuilder: (context, index) => LyricFade(
          bottomInset: _panelHeight,
          pinned: pinnedFrom != null && index >= pinnedFrom,
          child: Padding(
            padding: EdgeInsets.only(top: index == 0 ? 0 : _lyricGap),
            child: items[index],
          ),
        ),
      ),
    );
  }

  /// `.lyr { padding: 0 22px; gap: 16px }`, and the top fade's depth.
  static const double _lyricSidePadding = 22;
  static const double _lyricGap = 16;
  static const double _topFade = 36;

  Widget _turn(ChatState state, int i, {required bool busy}) {
    final message = state.messages[i];
    final precedingText = message.isError
        ? _precedingUserText(state.messages, i)
        : '';
    return LyricTurn(
      text: message.message.content,
      kind: message.isError
          ? ConversationTurnKind.error
          : (message.message.role == 'user'
                ? ConversationTurnKind.user
                : ConversationTurnKind.dj),
      onResend: message.isError && precedingText.isNotEmpty
          ? () => _send(precedingText)
          : null,
      resendEnabled: !busy,
    );
  }

  /// An album session's transcript (board A2 to A8, F1 to F3): the album
  /// card where the tape card would be, each passed-over pick as a muted
  /// row after the reply that offered it (so above the turn that replaced
  /// it), and the honest failure's refinement pills under the last reply.
  Widget _albumTranscript(ChatState state, {required bool busy}) {
    final pickState = state.pickState;
    final pick = pickState?.pick;
    final currentVersion = state.queueVersion;
    final notifier = ref.read(chatProvider(widget.sessionId).notifier);

    int? cardIndex;
    int? lastDjIndex;
    for (var i = state.messages.length - 1; i >= 0; i--) {
      final message = state.messages[i];
      if (cardIndex == null && message.message.queueVersion == currentVersion) {
        cardIndex = i;
      }
      if (lastDjIndex == null &&
          !message.isError &&
          message.message.role != 'user') {
        lastDjIndex = i;
      }
    }

    // Passed picks by the version they were the pick in; those whose reply
    // is not in the transcript (a "Pick this" swap writes no message) go
    // directly above the current card instead.
    final versions = {
      for (final m in state.messages)
        if (m.message.queueVersion != null) m.message.queueVersion!,
    };
    final passedByVersion = <int, List<AlbumPick>>{};
    final orphans = <AlbumPick>[];
    for (final album in pickState?.passed ?? const <AlbumPick>[]) {
      if (versions.contains(album.version) && album.version != currentVersion) {
        passedByVersion.putIfAbsent(album.version, () => []).add(album);
      } else {
        orphans.add(album);
      }
    }
    final goBack = busy ? null : (int version) => notifier.goBack(version);
    Widget passedRow(AlbumPick album) =>
        PassedOverRow(album: album, onGoBack: goBack);

    List<Widget> card() => [
      ...orphans.map(passedRow),
      if (pick != null)
        AlbumCard(
          pick: pick,
          runnersUp: pickState!.runnersUp,
          enabled: !busy,
          onToggleListenLater: notifier.toggleListenLater,
          onPick: (id) => notifier.choosePick(id),
        ),
    ];

    final suggestions = state.suggestions;
    Widget pills() => Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 4),
      child: Wrap(
        key: const Key('album-suggestions'),
        spacing: 8,
        children: [
          for (final suggestion in suggestions!)
            IdeaPill(
              label: suggestion,
              onPressed: busy ? null : () => _takeSuggestion(suggestion),
            ),
        ],
      ),
    );

    final seenVersions = <int>{};
    final lastUser = _lastUserIndex(state);
    int? pinnedFrom;
    final items = <Widget>[];
    for (var i = 0; i < state.messages.length; i++) {
      if (i == lastUser) pinnedFrom = items.length;
      items.add(_turn(state, i, busy: busy));
      final version = state.messages[i].message.queueVersion;
      if (i == cardIndex) {
        items.addAll(card());
      } else if (version != null && seenVersions.add(version)) {
        items.addAll((passedByVersion[version] ?? const []).map(passedRow));
      }
      if (i == lastDjIndex && suggestions != null && suggestions.isNotEmpty) {
        items.add(pills());
      }
    }
    if (cardIndex == null) items.addAll(card());
    if (lastDjIndex == null && suggestions != null && suggestions.isNotEmpty) {
      items.add(pills());
    }
    if (state.sending) {
      items.add(
        const WorkingCassette(
          captionText: WorkingCassette.albumCaption,
          announcementText: WorkingCassette.albumAnnouncement,
        ),
      );
    }
    return _list(items, pinnedFrom: pinnedFrom);
  }

  /// A refinement pill is the next turn in its own words; "Add my music"
  /// is the one that leaves, for the Library tab (board F2).
  void _takeSuggestion(String suggestion) {
    if (suggestion == 'Add my music') {
      ref.read(selectedTabProvider.notifier).selectTab(AppTab.library);
      Navigator.of(context).popUntil((route) => route.isFirst);
      return;
    }
    _send(suggestion);
  }

  /// The bottom panel, top to bottom: the tape strip once a mix exists, any
  /// attached playlist (with its locked states), then + beside the composer.
  /// There is no attachment row and no action row: Play lives on the strip,
  /// everything that used to sit beside the composer lives behind +.
  Widget _panel({
    required ChatState? state,
    required SessionPlaylistContextState inspiration,
    required bool busy,
  }) {
    final tokens = context.tokens;
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    // Over the keyboard when it is up; otherwise clear of the home
    // indicator. No dock inside a mix, so nothing else to clear.
    final bottom = keyboard > 0 ? keyboard : media.padding.bottom + 8;
    final enabled = state != null && !busy;
    final status = _inspirationStatus(inspiration);
    final album = state?.kind == SessionKind.album;
    final attached = inspiration.seed?.playlistId != null;
    final showStatus =
        state != null &&
        status != null &&
        // Nothing attached and nothing wrong: nothing to say.
        (attached || _canReloadInspiration(inspiration));

    return ConstrainedBox(
      // At 200% text with the keyboard up the panel wants more room than the
      // phone has; capped here, its content scrolls inside instead of
      // climbing off the top of the screen.
      constraints: BoxConstraints(
        maxHeight: (media.size.height - media.padding.top).clamp(
          0.0,
          double.infinity,
        ),
      ),
      child: LiquidGlassSurface(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(_panelRadius),
        ),
        fallbackBlurSigma: 30,
        fallbackTint: tokens.panel,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            HomePanel.sidePadding,
            10,
            HomePanel.sidePadding,
            bottom,
          ),
          // The panel's own overflow is its own business: a scroll in here
          // must not move the transcript.
          child: NotificationListener<ScrollNotification>(
            onNotification: (_) => true,
            child: SingleChildScrollView(
              reverse: true,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (state != null && !album && state.queue.isNotEmpty)
                    _strip(state),
                  if (state != null && attached)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: _inspirationChip(inspiration, enabled: enabled),
                      ),
                    ),
                  if (showStatus)
                    Padding(
                      padding: const EdgeInsets.only(left: 2, bottom: 6),
                      // A Wrap, not a Row: at 200% text the message and the
                      // action do not fit on one line, and each needs the
                      // whole width to wrap into.
                      child: Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            status,
                            key: const Key('inspiration-status'),
                            style: tokens.meta.copyWith(color: tokens.muted),
                          ),
                          // A selection that cannot be read is a READ
                          // failure: the way out is another read, never a
                          // write against a revision we do not have.
                          if (_canReloadInspiration(inspiration))
                            TextAction(
                              key: const Key('inspiration-reload'),
                              label: 'Reload inspiration',
                              quiet: true,
                              onPressed:
                                  inspiration.loading || inspiration.writing
                                  ? null
                                  : () => ref
                                        .read(
                                          sessionPlaylistContextProvider(
                                            widget.sessionId,
                                          ).notifier,
                                        )
                                        .refresh(),
                            ),
                        ],
                      ),
                    ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: _PlusButton(
                          onPressed: enabled
                              ? (anchor) => _plusMenu(anchor, state)
                              : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: MixPromptInput(
                          key: _composerKey,
                          controller: _textController,
                          focusNode: _promptFocus,
                          busy: !enabled,
                          // An album session's composer suggests the
                          // refinements once there is a pick (board A2),
                          // else asks for more; a mix asks for a change once
                          // there is one.
                          placeholder: album
                              ? (state?.pickState?.pick != null
                                    ? 'Another? Older? Something you do not know?'
                                    : 'Tell the DJ more…')
                              : (state != null && state.queue.isNotEmpty
                                    ? 'Ask for a change…'
                                    : null),
                          onSubmit: () =>
                              _send(_textController.text, fromComposer: true),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// `.bp { border-radius: 26px 26px 0 0 }`.
  static const double _panelRadius = 26;

  /// The tape strip. Play stays live while the DJ works on the next version:
  /// the current arrangement stays playable, as locked, and a reply that
  /// changes it arrives as a new state anyway.
  Widget _strip(ChatState state) {
    const keys = MixHandoffKeys.conversation;
    return TapeStrip(
      title: state.session.title,
      version: state.queueVersion,
      songs: state.queue.length,
      caseColor: _tapeColour(state),
      onOpen: _openArrangement,
      reason: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: MixPlayReason(keys: keys, queue: state.queue),
      ),
      play: ({required bool expand}) => MixSplitPlay(
        keys: keys,
        queue: state.queue,
        enabled: true,
        expand: expand,
        isPlayingThisMix: isPlayingThisMix,
        onPlay: (destination) => playAt(destination, state, state.queue),
        onOpenNowPlaying: openNowPlaying,
        onShare: (buttonContext) => shareToTransferTool(
          buttonContext,
          state.queue,
          state.session.title,
        ),
        sendingToMusic: sendingToMusic,
        sharing: sharingMix,
      ),
    );
  }

  /// The + menu: "Start from a playlist" always, and before the first mix
  /// "Shape the energy" too (an album has no energy line to shape).
  Future<void> _plusMenu(BuildContext anchor, ChatState? state) async {
    final shapeable =
        state != null &&
        state.kind != SessionKind.album &&
        state.queue.isEmpty &&
        state.queueVersion == 0;
    final inspiration = ref.read(
      sessionPlaylistContextProvider(widget.sessionId),
    );
    final choice = await showMixtapeMenu<String>(
      anchor,
      actions: [
        MixtapeMenuAction(
          key: const Key('chat-plus-playlist'),
          value: 'playlist',
          label: 'Start from a playlist',
          enabled: inspiration.canSelect,
        ),
        if (shapeable)
          const MixtapeMenuAction(
            key: Key('chat-plus-shape'),
            value: 'shape',
            label: 'Shape the energy',
            subtitle: 'Steady, build, wind down…',
          ),
      ],
    );
    if (!mounted || choice == null) return;
    if (choice == 'playlist') return _pickInspiration();
    if (choice == 'shape' && anchor.mounted) {
      // The shape menu opens from + too, applying the pick at once: the
      // sentence goes into the draft (nothing is sent) with the shipped
      // toast, or comes out again on Clear.
      final messenger = ScaffoldMessenger.of(context);
      await showEnergyShapeMenu(
        anchor,
        controller: _textController,
        selected: _shapeInDraft(),
        onChanged: (arc) {
          final next = arc == null
              ? _textController.text.replaceAll(_shapeSentence, '').trim()
              : energyBrief(_textController.text, arc);
          if (next == null) return;
          _textController.value = TextEditingValue(
            text: next,
            selection: TextSelection.collapsed(offset: next.length),
          );
          if (arc != null) {
            messenger.showSnackBar(
              mixtapeSnackBar(message: energyShapeToast),
            );
          }
        },
      );
    }
  }

  /// The energy sentence [energyBrief] writes into a draft.
  static final RegExp _shapeSentence = RegExp(
    r'(?:^|\n)Energy journey: (?:Steady|Build gradually|Wind down|Build, then settle)\.(?=\n|$)',
  );

  /// The shape the draft already asks for, so the menu ticks it.
  EnergyArc? _shapeInDraft() {
    final match = _shapeSentence.firstMatch(_textController.text);
    if (match == null) return null;
    final said = match.group(0)!.trim();
    for (final arc in EnergyArc.values) {
      if (said == 'Energy journey: ${arc.label}.') return arc;
    }
    return null;
  }

  /// The attached playlist's chip, with Replace and Detach as locked.
  Widget _inspirationChip(
    SessionPlaylistContextState inspiration, {
    required bool enabled,
  }) {
    final canWrite = enabled && inspiration.canSelect;
    return InspirationChip(
      name: inspiration.seed?.name ?? 'Unavailable playlist',
      tone: _chipTone(inspiration),
      onPick: canWrite ? _pickInspiration : null,
      onDetach: canWrite
          ? () => ref
                .read(sessionPlaylistContextProvider(widget.sessionId).notifier)
                .select(playlistId: null)
          : null,
    );
  }

  /// This mix's title before its own transcript has loaded: the summary the
  /// Mixes list already holds. Null when this conversation was opened
  /// without that list ever being read.
  String? _knownTitle() {
    final summaries = ref.watch(sessionsProvider).value;
    final match = summaries
        ?.where((session) => session.id == widget.sessionId)
        .firstOrNull;
    final title = match?.title.trim();
    return (title == null || title.isEmpty) ? null : title;
  }

  /// The text of the nearest USER message before [index] — that's the turn an
  /// error turn at [index] answers, and what "resend" means.
  String _precedingUserText(List<ChatMessage> messages, int index) {
    for (var i = index - 1; i >= 0; i--) {
      if (messages[i].message.role == 'user') {
        return messages[i].message.content;
      }
    }
    return '';
  }
}

/// The header: Back on the left, the title (with the corpus-mode subtitle
/// under it), one More on the right — each button its own glass circle.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.notPersonal,
    required this.onBack,
    required this.onMore,
  });

  final String title;
  final bool notPersonal;
  final VoidCallback onBack;
  final Future<void> Function(BuildContext anchor)? onMore;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Row(
        children: [
          GlassCluster(
            children: [
              GlassButton(
                key: const Key('chat-back'),
                icon: Icons.arrow_back_ios_new,
                label: 'Back to Mixes',
                onPressed: onBack,
              ),
            ],
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    // The header title shrinks at large sizes rather than
                    // crowding the buttons.
                    textScaler: MediaQuery.textScalerOf(
                      context,
                    ).clamp(maxScaleFactor: 1.3),
                    style: tokens.smallTitle,
                  ),
                  if (notPersonal)
                    Text(
                      'Not personal yet',
                      key: const Key('chat-not-personal'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: tokens.meta.copyWith(color: tokens.muted),
                    ),
                ],
              ),
            ),
          ),
          GlassCluster(
            children: [
              Builder(
                builder: (anchor) => GlassButton(
                  key: const Key('chat-actions'),
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

/// `.plus`: the 44 pt round button beside the composer that opens the +
/// menu, anchored to itself.
class _PlusButton extends StatelessWidget {
  const _PlusButton({required this.onPressed});

  final void Function(BuildContext anchor)? onPressed;

  static const Key buttonKey = Key('chat-plus');

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final enabled = onPressed != null;
    return Builder(
      builder: (anchor) => Semantics(
        button: true,
        enabled: enabled,
        label: 'Add',
        onTap: enabled ? () => onPressed!(anchor) : null,
        excludeSemantics: true,
        child: GestureDetector(
          key: buttonKey,
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? () => onPressed!(anchor) : null,
          child: Opacity(
            opacity: enabled ? 1 : 0.5,
            child: Container(
              width: MixtapeMetrics.minTarget,
              height: MixtapeMetrics.minTarget,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: tokens.field,
                border: Border.all(color: tokens.hairline),
              ),
              child: Icon(Icons.add_rounded, size: 22, color: tokens.plum),
            ),
          ),
        ),
      ),
    );
  }
}

/// F2: the transcript's own loading state. The chrome and the panel are
/// already drawn around it, so nothing pops in when the turns resolve.
class _SkeletonTurns extends StatelessWidget {
  const _SkeletonTurns({this.title});

  /// Announced as "Opening <title>" when the Mixes list already knows it.
  final String? title;

  static const Key skeletonKey = Key('chat-skeleton');

  /// Alignment and height of each placeholder turn, as the board draws them.
  static const List<(bool, double)> _rows = [
    (true, 20),
    (false, 44),
    (false, 44),
    (true, 20),
    (false, 44),
  ];

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Semantics(
      key: skeletonKey,
      container: true,
      liveRegion: true,
      label: title == null ? 'Opening this mix' : 'Opening $title',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          MixtapeMetrics.screenSidePadding,
          10,
          MixtapeMetrics.screenSidePadding,
          10,
        ),
        children: [
          for (final (mine, height) in _rows)
            Align(
              alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
              child: FractionallySizedBox(
                alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                widthFactor: mine ? 0.5 : 0.7,
                child: Container(
                  height: height,
                  margin: const EdgeInsets.symmetric(vertical: 5),
                  decoration: BoxDecoration(
                    color: tokens.hairline,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// F3: only when there is nothing to show at all. Back still works.
class _CouldNotOpen extends StatelessWidget {
  const _CouldNotOpen({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 36, color: tokens.errInk),
            const SizedBox(height: 14),
            Text(
              "Couldn't open this mix",
              textAlign: TextAlign.center,
              style: tokens.section,
            ),
            const SizedBox(height: 6),
            Text(
              'Check your connection and try again. Nothing here has been lost.',
              textAlign: TextAlign.center,
              style: tokens.secondary,
            ),
            const SizedBox(height: 12),
            KeyedSubtree(
              key: const Key('chat-retry'),
              child: TapeButton(label: 'Try again', onPressed: onRetry),
            ),
          ],
        ),
      ),
    );
  }
}

/// The rename alert. The controller belongs to the dialog rather than the
/// caller so it outlives the route's own exit transition — a controller
/// disposed the moment `showDialog` returns is still being read by the
/// fading-out field.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.title, required this.heading});

  final String title;
  final String heading;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.title)
        ..selection = TextSelection(
          baseOffset: 0,
          extentOffset: widget.title.length,
        );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoAlertDialog(
    title: Text(widget.heading),
    content: Padding(
      padding: const EdgeInsets.only(top: 14),
      child: CupertinoTextField(
        key: const Key('chat-rename-field'),
        controller: _controller,
        autofocus: true,
        onSubmitted: (value) => Navigator.of(context).pop(value),
        placeholder: 'Mix name',
      ),
    ),
    actions: [
      CupertinoDialogAction(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      CupertinoDialogAction(
        key: const Key('chat-rename-confirm'),
        isDefaultAction: true,
        onPressed: () => Navigator.of(context).pop(_controller.text),
        child: const Text('Save'),
      ),
    ],
  );
}

/// C3's explanatory line for a Spotify listener before their import lands:
/// the mix came from the shared catalog and the interview, not their plays.
/// Live so a screen reader hears it when a turn flips the flag.
class _NotPersonalLine extends StatelessWidget {
  const _NotPersonalLine();

  static const Key lineKey = Key('chat-not-personal-line');

  static const String copy =
      "Built from Mixtape's catalog and your interview, not your listening. "
      'Import your Spotify data for the real thing.';

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Semantics(
      key: lineKey,
      container: true,
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.only(left: 2, top: 6, bottom: 4),
        child: Text(copy, style: tokens.meta.copyWith(color: tokens.muted)),
      ),
    );
  }
}
