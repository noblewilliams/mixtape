import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/api/api_client.dart';
import '../../data/dj/dj_api.dart';
import '../../data/files/opened_archive_channel.dart';
import '../../data/listening/listening_models.dart';
import '../format/import_format.dart';
import '../format/relative_time.dart';
import '../theme/mixtape_theme.dart';
import '../widgets/foundation/cassette_tile.dart';
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/large_title_scaffold.dart';
import '../widgets/home_panel.dart';
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

/// The Home tab (`docs/mockups/approved/2026-09-17-mobile-shell.md` → Home;
/// `docs/mockups/approved/2026-09-17-mobile-home-states.md`; plan task 3.1).
///
/// A large title over open space with one hint line, and everything you can
/// do in a bottom panel above the dock: the composer, the start-failure line
/// and three idea pills. Starting a mix turns the cassette's hubs in the open
/// space. The mix list is the Mixes tab (task 2.3) and the old menu's
/// destinations are the Library and You tabs (task 2.2), so Home has no
/// chrome of its own beyond the title.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key, this.initialPlaylist});

  final PlaylistSummary? initialPlaylist;

  /// The board's one line of open-space copy.
  static const String hintText =
      'Say what the moment needs, tap an idea, or start from one of your '
      'playlists.';

  /// Below this much open space the hint is dropped rather than squeezed.
  static const double minHintSpace = 80;

  static const String startingTitle = 'Making your mix';
  static const String startingHint =
      'Usually under a minute. You can leave this tab; it will be waiting in '
      'Mixes.';

  /// The starting state's cassette.
  static const double startingCassetteWidth = 120;

  static const Key hintKey = Key('home-hint');
  static const Key startingKey = Key('home-starting');

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _promptController = TextEditingController();
  final _promptFocus = FocusNode();
  final _composerKey = GlobalKey();
  final _panelKey = GlobalKey();

  /// The panel's measured height, which the open space above it reserves.
  double _panelHeight = 0;
  bool _measuring = false;
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
    _promptFocus.dispose();
    super.dispose();
  }

  /// The panel is drawn outside the scroll view (it rides the keyboard and
  /// floats over the dock), so the open space cannot lay itself out against
  /// it — it is measured after the frame instead and reserved on the next.
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

  /// Guarded by [_starting] so a second tap while the first create is still
  /// in flight (these calls run 20-40s) can never mint a second session.
  Future<void> _submit() async {
    if (_starting) return;
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty) return;

    setState(() {
      _starting = true;
      _error = null;
    });
    try {
      final sessionId = await ref.read(sessionStarterProvider)(
        prompt,
        playlistSeed: _inspiration == null
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

    _measurePanel();

    return GradientBackground(
      // No app bar: the large title is Home's only chrome, and the panel is
      // laid over the scroll view rather than inside it, so the keyboard
      // carries it while the open space stays put.
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        body: Stack(
          children: [
            // The dock's inset is the panel's business, not the scroll
            // view's: left in, the title's scaffold would pad a dock the
            // panel already clears.
            MediaQuery.removePadding(
              context: context,
              removeBottom: true,
              child: LargeTitleScaffold(
                title: 'Home',
                // No pull-to-refresh on Home: there is no list to refresh.
                slivers: [
                  SliverLayoutBuilder(
                    builder: (context, constraints) {
                      final open =
                          constraints.viewportMainAxisExtent -
                          constraints.precedingScrollExtent -
                          _panelHeight;
                      return SliverToBoxAdapter(
                        child: ConstrainedBox(
                          // The open space is whatever the title and the
                          // panel leave; content taller than it scrolls, and
                          // nothing else on Home ever does.
                          constraints: BoxConstraints(
                            minHeight: open < 0 ? 0 : open,
                          ),
                          child: _openSpace(
                            context,
                            open: open,
                            waiting: waiting,
                            onboarding: onboarding,
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: KeyedSubtree(
                key: _panelKey,
                child: HomePanel(
                  composerKey: _composerKey,
                  controller: _promptController,
                  focusNode: _promptFocus,
                  busy: _starting,
                  error: _error,
                  onSubmit: _submit,
                  attachment: _inspiration == null
                      ? null
                      : Builder(
                          builder: (anchor) => PlaylistInspirationAttachment(
                            name: _inspiration!.name,
                            busy: _starting,
                            onPick: () => _pickInspiration(anchor),
                            onDetach: () => ref
                                .read(newMixInspirationProvider.notifier)
                                .clear(),
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// What the space between the title and the panel holds: the starting
  /// state, the Spotify waiting rows, or the one hint line.
  Widget _openSpace(
    BuildContext context, {
    required double open,
    required bool waiting,
    required OnboardingState? onboarding,
  }) {
    if (_starting) return const _StartingState();
    if (waiting && onboarding != null) {
      // Task 3.3 turns this into the board's two flush rows; it only moves
      // into the open space here.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SpotifyWaitingCard(
            onboarding: onboarding,
            onOpenRequest: _openRequestScreen,
            onOpenInterview: _openInterview,
            onChooseZip: _openImportSheet,
          ),
          const SizedBox(height: 16),
        ],
      );
    }
    // Squeezed by the keyboard or a tall panel, the hint goes rather than
    // crowding the composer.
    if (open < HomeScreen.minHintSpace) return const SizedBox.shrink();
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Text(
          HomeScreen.hintText,
          key: HomeScreen.hintKey,
          textAlign: TextAlign.center,
          // The board's `.hintmid`: secondary size in muted ink.
          style: context.tokens.secondary.copyWith(color: context.tokens.muted),
        ),
      ),
    );
  }
}

/// The board's starting state: the hubs turn in the open space (still under
/// reduced motion, where the text alone carries it), the duration hint says
/// where the mix will be, and the whole thing announces itself.
class _StartingState extends StatelessWidget {
  const _StartingState();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Center(
      child: Semantics(
        key: HomeScreen.startingKey,
        liveRegion: true,
        label: HomeScreen.startingTitle,
        container: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CassetteTile(
              width: HomeScreen.startingCassetteWidth,
              spinning: true,
            ),
            const SizedBox(height: 10),
            Text(HomeScreen.startingTitle, style: tokens.section),
            const SizedBox(height: 10),
            Text(
              HomeScreen.startingHint,
              textAlign: TextAlign.center,
              // `.busy`: muted around the section-weight line above it.
              style: tokens.secondary.copyWith(color: tokens.muted),
            ),
          ],
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
