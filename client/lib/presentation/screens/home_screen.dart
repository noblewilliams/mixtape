import '../widgets/routine_suggestions.dart';
import 'playback_screen.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/api/api_client.dart';
import '../../data/dj/dj_api.dart';
import '../../data/dj/dj_models.dart';
import '../../data/files/opened_archive_channel.dart';
import '../../data/listening/listening_models.dart';
import '../format/import_format.dart';
import '../format/relative_time.dart';
import '../widgets/mix_home_row.dart';
import '../widgets/mix_prompt_input.dart';
import '../format/source_labels.dart';
import '../providers/auth_provider.dart';
import '../providers/dj_providers.dart';
import '../providers/library_sync_provider.dart';
import '../providers/listening_import_provider.dart';
import '../providers/onboarding_provider.dart';
import '../providers/opened_archive_provider.dart';
import 'chat_screen.dart';
import 'account_screen.dart';
import '../../data/playlists/playlist_models.dart';
import '../../data/playlists/playlist_context_models.dart';
import '../widgets/playlist_inspiration.dart';
import '../providers/new_mix_inspiration_provider.dart';
import 'import_sheet.dart';
import 'interview_screen.dart';
import 'memory_screen.dart';
import 'music_sources_screen.dart';
import 'spotify_request_screen.dart';

const _archiveFailedMessage = "couldn't archive — try again";
const _unarchiveFailedMessage = "couldn't unarchive — try again";
const _refreshFailedMessage = "couldn't refresh — showing what we had";

const _genericStartErrorMessage = 'something went wrong on our end — try again';
const _offlineStartErrorMessage =
    "couldn't reach the DJ — check your connection and try again";

/// Sessions-first Home (see
/// `docs/superpowers/plans/2026-08-29-p3b-dj-client.md` Task 6): a one-shot
/// prompt that starts a new DJ session via [sessionStarterProvider], and the
/// list of existing sessions (from [sessionsProvider]) below it. Library
/// sync (P1) moved out of the body into an AppBar action — same
/// [librarySyncProvider]-driven UI, now presented in a bottom sheet.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key, this.initialPlaylist});

  final PlaylistSummary? initialPlaylist;

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _promptController = TextEditingController();
  final _composerKey = GlobalKey();
  bool _starting = false;
  String? _error;
  bool _showArchived = false;
  PlaylistSummary? get _inspiration =>
      ref.read(newMixInspirationProvider)?.playlist;
  bool get _excludeSourceTracks =>
      ref.read(newMixInspirationProvider)?.seed.excludeSourceTracks ?? false;

  @override
  void initState() {
    super.initState();
    if (widget.initialPlaylist != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref
              .read(newMixInspirationProvider.notifier)
              .select(widget.initialPlaylist!);
        }
      });
    }
  }

  Future<void> _pickInspiration(BuildContext anchor) async {
    if (_starting) return;
    final box =
        _composerKey.currentContext?.findRenderObject() as RenderBox? ??
        anchor.findRenderObject() as RenderBox;
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
      selected: _inspiration == null
          ? null
          : InitialPlaylistSeed(
              playlistId: _inspiration!.id,
              excludeSourceTracks: _excludeSourceTracks,
            ),
    );
    if (!mounted || choice == null) return;
    ref
        .read(newMixInspirationProvider.notifier)
        .select(
          choice.playlist,
          excludeSourceTracks: choice.excludeSourceTracks,
        );
  }

  /// C5 bookkeeping: the handed archive this screen has already acted on, so
  /// an unrelated rebuild does not open the sheet over and over; and whether
  /// one is already on its way to being opened this frame.
  HandedArchive? _handled;
  bool _openingHandedArchive = false;

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  /// Guarded by [_starting] so a second tap while the first create is still
  /// in flight (these calls run 20-40s) can never mint a second session.
  Future<void> _submit({String? suggestedPrompt}) async {
    if (_starting) return;
    final prompt = suggestedPrompt ?? _promptController.text.trim();
    if (prompt.isEmpty) return;

    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final sessionId = await ref.read(sessionStarterProvider)(
        prompt,
        playlistSeed: suggestedPrompt != null || _inspiration == null
            ? null
            : InitialPlaylistSeed(
                playlistId: _inspiration!.id,
                excludeSourceTracks: _excludeSourceTracks,
              ),
      );
      if (!mounted) return;
      _promptController.clear();
      ref.read(newMixInspirationProvider.notifier).clear();
      _navigateToChat(sessionId);
    } on DjApiException catch (e) {
      if (!mounted) return;
      final sessionId = e.sessionId;
      if (sessionId != null) {
        // The session row persisted despite the turn failing — Home's job
        // is done; ChatScreen owns showing the error/retry affordance
        // (seeded from e.message via initialError, since the failed turn
        // never made it into the transcript itself).
        _promptController.clear();
        ref.read(newMixInspirationProvider.notifier).clear();
        _navigateToChat(sessionId, initialError: e.message);
      } else {
        setState(() => _error = e.message);
      }
    } on StaleQueueException {
      // Defensive only: DjApi's doc comment lists this among its four exit
      // types, but createSession can never actually throw it in practice
      // (only queue-ops does) — kept for symmetry with the other three,
      // mapped to the same generic message as a plain ApiException.
      if (!mounted) return;
      setState(() => _error = _genericStartErrorMessage);
    } on NetworkException {
      if (!mounted) return;
      setState(() => _error = _offlineStartErrorMessage);
    } on ApiException {
      if (!mounted) return;
      setState(() => _error = _genericStartErrorMessage);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _navigateToChat(String sessionId, {String? initialError}) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) =>
                ChatScreen(sessionId: sessionId, initialError: initialError),
          ),
        )
        // Sessions can change while ChatScreen owns the screen (a fresh
        // session just created, an archive/status change on the way in) —
        // refresh on return rather than leaving the list stale until some
        // unrelated rebuild happens to refetch it.
        .then((_) {
          if (!mounted) return;
          ref.read(sessionsProvider.notifier).refresh();
        });
  }

  Future<void> _openHomeActions(
    BuildContext anchor,
    bool waiting,
    bool syncing,
  ) async {
    final button = anchor.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    final rect = Rect.fromPoints(
      button.localToGlobal(Offset.zero, ancestor: overlay),
      button.localToGlobal(
        button.size.bottomRight(Offset.zero),
        ancestor: overlay,
      ),
    );
    // Use a fixed anchor: signing out can replace Home during menu dismissal.
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
      items: [
        const PopupMenuItem(
          value: 'memories',
          key: Key('memories-action'),
          child: Text('What the DJ knows'),
        ),
        const PopupMenuItem(
          value: 'sources',
          key: Key('sources-action'),
          child: Text('Your music'),
        ),
        const PopupMenuItem(
          value: 'spotify-import',
          key: Key('spotify-import-action'),
          child: Text('Add Spotify music'),
        ),
        PopupMenuItem(
          value: 'sync',
          key: const Key('sync-action'),
          child: Text(syncing ? 'Syncing library…' : 'Sync library'),
        ),
        if (waiting)
          const PopupMenuItem(
            value: 'setup',
            key: Key('music-setup-action'),
            child: Text('Music setup'),
          ),
        const PopupMenuItem(
          value: 'account',
          key: Key('account-action'),
          child: Text('Account'),
        ),
        const PopupMenuItem(
          value: 'logout',
          key: Key('logout-action'),
          child: Text('Sign out'),
        ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case 'account':
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const AccountScreen()));
      case 'memories':
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const MemoryScreen()));
      case 'sources':
        _openSources();
      case 'spotify-import':
        Navigator.of(context)
            .push(
              MaterialPageRoute(builder: (_) => const SpotifyRequestScreen()),
            )
            .then((_) {
              if (mounted) ref.read(onboardingProvider.notifier).refresh();
            });
      case 'sync':
        _openSyncSheet();
      case 'setup':
        _openMusicSetup();
      case 'logout':
        ref.read(authProvider.notifier).signOut();
    }
  }

  void _openMusicSetup() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => Consumer(
        builder: (context, ref, _) {
          final onboarding = ref.watch(onboardingProvider).value;
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: onboarding == null
                  ? const Text('Couldn’t load music setup. Try again.')
                  : _SpotifyWaitingCard(
                      onboarding: onboarding,
                      onOpenRequest: _openRequestScreen,
                      onOpenInterview: _openInterview,
                      onChooseZip: _openImportSheet,
                    ),
            ),
          );
        },
      ),
    );
  }

  void _openSyncSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _LibrarySyncSheet(),
    );
  }

  void _openRequestScreen() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SpotifyRequestScreen()))
    // "I've requested it" refreshes on its own; this covers a listener
    // who comes back after the server learned of it another way.
    .then((_) {
      if (!mounted) return;
      ref.read(onboardingProvider.notifier).refresh();
    });
  }

  void _openInterview() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const InterviewScreen()))
    // The server records interview_completed; the card reads it back.
    .then((_) {
      if (!mounted) return;
      ref.read(onboardingProvider.notifier).refresh();
    });
  }

  void _openSources() {
    ref.read(onboardingProvider.notifier).refresh();
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const MusicSourcesScreen()))
    // An import or a removal over there changes what the card says.
    .then((_) {
      if (!mounted) return;
      ref.read(onboardingProvider.notifier).refresh();
    });
  }

  /// "Choose a ZIP": the sheet opens over Home and the picker comes up at
  /// once (or the run in progress shows where it got to).
  Future<void> _openImportSheet() => openImportFlow(context, ref);

  /// A ZIP handed to the app from Files or Mail (C5). Home is the only
  /// screen that pushes routes, so the flow opens from here: for a cold
  /// start (the archive was already waiting when Home mounted) and for a
  /// file opened while the app runs. Post-frame because both paths can land
  /// during a build, and guarded so a rebuild in between cannot schedule it
  /// twice.
  void _scheduleHandedArchive() {
    if (_openingHandedArchive) return;
    _openingHandedArchive = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openingHandedArchive = false;
      _openHandedArchive();
    });
  }

  void _openHandedArchive() {
    if (!mounted) return;
    final handedOver = ref.read(openedArchiveProvider);
    if (handedOver == null) return;
    final state = ref.read(listeningImportProvider);
    // A run in flight is never reset (the re-entry rule), and a run that has
    // landed on a result nobody has read is not thrown away for the new file
    // either: the result screen offers it with "Import it". Only a flow with
    // nothing on it starts the handed file by itself.
    if (state is ImportIdle || state is ImportFlowCancelled) {
      startHandedArchive(ref, handedOver);
    }
    // One sheet only, wherever it was opened from: a file opened over an
    // open sheet re-renders it from the provider rather than stacking a
    // second one. A sheet opened over an upload is locked until it lands.
    if (!importSheetShowing) {
      unawaited(
        showImportSheet(context, dismissible: state is! ImportUploading),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(newMixInspirationProvider);
    final sessionsAsync = ref.watch(sessionsProvider);
    final sync = ref.watch(librarySyncProvider);
    // The Spotify waiting state, until the import lands. Apple listeners
    // (and anyone whose onboarding cannot be read) see Home exactly as before.
    // The card stays until both packages have landed: the first import is
    // half the data, and the nudge for the other half lives here.
    final onboarding = ref.watch(onboardingProvider).value;
    // C5: a ZIP handed to the app from Files or Mail, and the run that may
    // have to end first. The import state is listened to rather than watched
    // so an upload's progress ticks do not rebuild Home.
    final handedArchive = ref.watch(openedArchiveProvider);
    ref.listen(listeningImportProvider, (previous, next) {
      // A run ending is the one moment a file that had to wait is worth
      // another look — the result it waited for now has somewhere to offer
      // it from. Nothing else that rebuilds Home is: [_handled] is left
      // alone, so a sheet the listener put away stays away.
      if ((previous?.inProgress ?? false) && !next.inProgress) {
        _scheduleHandedArchive();
      }
    });
    if (handedArchive != null && handedArchive != _handled) {
      _handled = handedArchive;
      _scheduleHandedArchive();
    }
    final waiting =
        onboarding != null &&
        onboarding.chosenService == 'spotify' &&
        spotifyPackages(onboarding).count < 2 &&
        !(spotifySource(onboarding)?.packages.contains('spotify_exportify') ??
            false);

    return Scaffold(
      appBar: AppBar(
        title: const Text('mixtape'),
        automaticallyImplyLeading: false,
        actions: [
          Builder(
            builder: (anchor) => IconButton(
              key: const Key('home-actions'),
              tooltip: 'Home actions',
              icon: const Icon(Icons.more_horiz),
              onPressed: () =>
                  _openHomeActions(anchor, waiting, sync is SyncRunning),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _refreshSessions,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const PlaybackMini(),
                      RoutineSuggestions(busy: _starting, onCreate: (prompt) => _submit(suggestedPrompt: prompt)),
                      MixPromptInput(
                        key: _composerKey,
                        controller: _promptController,
                        busy: _starting,
                        onSubmit: _submit,
                        attachment: _inspiration == null
                            ? null
                            : Builder(
                                builder: (anchor) =>
                                    PlaylistInspirationAttachment(
                                      name: _inspiration!.name,
                                      busy: _starting,
                                      onPick: () => _pickInspiration(anchor),
                                      onDetach: () => ref
                                          .read(
                                            newMixInspirationProvider.notifier,
                                          )
                                          .clear(),
                                    ),
                              ),
                      ),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            _error!,
                            key: const Key('start-error'),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Wrap(
                    children: [
                      Semantics(
                        selected: !_showArchived,
                        child: TextButton(
                          key: const Key('active-mixes'),
                          onPressed: () =>
                              setState(() => _showArchived = false),
                          child: Text(
                            'Active mixes',
                            style: TextStyle(
                              fontWeight: !_showArchived
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                      ),
                      Semantics(
                        selected: _showArchived,
                        child: TextButton(
                          key: const Key('archived-mixes'),
                          onPressed: () => setState(() => _showArchived = true),
                          child: Text(
                            'Archived mixes',
                            style: TextStyle(
                              fontWeight: _showArchived
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                _buildSessionsBody(sessionsAsync),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _refreshSessions() async {
    final ok = await ref.read(sessionsProvider.notifier).refresh();
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text(_refreshFailedMessage)));
    }
  }

  /// Mirrors ChatScreen's `hasError && !hasValue` pattern (see
  /// chat_screen.dart's build() comment): only fall back to the full-screen
  /// error+retry state when there's truly nothing else to show. A failed
  /// background refresh with a previously-good list on hand keeps showing
  /// that list rather than blanking it out — the RefreshIndicator wrapping
  /// it gives manual pull-to-refresh, and refresh() itself never throws
  /// (AsyncValue.guard-wrapped), so this never leaks an unhandled error.
  Widget _buildSessionsBody(AsyncValue<List<DjSession>> sessionsAsync) {
    if (sessionsAsync.hasError && !sessionsAsync.hasValue) {
      // invalidate (not refresh()) here specifically: reaching this branch
      // means build() itself just failed, which per chat_screen.dart's
      // build() comment leaves Riverpod's own retry backoff scheduled on
      // this element. invalidate() replaces the element outright, so that
      // pending backoff Timer is cancelled rather than left dangling —
      // refresh() would instead race it (and, in tests, trip the
      // pending-timer-at-teardown invariant).
      return _SessionsErrorState(
        onRetry: () => ref.invalidate(sessionsProvider),
      );
    }
    if (!sessionsAsync.hasValue) {
      return const Center(child: CircularProgressIndicator());
    }
    return _SessionsList(
      sessions: sessionsAsync.value!,
      showArchived: _showArchived,
      onTapSession: _navigateToChat,
    );
  }
}

/// Home's waiting state for a Spotify listener until both packages have
/// landed: the status chip, the elapsed wait since "I've requested it" (or
/// the way to the request screen) until the first package is in and the
/// nudge for the other package after, "Choose a ZIP", the interview card
/// with what it produced, and the "Not personal yet" note while nothing has
/// landed. Route pushes stay with Home via the callbacks.
class _SpotifyWaitingCard extends StatelessWidget {
  const _SpotifyWaitingCard({
    required this.onboarding,
    required this.onOpenRequest,
    required this.onOpenInterview,
    required this.onChooseZip,
  });

  final OnboardingState onboarding;
  final VoidCallback onOpenRequest;
  final VoidCallback onOpenInterview;
  final VoidCallback onChooseZip;

  String? get _nudge {
    final source = spotifySource(onboarding);
    final packages = packagesOf(source);
    if (source == null || packages.count == 0) return null;
    final when = shortDate(source.lastImportedAt ?? source.connectedAt);
    return packages.extended
        ? 'Extended history imported $when. Still waiting for the account data; check your inbox '
              'for the second email.'
        : 'Account data imported $when. Still waiting for the extended history; it can take up '
              'to 30 days.';
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final markedAt = onboarding.markedRequestedAt;
    final interviewDone = onboarding.interviewCompletedAt != null;
    final interview = onboarding.interview;
    final nudge = _nudge;
    return Card(
      key: const Key('waiting-card'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    nudge == null
                        ? 'Bring your Spotify music'
                        : 'Your Spotify data',
                    style: textTheme.titleMedium,
                  ),
                ),
                Chip(
                  key: const Key('waiting-chip'),
                  label: Text(spotifyStatusLabel(onboarding)),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (nudge != null)
              Text(
                nudge,
                key: const Key('waiting-nudge'),
                style: textTheme.bodySmall,
              )
            else
              Row(
                children: [
                  Icon(
                    markedAt == null ? Icons.mail_outline : Icons.hourglass_top,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: markedAt == null
                        ? const Text(
                            'Ready to import',
                            key: Key('waiting-not-requested'),
                          )
                        : Text(
                            'Requested ${elapsedWait(markedAt)}',
                            key: const Key('waiting-requested'),
                          ),
                  ),
                  TextButton(
                    key: const Key('open-request'),
                    onPressed: onOpenRequest,
                    child: Text('Import steps'),
                  ),
                ],
              ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonalIcon(
                key: const Key('waiting-choose-zip'),
                onPressed: onChooseZip,
                icon: const Icon(Icons.folder_zip_outlined),
                label: Text('Choose files'),
              ),
            ),
            const Divider(),
            if (interviewDone)
              ListTile(
                key: const Key('interview-done'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.check_circle_outline),
                title: const Text('Interview done'),
                subtitle: interview == null
                    ? null
                    : Text(
                        '${plural(interview.notes, 'note')}, ${plural(interview.artists, 'artist')}',
                      ),
              )
            else
              ListTile(
                key: const Key('open-interview'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.record_voice_over_outlined),
                title: const Text('Tell the DJ about your taste'),
                subtitle: const Text(
                  'Five quick questions so the first mixes have something to go on.',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: onOpenInterview,
              ),
            if (nudge == null) ...[
              const SizedBox(height: 8),
              Text(
                'Mixes before the import are labeled "Not personal yet".',
                key: const Key('not-personal-note'),
                style: textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SessionsErrorState extends StatelessWidget {
  const _SessionsErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            const Text(
              "couldn't load your sessions",
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('sessions-retry'),
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SessionsList extends ConsumerWidget {
  const _SessionsList({
    required this.sessions,
    required this.showArchived,
    required this.onTapSession,
  });
  final List<DjSession> sessions;
  final bool showArchived;
  final ValueChanged<String> onTapSession;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = showArchived
        ? archivedSessions(sessions)
        : nonArchivedSessions(sessions);
    if (visible.isEmpty) {
      return ListView(
        key: const Key('sessions-empty'),
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              showArchived
                  ? 'No archived mixes.'
                  : 'No mixes yet — tell the DJ what you want to hear.',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      );
    }
    return ListView.builder(
      key: const Key('sessions-list'),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: visible.length,
      itemBuilder: (rowContext, index) {
        final session = visible[index];
        return MixHomeRow(
          key: Key('session-${session.id}'),
          session: session,
          onOpen: () => onTapSession(session.id),
          onRename: (title) =>
              ref.read(sessionsProvider.notifier).rename(session.id, title),
          onArchive: () =>
              _setArchived(context, ref, session.id, archived: true),
          onRestore: () =>
              _setArchived(context, ref, session.id, archived: false),
        );
      },
    );
  }

  Future<bool> _setArchived(
    BuildContext context,
    WidgetRef ref,
    String id, {
    required bool archived,
  }) async {
    final notifier = ref.read(sessionsProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final ok = archived
        ? await notifier.archive(id)
        : await notifier.unarchive(id);
    if (!context.mounted || !messenger.mounted) return ok;
    messenger.hideCurrentSnackBar();
    if (!ok) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            archived ? _archiveFailedMessage : _unarchiveFailedMessage,
          ),
        ),
      );
    } else if (archived) {
      messenger.showSnackBar(
        SnackBar(
          content: const Text('Mix archived'),
          duration: const Duration(seconds: 3),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () async {
              if (!context.mounted) return;
              final restored = await ref
                  .read(sessionsProvider.notifier)
                  .unarchive(id);
              if (!restored && context.mounted && messenger.mounted) {
                messenger.showSnackBar(
                  const SnackBar(content: Text(_unarchiveFailedMessage)),
                );
              }
            },
          ),
        ),
      );
    }
    return ok;
  }
}

/// The P1 library-sync UI (unchanged), now presented from a bottom sheet
/// opened via the AppBar's sync action instead of owning Home's body.
class _LibrarySyncSheet extends ConsumerWidget {
  const _LibrarySyncSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(librarySyncProvider);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: switch (sync) {
          SyncIdle() => FilledButton(
            key: const Key('sync-library'),
            onPressed: () => ref.read(librarySyncProvider.notifier).sync(),
            child: const Text('Sync my library'),
          ),
          SyncRunning(:final progress) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: progress == 0 ? null : progress),
              const SizedBox(height: 16),
              Text(
                progress == 0
                    ? 'Syncing…'
                    : 'Syncing… ${(progress * 100).round()}%',
              ),
            ],
          ),
          SyncDone(:final summary) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Synced ${summary.songs} ${summary.songs == 1 ? 'song' : 'songs'} and '
                '${summary.playlists} ${summary.playlists == 1 ? 'playlist' : 'playlists'}. '
                'The DJ is listening.',
                textAlign: TextAlign.center,
              ),
              if (summary.unresolvedEntries > 0) ...[
                const SizedBox(height: 8),
                Text(
                  '${summary.unresolvedEntries} playlist '
                  '${summary.unresolvedEntries == 1 ? 'entry is' : 'entries are'} '
                  'still unmatched.',
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 16),
              TextButton(
                key: const Key('sync-again'),
                onPressed: () => ref.read(librarySyncProvider.notifier).sync(),
                child: const Text('Sync again'),
              ),
            ],
          ),
          SyncFailed(:final message) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              OutlinedButton(
                key: const Key('sync-retry'),
                onPressed: () => ref.read(librarySyncProvider.notifier).sync(),
                child: const Text('Try again'),
              ),
            ],
          ),
        },
      ),
    );
  }
}
