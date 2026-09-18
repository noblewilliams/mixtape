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

import 'dart:async';

import 'package:flutter/cupertino.dart'
    show
        CupertinoAlertDialog,
        CupertinoDialogAction,
        CupertinoTextField,
        showCupertinoDialog;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_client.dart';
import '../../data/playlists/playlist_context_models.dart';
import '../providers/dj_providers.dart';
import '../providers/auth_provider.dart';
import '../providers/library_sync_provider.dart';
import '../providers/playlist_context_provider.dart';
import '../providers/mix_operation_gate.dart';
import '../theme/mixtape_theme.dart';
import '../widgets/conversation_turn.dart';
import '../widgets/energy_journey.dart';
import '../widgets/foundation/glass_cluster.dart';
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/label_chip.dart';
import '../widgets/foundation/liquid_glass_surface.dart';
import '../widgets/foundation/tape_button.dart';
import '../widgets/foundation/text_action.dart';
import '../widgets/home_panel.dart' show HomePanel;
import '../widgets/mix_energy_summary.dart';
import '../widgets/mix_handoff.dart';
import '../widgets/mix_prompt_input.dart';
import '../widgets/playlist_inspiration.dart';
import '../widgets/queue_card.dart';
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
  Timer? _listeningTimer;
  bool _showListeningCaption = false;
  bool _seededInitialError = false;
  bool _changingStatus = false;

  @override
  String get mixSessionId => widget.sessionId;

  @override
  void showMixSnack(String message) => _snack(message);

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
    _listeningTimer?.cancel();
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

  void _startListeningTimer() {
    _showListeningCaption = false;
    _listeningTimer?.cancel();
    _listeningTimer = Timer(const Duration(seconds: 10), () {
      if (mounted) setState(() => _showListeningCaption = true);
    });
  }

  void _cancelListeningTimer() {
    _listeningTimer?.cancel();
    _listeningTimer = null;
    _showListeningCaption = false;
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
        ref.read(chatProvider(widget.sessionId)).value?.sending == true) {
      return;
    }
    if (fromComposer) _textController.clear();
    try {
      await ref.read(chatProvider(widget.sessionId).notifier).send(trimmed);
    } catch (_) {
      if (!mounted) return;
      _snack('something unexpected happened');
    }
  }

  /// Floating, 16 pt in: there is no dock on this route for a toast to clear,
  /// and the app-level [ScaffoldMessenger] builds the bar against the app's
  /// own theme, so the geometry is set here rather than in a local theme.
  void _snack(String message, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: action,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
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

  /// The board's More menu: Version history, Rename, Archive or Restore.
  Future<void> _actions(BuildContext anchor) async {
    final archived =
        ref.read(chatProvider(widget.sessionId)).value?.session.status ==
        'archived';
    final action = await showMixtapeMenu<String>(
      context,
      actions: [
        const MixtapeMenuAction(value: 'history', label: 'Version history'),
        const MixtapeMenuAction(value: 'rename', label: 'Rename'),
        MixtapeMenuAction(
          value: 'status',
          label: archived ? 'Restore' : 'Archive',
          isDestructive: !archived,
        ),
      ],
    );
    if (!mounted || action == null) return;
    if (action == 'history') return _openHistory();
    if (action == 'rename') return _rename();
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
    final current =
        ref.read(chatProvider(widget.sessionId)).value?.session.title ?? '';
    final name = await showCupertinoDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (_) => _RenameDialog(title: current),
    );
    if (!mounted || name == null || name.trim().isEmpty) return;
    final ok = await ref
        .read(chatProvider(widget.sessionId).notifier)
        .rename(name);
    if (!mounted || ok) return;
    _snack('Couldn’t rename this mix. Try again.');
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
      _snack('Couldn’t sign out. Try again.');
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
          _snack(state.transientError!);
        }
        ref.read(chatProvider(widget.sessionId).notifier).clearTransientError();
      }

      final wasSending = previous?.value?.sending ?? false;
      if (state.sending && !wasSending) {
        _startListeningTimer();
      } else if (!state.sending && wasSending) {
        _cancelListeningTimer();
      }

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
      onArrangement: _openArrangement,
      onMore: _changingStatus ? null : _actions,
      body: _transcript(state, busy: busy),
      panel: _panel(state: state, inspiration: inspiration, busy: busy),
    );
  }

  /// Chrome shared by every state: the gradient, the glass clusters, the
  /// floating SnackBars (no dock on this route, so they sit 16 pt in) and the
  /// panel floating over the transcript.
  Widget _frame({
    required String title,
    required Widget body,
    bool notPersonal = false,
    VoidCallback? onArrangement,
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
                      onArrangement: onArrangement,
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

  /// The turns, flush on the gradient, scrolled to the last one.
  Widget _transcript(ChatState state, {required bool busy}) {
    final currentVersion = state.queueVersion;

    // The LATEST message whose queueVersion matches the current one carries
    // the tape card; every OTHER version-bearing message gets a Version chip.
    int? liveQueueMessageIndex;
    for (var i = state.messages.length - 1; i >= 0; i--) {
      if (state.messages[i].message.queueVersion == currentVersion) {
        liveQueueMessageIndex = i;
        break;
      }
    }
    final needsStandaloneCard =
        liveQueueMessageIndex == null && state.queue.isNotEmpty;

    final items = <Widget>[];
    for (var i = 0; i < state.messages.length; i++) {
      final message = state.messages[i];
      // A dead resend (no preceding user turn — a synthesized transcript
      // could lack one) hides the button entirely rather than wiring it to a
      // no-op.
      final precedingText = message.isError
          ? _precedingUserText(state.messages, i)
          : '';
      items.add(
        ConversationTurn(
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
        ),
      );
      final version = message.message.queueVersion;
      if (version != null) {
        if (i == liveQueueMessageIndex) {
          // The server tags version-changed messages even when a turn EMPTIES
          // the queue — an empty tape card would be a header with nothing
          // under it, so it is skipped entirely.
          if (state.queue.isNotEmpty) items.addAll(_tapeCard(state));
        } else {
          items.add(
            _VersionChip(
              version: version,
              onOpen: () => _openHistory(version: version),
            ),
          );
        }
      }
    }
    if (needsStandaloneCard) items.addAll(_tapeCard(state));
    // C3's one quiet line under the last turn, in the words the arrangement's
    // own corpus-mode block uses. The title carries "Not personal yet"; this
    // is the explanation that goes with it.
    if (state.session.notPersonal) items.add(const _NotPersonalLine());
    if (state.sending) {
      items.add(WorkingIndicator(showCaption: _showListeningCaption));
    }

    return ListView.builder(
      controller: _scrollController,
      padding: EdgeInsets.fromLTRB(
        MixtapeMetrics.screenSidePadding,
        8,
        MixtapeMetrics.screenSidePadding,
        _panelHeight + 8,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) => items[index],
    );
  }

  /// The tape card and, under it, the energy line for the same version.
  List<Widget> _tapeCard(ChatState state) => [
    QueueCard(
      sessionId: widget.sessionId,
      queue: state.queue,
      version: state.queueVersion,
    ),
    if (state.queueVersion > 0)
      MixEnergySummary(
        sessionId: widget.sessionId,
        version: state.queueVersion,
      ),
  ];

  /// The bottom panel: the drag handle, the attachment row, the composer and
  /// the mix actions, on HomePanel's glass.
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
          top: Radius.circular(HomePanel.topRadius),
        ),
        fallbackBlurSigma: 30,
        fallbackTint: tokens.panel,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            HomePanel.sidePadding,
            8,
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
                  Center(
                    child: Container(
                      key: HomePanel.handleKey,
                      width: HomePanel.handleWidth,
                      height: HomePanel.handleHeight,
                      margin: const EdgeInsets.only(top: 2, bottom: 12),
                      decoration: const BoxDecoration(
                        color: HomePanel.handleColor,
                        borderRadius: BorderRadius.all(Radius.circular(3)),
                      ),
                    ),
                  ),
                  if (state != null) ...[
                    _attachments(inspiration, enabled: enabled),
                    if (status != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 2, bottom: 4),
                        // A Wrap, not a Row: at 200% text the message and
                        // the action do not fit on one line, and each needs
                        // the whole width to wrap into.
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
                  ],
                  // The Shape chip lives in the attachment row above; the
                  // composer itself draws none (Home's is in its title row).
                  MixPromptInput(
                    key: _composerKey,
                    controller: _textController,
                    focusNode: _promptFocus,
                    busy: !enabled,
                    onSubmit: () =>
                        _send(_textController.text, fromComposer: true),
                  ),
                  // The shared handoff row (`widgets/mix_handoff.dart`),
                  // which the arrangement draws too: a mix Apple Music
                  // cannot touch drops Play/Create and says why; anything
                  // with a Spotify id gains the transfer handoff.
                  MixActionsRow(
                    keys: MixHandoffKeys.conversation,
                    queue: state?.queue ?? const [],
                    enabled: enabled,
                    padding: const EdgeInsets.only(top: 8),
                    isPlayingThisMix: isPlayingThisMix,
                    onPlayNow: state == null
                        ? null
                        : () => playHere(state, state.queue),
                    onCreatePlaylist: state == null
                        ? null
                        : () => createPlaylist(
                            queue: state.queue,
                            defaultName: state.session.title,
                            keys: MixHandoffKeys.conversation,
                          ),
                    onSendToMusic: state == null
                        ? null
                        : () => sendToMusic(state.queue),
                    onShare: state == null
                        ? null
                        : (buttonContext) => shareToTransferTool(
                            buttonContext,
                            state.queue,
                            state.session.title,
                          ),
                    saving: savingPlaylist,
                    sendingToMusic: sendingToMusic,
                    sharing: sharingMix,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// `.attach`: the playlist chip and the Shape chip on one wrapping row.
  Widget _attachments(
    SessionPlaylistContextState inspiration, {
    required bool enabled,
  }) {
    final attached = inspiration.seed?.playlistId != null;
    final canWrite = enabled && inspiration.canSelect;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          InspirationChip(
            name: attached
                ? (inspiration.seed?.name ?? 'Unavailable playlist')
                : null,
            tone: _chipTone(inspiration),
            onPick: canWrite ? _pickInspiration : null,
            onDetach: attached && canWrite
                ? () => ref
                      .read(
                        sessionPlaylistContextProvider(
                          widget.sessionId,
                        ).notifier,
                      )
                      .select(playlistId: null)
                : null,
          ),
          LabelChip(
            key: const Key('chat-shape-chip'),
            label: 'Shape',
            hole: false,
            leading: const EnergyWave(
              arc: EnergyArc.arc,
              width: 18,
              height: 12,
            ),
            onPressed: enabled
                ? () => showEnergyShapeSheet(context, _textController)
                : null,
          ),
        ],
      ),
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

/// The board's `.navbar`: the back cluster, the centred title (with the
/// corpus-mode subtitle under it) and the Arrangement / More cluster.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.notPersonal,
    required this.onBack,
    required this.onArrangement,
    required this.onMore,
  });

  final String title;
  final bool notPersonal;
  final VoidCallback onBack;
  final VoidCallback? onArrangement;
  final Future<void> Function(BuildContext anchor)? onMore;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
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
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.smallTitle,
                  ),
                  if (notPersonal)
                    Text(
                      'Not personal yet',
                      key: const Key('chat-not-personal'),
                      textAlign: TextAlign.center,
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
              GlassButton(
                key: const Key('chat-arrangement'),
                icon: Icons.queue_music,
                label: 'Arrangement',
                onPressed: onArrangement,
              ),
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

/// `.vchip`: an earlier arrangement, opening history at that version.
class _VersionChip extends StatelessWidget {
  const _VersionChip({required this.version, required this.onOpen});

  final int version;
  final VoidCallback onOpen;

  static Key keyFor(int version) => ValueKey('version-chip-$version');

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Align(
      alignment: Alignment.centerLeft,
      child: Semantics(
        button: true,
        label: 'Version $version',
        // `excludeSemantics` drops the detector's own tap action, and a node
        // with no action cannot be activated by VoiceOver. Declare it here.
        onTap: onOpen,
        excludeSemantics: true,
        child: GestureDetector(
          key: keyFor(version),
          behavior: HitTestBehavior.opaque,
          onTap: onOpen,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: MixtapeMetrics.minTarget,
            ),
            child: Center(
              widthFactor: 1,
              child: Container(
                constraints: const BoxConstraints(minHeight: 30),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: const BoxDecoration(
                  color: Color.fromRGBO(120, 110, 120, 0.14),
                  borderRadius: BorderRadius.all(
                    Radius.circular(MixtapeMetrics.pillRadius),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.history, size: 14, color: tokens.plum),
                    const SizedBox(width: 6),
                    Text(
                      'Version $version',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: tokens.plum,
                      ),
                    ),
                  ],
                ),
              ),
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
    (true, 40),
    (false, 56),
    (false, 60),
    (true, 40),
    (false, 56),
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
                    borderRadius: mine
                        ? ConversationTurn.userRadius
                        : ConversationTurn.djRadius,
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
  const _RenameDialog({required this.title});

  final String title;

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
    title: const Text('Rename mix'),
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
