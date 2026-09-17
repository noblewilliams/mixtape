import '../widgets/routine_suggestions.dart';
import 'playback_screen.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/api/api_client.dart';
import '../../data/dj/dj_api.dart';
import '../../data/files/opened_archive_channel.dart';
import '../../data/listening/listening_models.dart';
import '../format/import_format.dart';
import '../format/relative_time.dart';
import '../widgets/mix_prompt_input.dart';
import '../format/source_labels.dart';
import '../providers/dj_providers.dart';
import '../providers/listening_import_provider.dart';
import '../providers/onboarding_provider.dart';
import '../providers/opened_archive_provider.dart';
import 'chat_screen.dart';
import '../../data/playlists/playlist_models.dart';
import '../../data/playlists/playlist_context_models.dart';
import '../widgets/playlist_inspiration.dart';
import '../providers/new_mix_inspiration_provider.dart';
import 'import_sheet.dart';
import 'interview_screen.dart';
import 'spotify_request_screen.dart';

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
      // Phase 3 restyles this into the board's large title; task 2.2 only
      // takes the overflow menu away — its destinations are the Library and
      // You tabs now.
      appBar: AppBar(
        title: const Text('mixtape'),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const PlaybackMini(),
                    RoutineSuggestions(
                      busy: _starting,
                      onCreate: (prompt) => _submit(suggestedPrompt: prompt),
                    ),
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
              // Music setup for a Spotify listener, on Home until their
              // data lands. Phase 3.3 restyles it into the board's two
              // flush rows; task 2.2 only moves it out of the menu that
              // used to hold it.
              if (waiting)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: _SpotifyWaitingCard(
                    onboarding: onboarding,
                    onOpenRequest: _openRequestScreen,
                    onOpenInterview: _openInterview,
                    onChooseZip: _openImportSheet,
                  ),
                ),
            ],
          ),
        ),
      ),
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
