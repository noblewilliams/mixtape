/// "Add your music": one screen for both services, with the native glass
/// segmented control under the title — Apple Music | Spotify (founder, smoke
/// round four, note 4; board r4, T1).
///
/// Both panes are the same two-step checklist (board
/// `docs/mockups/2026-11-21-add-your-music-restyle-r4.html`, approved
/// 2026-11-21, over the 3 November grammar): a one-line header with the
/// service's official icon, how many of its two steps are in and a two-bar
/// meter, then the steps — Apple's "Library" and optional "Listening
/// history", Spotify's "Saved music" and optional "Listening history" — each
/// a state disc, a status line and its own actions (Sync as an icon, Import
/// again, Replace, Remove), with the request steps and the Apple file folded
/// under one row. Your music is retired; its actions live on these steps.
///
/// The Spotify pane is the September 8 Exportify approval
/// (`docs/mockups/approved/2026-09-08-exportify-import.md`) over the September
/// 4 web import record, restyled onto the September 17 shell by plan task 8.7:
/// the large title on the gradient, section words, flush rows, an inset group
/// for the deeper block, and tape/chip/text controls. The Apple pane is the
/// library sync the Library tab already offers plus the optional Apple Media
/// Services export (`docs/decisions.md`, 2026-09-04: iOS live sync is the
/// primary Apple path, the export is a "go deeper").
///
/// The class name is unchanged: the gate still shows this as its Spotify
/// request step, with "Bring your Spotify music" and the Spotify segment
/// preselected.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/listening/listening_models.dart';
import '../format/import_format.dart';
import '../format/relative_time.dart';
import '../providers/device_providers.dart';
import '../providers/library_sync_provider.dart';
import '../providers/onboarding_provider.dart';
import '../theme/mixtape_theme.dart';
import '../widgets/foundation/brand_icons.dart';
import '../widgets/foundation/glass_cluster.dart';
import '../widgets/foundation/glass_segmented_control.dart';
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/label_chip.dart';
import '../widgets/foundation/large_title_scaffold.dart';
import '../widgets/foundation/section_word.dart';
import '../widgets/foundation/segmented_toggle.dart';
import '../widgets/foundation/status_word.dart';
import '../widgets/foundation/tape_button.dart';
import '../widgets/foundation/text_action.dart';
import '../format/source_labels.dart';
import '../widgets/library_sync_dialog.dart';
import 'import_sheet.dart';
import 'music_sources_screen.dart' show removeSourceFlow;
import '../widgets/foundation/haptics.dart';

/// The address in step 1, as it reads on screen and where it opens.
const String spotifyPrivacyAddress = 'spotify.com/account/privacy';
final Uri spotifyPrivacyUrl = Uri.parse(
  'https://www.spotify.com/account/privacy/',
);

/// The same pair for Apple's own data page.
const String applePrivacyAddress = 'privacy.apple.com';
final Uri applePrivacyUrl = Uri.parse('https://privacy.apple.com/');

/// Where "Open Exportify ↗" goes.
final Uri exportifyUrl = Uri.parse('https://exportify.app/');

/// How long after "I've requested it" the inbox reminder fires.
const Duration requestReminderDelay = Duration(days: 3);

/// The quick start, one numbered row each — the copy the screen has shipped
/// since the Exportify approval, split off the single paragraph it was.
const List<String> exportifyQuickStartSteps = [
  'Open Exportify and connect Spotify.',
  'Choose Export All and save the ZIP as it is.',
  'Come back and choose the files. Mixtape will show what it found before importing.',
];

/// The spec's request steps, word for word (`**bold**`, `*italic*` as in
/// the spec's own markup) — docs/superpowers/specs/2026-09-01-listening-
/// export-import-design.md, "Spotify request flow". Change them there first.
const List<String> spotifyRequestSteps = [
  'Open **spotify.com/account/privacy** and log in with the account that has your '
      'listening history. A laptop is easier than a phone for this part.',
  'Scroll to **Download your data**.',
  'Select **Account data** and **Extended streaming history**. '
      'Leave *Technical log information* unselected.',
  'Press **Request data**.',
  'Check your email. Spotify sends a **confirmation** message first. Open it and press '
      '**Confirm**. Nothing is prepared until you do, and this is the step most people miss.',
  'Wait. The two packages arrive as separate emails, each with a **Download** button, '
      'usually within days; the extended history can take up to 30. Each link expires '
      'after about two weeks, so download it when you see it.',
  "Save the ZIPs as they are. Don't unzip them.",
  "Come back to Mixtape and give it each ZIP as it arrives. You don't have to wait for both.",
];

const String spotifyRequestIosNote =
    'On iOS the last step is: tap the download link in Mail, Safari saves the ZIP to '
    'Files, then share it to Mixtape or pick it from inside the app.';

/// Apple's own request flow, from the spec's "Apple 'go deeper' flow"
/// (docs/superpowers/specs/2026-09-01-listening-export-import-design.md),
/// condensed to the four beats the founder asked for.
const List<String> appleRequestSteps = [
  'Open **privacy.apple.com** and sign in with the Apple Account you use for Apple '
      'Music. A laptop is easier than a phone for this part.',
  'Under **Get a copy of your data**, choose **Request a copy of your data** and tick '
      '**Apple Media Services information** only. Its description also mentions the App '
      'Store, iTunes, Apple Books and Podcasts; that is normal, it is one bundle.',
  'Choose the **largest maximum file size** offered, so the export arrives as one file '
      'rather than several parts, then press **Complete request**. Apple says up to 7 '
      'days, usually less.',
  'When the "Your data is ready" email arrives, go back to **privacy.apple.com** and '
      'download the ZIP. It stays available for 14 days.',
  'Save the ZIP as it is, come back here and choose the files.',
];

/// The privacy rule the Apple picker keeps, under it inside the fold
/// (board r4, A2).
const String appleFileNote =
    'Read on this device first. Mixtape shows counts only, and you review '
    'before uploading.';

/// Apple's step 1 before a first sync (board r4, A4).
const String appleSyncIntro =
    'Sync your songs and playlists, so the DJ builds from what you already '
    'play.';

/// The open "Listening history" step's one line (board r4, A1 and S2); the
/// "Optional" tag beside the step's title says the rest.
const String appleHistoryIntro =
    'Teaches the DJ the songs you return to, not only the ones you saved.';
const String spotifyHistoryIntro =
    'Years of plays from Spotify. It takes days to arrive.';

/// "Add your music": the Apple pane (library sync, then the optional Media
/// Services export) and the Spotify pane (the Exportify quick start, the eight
/// official steps, and the checkpoint that starts the wait).
///
/// Shown by the service gate as its second step ([onDone] set, the Spotify
/// segment preselected and "Done, take me to the tapes" at the bottom) and
/// pushed from the Library tab and Home's waiting card ([onDone] null, the
/// glass back button is the way out).
class SpotifyRequestScreen extends ConsumerStatefulWidget {
  const SpotifyRequestScreen({super.key, this.onDone, this.initialSegment});

  final VoidCallback? onDone;

  /// The pane to open on, for the rows that name a service themselves — the
  /// Library tab's Apple Music and Spotify rows. Null lets the default rule
  /// below decide.
  final int? initialSegment;

  /// The fold row in step 2, and so the way tests open it. Both panes have
  /// one; only one pane is ever built.
  static const Key goDeeperKey = Key('go-deeper');

  /// The service toggle under the title, a [GlassSegmentedControl].
  static const Key segmentKey = Key('add-music-segment');

  /// Its two segments.
  static const Key appleSegmentKey = Key('add-music-apple');
  static const Key spotifySegmentKey = Key('add-music-spotify');

  /// "Open Exportify ↗" and "Choose files", which share one row.
  static const Key exportifyRowKey = Key('exportify-row');

  /// The Apple pane's sync, "Sync Apple Music" wherever it stands: the tape
  /// button before a first sync, the icon on the Library step after (its
  /// VoiceOver name). Every sync control names Apple Music (founder,
  /// 2026-11-09).
  static const Key appleSyncKey = Key('add-music-apple-sync');

  /// Each pane's one-line header.
  static const Key statusRowKey = Key('add-music-status');

  /// "Import again" on Spotify's Saved music step, once it is in.
  static const Key spotifyImportAgainKey = Key('spotify-import-again');

  /// "Import again" on Spotify's Listening history step, once it is in.
  static const Key spotifyHistoryImportAgainKey = Key(
    'spotify-history-import-again',
  );

  /// The panes, in segment order.
  static const int appleSegment = 0;
  static const int spotifySegment = 1;

  /// Pushed from Library, the screen is about all of your music; shown by the
  /// gate it is still the Spotify step, and `service_gate_test` pins that copy.
  static const String libraryTitle = 'Add your music';
  static const String gateTitle = 'Bring your Spotify music';

  @override
  ConsumerState<SpotifyRequestScreen> createState() =>
      _SpotifyRequestScreenState();
}

class _SpotifyRequestScreenState extends ConsumerState<SpotifyRequestScreen> {
  bool _deeperOpen = false;

  /// Null until either the listener has chosen a segment or onboarding has
  /// answered once — latched then, so a later refetch cannot slide the screen
  /// out from under a reader.
  int? _segment;

  /// Spotify when the gate is showing this, or when the listener told the gate
  /// they use Spotify; Apple Music otherwise.
  int _resolveSegment(AsyncValue<OnboardingState> onboarding) {
    final latched = _segment ?? widget.initialSegment;
    if (latched != null) return _segment = latched;
    if (widget.onDone != null) {
      return _segment = SpotifyRequestScreen.spotifySegment;
    }
    if (!onboarding.hasValue) return SpotifyRequestScreen.appleSegment;
    return _segment = onboarding.value!.chosenService == 'spotify'
        ? SpotifyRequestScreen.spotifySegment
        : SpotifyRequestScreen.appleSegment;
  }

  /// Both effects run detached, like session events: neither the funnel post
  /// nor the reminder can block or fail the tap. The screen moves on when
  /// the notifier's refetch brings back `markedRequestedAt`.
  void _markRequested() {
    unawaited(ref.read(onboardingProvider.notifier).markRequested());
    unawaited(
      ref
          .read(reminderSchedulerProvider)
          .scheduleRequestReminder(after: requestReminderDelay)
          .catchError((Object _) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final onboarding = ref.watch(onboardingProvider);
    final markedAt = onboarding.value?.markedRequestedAt;
    final openLink = ref.watch(linkOpenerProvider);
    final segment = _resolveSegment(onboarding);

    return GradientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: LargeTitleScaffold(
          title: widget.onDone == null
              ? SpotifyRequestScreen.libraryTitle
              : SpotifyRequestScreen.gateTitle,
          // The gate owns its own way out; pushed from Home or the Library
          // tab, the pinned glass cluster is the board's back affordance.
          leading: widget.onDone == null
              ? GlassCluster(
                  children: [
                    GlassButton(
                      key: const Key('request-back'),
                      icon: CupertinoIcons.chevron_left,
                      label: 'Back',
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                )
              : null,
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 4),
                  _segmentedControl(segment),
                  // The toggle reads as navigation, not part of the first
                  // section (board r4, note 1).
                  const SizedBox(height: 22),
                  if (segment == SpotifyRequestScreen.appleSegment)
                    _applePane(openLink)
                  else
                    _spotifyPane(openLink, markedAt),
                  if (widget.onDone != null) ...[
                    const SizedBox(height: 20),
                    Center(
                      child: TapeButton(
                        key: const Key('request-done'),
                        label: 'Done, take me to the tapes',
                        onPressed: widget.onDone,
                      ),
                    ),
                  ],
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The native glass toggle, as on Mixes, hugging the left margin under the
  /// title (board r4, T1). Its labels stop growing at the control's cap, as
  /// `UISegmentedControl` does; off iOS 26 it is the house toggle.
  Widget _segmentedControl(int segment) => Align(
    alignment: Alignment.centerLeft,
    child: MediaQuery.withClampedTextScaling(
      maxScaleFactor: GlassSegmentedControl.maxTextScale,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth:
              MediaQuery.sizeOf(context).width -
              2 * MixtapeMetrics.screenSidePadding,
        ),
        child: GlassSegmentedControl<int>(
          key: SpotifyRequestScreen.segmentKey,
          value: segment,
          onChanged: (value) {
            if (value == segment) return;
            setState(() {
              _segment = value;
              // The other pane's fold is not this one's; a switch that
              // landed on a screenful of open steps reads as a different
              // screen.
              _deeperOpen = false;
            });
          },
          options: const [
            SegmentedOption(
              value: SpotifyRequestScreen.appleSegment,
              label: 'Apple Music',
              key: SpotifyRequestScreen.appleSegmentKey,
            ),
            SegmentedOption(
              value: SpotifyRequestScreen.spotifySegment,
              label: 'Spotify',
              key: SpotifyRequestScreen.spotifySegmentKey,
            ),
          ],
        ),
      ),
    ),
  );

  /// One row, not two stacked blocks: open the exporter, then choose what it
  /// gave you (smoke round four, note 4). The two sit on opposite edges of
  /// the row rather than huddling on the left (smoke round five, note 2), and
  /// still stack once the text is too large for both to share a line.
  Widget _exportifyRow(Future<bool> Function(Uri) openLink) => Wrap(
    key: SpotifyRequestScreen.exportifyRowKey,
    // `spaceBetween`, so a run that holds both puts the tape button on the
    // left margin and the chip on the right instead of huddling them. A run
    // that holds one — the stacked case at large text — is simply left
    // aligned, exactly as the plain wrap was.
    alignment: WrapAlignment.spaceBetween,
    spacing: 8,
    runSpacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      TapeButton(
        key: const Key('open-exportify'),
        label: 'Open Exportify ↗',
        onPressed: () => unawaited(openLink(exportifyUrl)),
      ),
      _chooseChip(),
    ],
  );

  /// "Choose files": straight to the picker; the sheet follows the file
  /// (smoke round seven, note 1).
  Widget _chooseChip() => LabelChip(
    key: const Key('choose-import-files'),
    label: 'Choose files',
    leading: const _FileGlyph(),
    // Straight to the file picker.
    haptic: HapticKind.open,
    onPressed: () => unawaited(openImportFlow(context, ref)),
  );

  /// Apple: step 1 the library sync, step 2 the optional Media Services
  /// export, its request steps and file folded under one row (board r4,
  /// A1–A7).
  Widget _applePane(Future<bool> Function(Uri) openLink) {
    final onboarding = ref.watch(onboardingProvider).value;
    final sync = ref.watch(librarySyncProvider);
    final status = appleSyncStatus(sync, onboarding);
    final running = sync is SyncRunning;
    // A library that landed once stays added, a failed re-sync included.
    final libraryAdded =
        appleLiveSource(onboarding) != null || sync is SyncDone;
    MusicSource? history;
    for (final source in onboarding?.sources ?? const <MusicSource>[]) {
      if (source.source == 'apple_export' && source.lastImportedAt != null) {
        history = source;
      }
    }
    void startSync() => unawaited(showLibrarySync(context, ref));
    void choose() => unawaited(openImportFlow(context, ref));
    final syncIcon = _SyncIconButton(onPressed: startSync);

    final _Step library = switch (sync) {
      SyncRunning(:final progress) => _Step(
        number: 1,
        state: _StepState.current,
        title: 'Library',
        status: '${status.label} · you can leave this screen',
        body: _SyncProgress(progress: progress),
      ),
      SyncFailed() => _Step(
        number: 1,
        state: _StepState.attention,
        title: 'Library',
        status: status.label,
        statusKind: StatusKind.warn,
        actions: [syncIcon],
      ),
      _ when libraryAdded => _Step(
        number: 1,
        state: _StepState.done,
        title: 'Library',
        status: status.label,
        statusKind: StatusKind.ok,
        actions: [syncIcon],
      ),
      _ => _Step(
        number: 1,
        state: _StepState.current,
        title: 'Library',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Lede(appleSyncIntro),
            TapeButton(
              key: SpotifyRequestScreen.appleSyncKey,
              label: 'Sync Apple Music',
              leading: const _TapeGlyph(CupertinoIcons.arrow_2_circlepath),
              onPressed: startSync,
            ),
          ],
        ),
      ),
    };

    final _Step historyStep;
    if (history != null) {
      final years = yearsRange(history.ledgerFrom, history.ledgerTo);
      final added = 'Added ${shortDate(history.lastImportedAt!)}';
      historyStep = _Step(
        number: 2,
        state: _StepState.done,
        title: 'Listening history',
        status: years == null ? added : '$added · $years',
        statusKind: StatusKind.ok,
        actions: [
          TextAction(
            key: const Key('choose-apple-files'),
            label: 'Replace',
            haptic: HapticKind.open,
            onPressed: choose,
          ),
          TextAction(
            key: const Key('remove-apple_export'),
            label: 'Remove',
            quiet: true,
            // Presents the confirmation, which plays the destructive tick.
            haptic: HapticKind.open,
            onPressed: () =>
                unawaited(removeSourceFlow(context, ref, history!)),
          ),
        ],
        isLast: true,
      );
    } else if (!libraryAdded && !running) {
      // Before a first sync the sync is the one primary action; the file
      // waits as a small one (board r4, A4).
      historyStep = _Step(
        number: 2,
        state: _StepState.waiting,
        title: 'Listening history',
        optional: true,
        status: 'After your library, or any time',
        actions: [
          TextAction(
            key: const Key('choose-apple-files'),
            label: 'Choose file',
            haptic: HapticKind.open,
            onPressed: choose,
          ),
        ],
        isLast: true,
      );
    } else {
      historyStep = _Step(
        number: 2,
        state: _StepState.current,
        title: 'Listening history',
        optional: true,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Lede(appleHistoryIntro, bottom: 0),
            _Disclosure(
              title: 'Get your Apple file',
              subtitle: _deeperOpen
                  ? 'Request it, then choose it'
                  : 'From privacy.apple.com',
              open: _deeperOpen,
              onTap: () => setState(() => _deeperOpen = !_deeperOpen),
            ),
            if (_deeperOpen)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _AppleSteps(
                      onOpenAddress: () => unawaited(openLink(applePrivacyUrl)),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      // One primary action per pane (3 Nov rule): before a
                      // first sync the file is a chip.
                      child: libraryAdded
                          ? TapeButton(
                              key: const Key('choose-apple-files'),
                              label: 'Choose your Apple file',
                              leading: const _TapeGlyph(CupertinoIcons.doc),
                              haptic: HapticKind.open,
                              onPressed: choose,
                            )
                          : LabelChip(
                              key: const Key('choose-apple-files'),
                              label: 'Choose your Apple file',
                              leading: const _FileGlyph(),
                              haptic: HapticKind.open,
                              onPressed: choose,
                            ),
                    ),
                    const SizedBox(height: 6),
                    _Note(appleFileNote),
                  ],
                ),
              ),
          ],
        ),
        isLast: true,
      );
    }

    final done = (libraryAdded && !running ? 1 : 0) + (history != null ? 1 : 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ServiceHeader(
          icon: const AppleMusicIcon(size: _ServiceHeader.iconSize),
          name: 'Apple Music',
          line: running ? 'Syncing…' : _ServiceHeader.countLine(done),
          done: done,
        ),
        library,
        historyStep,
      ],
    );
  }

  /// Spotify: step 1 the saved music (the Exportify quick start), step 2 the
  /// optional listening history with the eight official steps folded (board
  /// r4, S1–S4).
  Widget _spotifyPane(Future<bool> Function(Uri) openLink, DateTime? markedAt) {
    final onboarding = ref.watch(onboardingProvider).value;
    final source = onboarding == null ? null : spotifySource(onboarding);
    final packages = source?.packages ?? const <String>[];
    // Saved music is the Exportify package, or the official account data,
    // which carries the same library (`spotifyStatusLabel`'s "Both in").
    final savedIn =
        packages.contains('spotify_exportify') ||
        packages.contains(accountPackage);
    final historyIn = packages.contains(extendedPackage);
    final imported = source?.lastImportedAt;
    final importedLabel = imported == null
        ? 'Imported'
        : 'Imported ${shortDate(imported)}';
    void importAgain() => unawaited(openImportFlow(context, ref));
    // The one export holds both steps, so one Remove, on the last step in.
    Widget remove() => TextAction(
      key: const Key('remove-spotify_export'),
      label: 'Remove',
      quiet: true,
      haptic: HapticKind.open,
      onPressed: () => unawaited(removeSourceFlow(context, ref, source!)),
    );

    final saved = savedIn
        ? _Step(
            number: 1,
            state: _StepState.done,
            title: 'Saved music',
            status: importedLabel,
            statusKind: StatusKind.ok,
            actions: [
              TextAction(
                key: SpotifyRequestScreen.spotifyImportAgainKey,
                label: 'Import again',
                haptic: HapticKind.open,
                onPressed: importAgain,
              ),
              if (!historyIn) remove(),
            ],
          )
        : _Step(
            number: 1,
            state: _StepState.current,
            title: 'Saved music',
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < exportifyQuickStartSteps.length; i++)
                  _NumberedRow(
                    number: '${i + 1}',
                    isFirst: i == 0,
                    child: Text(
                      exportifyQuickStartSteps[i],
                      style: _stepStyle(context),
                    ),
                  ),
                const SizedBox(height: 8),
                _exportifyRow(openLink),
                const SizedBox(height: 4),
              ],
            ),
          );

    final _Step history;
    if (historyIn) {
      final years = source == null
          ? null
          : yearsRange(source.ledgerFrom, source.ledgerTo);
      history = _Step(
        number: 2,
        state: _StepState.done,
        title: 'Listening history',
        status: years == null ? importedLabel : '$importedLabel · $years',
        statusKind: StatusKind.ok,
        actions: [
          TextAction(
            key: SpotifyRequestScreen.spotifyHistoryImportAgainKey,
            label: 'Import again',
            haptic: HapticKind.open,
            onPressed: importAgain,
          ),
          remove(),
        ],
        isLast: true,
      );
    } else if (!savedIn) {
      // Waiting on saved music, but the request is days of email, so it can
      // start now: a small action opens the same eight steps (Home's waiting
      // card sends a listener here to make that request).
      history = _Step(
        number: 2,
        state: _StepState.waiting,
        title: 'Listening history',
        optional: true,
        status: markedAt == null
            ? 'Request it from Spotify any time'
            : 'Requested ${elapsedWait(markedAt)}',
        actions: [
          if (!_deeperOpen)
            TextAction(
              key: SpotifyRequestScreen.goDeeperKey,
              label: 'How to request it',
              // Unfolds the steps in place, as the disclosure row does.
              haptic: HapticKind.select,
              onPressed: () => setState(() => _deeperOpen = true),
            ),
        ],
        body: _deeperOpen
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Disclosure(
                    title: 'How to request it',
                    subtitle: '${spotifyRequestSteps.length} steps',
                    open: true,
                    onTap: () => setState(() => _deeperOpen = false),
                  ),
                  _DeeperSteps(
                    markedAt: markedAt,
                    onOpenAddress: () => unawaited(openLink(spotifyPrivacyUrl)),
                    onMarkRequested: _markRequested,
                  ),
                ],
              )
            : null,
        isLast: true,
      );
    } else {
      history = _Step(
        number: 2,
        state: _StepState.current,
        title: 'Listening history',
        optional: true,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Lede(spotifyHistoryIntro, bottom: 0),
            _Disclosure(
              title: 'How to request it',
              // Collapsed, the row carries the wait so the listener sees it
              // without opening the block; open, the block's own line says it.
              subtitle: !_deeperOpen && markedAt != null
                  ? 'Requested ${elapsedWait(markedAt)}'
                  : '${spotifyRequestSteps.length} steps',
              open: _deeperOpen,
              onTap: () => setState(() => _deeperOpen = !_deeperOpen),
            ),
            if (_deeperOpen)
              _DeeperSteps(
                markedAt: markedAt,
                onOpenAddress: () => unawaited(openLink(spotifyPrivacyUrl)),
                onMarkRequested: _markRequested,
              ),
            const SizedBox(height: 6),
            Align(alignment: Alignment.centerLeft, child: _chooseChip()),
            const SizedBox(height: 4),
          ],
        ),
        isLast: true,
      );
    }

    final done = (savedIn ? 1 : 0) + (historyIn ? 1 : 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ServiceHeader(
          icon: const SpotifyIcon(size: _ServiceHeader.iconSize),
          name: 'Spotify',
          line: _ServiceHeader.countLine(done),
          done: done,
        ),
        saved,
        history,
      ],
    );
  }
}

/// The step copy's size inside a checklist (board r4 `.item3 .step`).
TextStyle _stepStyle(BuildContext context) =>
    context.tokens.body.copyWith(fontSize: 13.5, height: 1.4);

/// Where a service stands, at the top of its pane, on one line: the official
/// icon, the name, "· 1 of 2 added", and a two-bar meter at the right (board
/// r4 `.hero3`). At large text the count and the meter drop under the name.
class _ServiceHeader extends StatelessWidget {
  const _ServiceHeader({
    required this.icon,
    required this.name,
    required this.line,
    required this.done,
  });

  final Widget icon;
  final String name;
  final String line;

  /// How many of the two steps are in: the meter's green bars.
  final int done;

  static const double iconSize = 32;

  /// At this text scale the header stacks.
  static const double stackScale = 1.3;

  static String countLine(int done) => switch (done) {
    2 => 'All in',
    1 => '1 of 2 added',
    _ => 'Not added yet',
  };

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final stacked = MediaQuery.textScalerOf(context).scale(1) >= stackScale;
    final nameStyle = TextStyle(
      fontSize: 17,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
      height: 1.2,
      color: tokens.text,
    );
    final lineStyle = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      color: tokens.muted,
    );
    final meter = ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 2; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            Container(
              width: 18,
              height: 3,
              decoration: BoxDecoration(
                color: i < done ? statusOkGlyph(context) : tokens.hairline,
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
          ],
        ],
      ),
    );

    return Semantics(
      key: SpotifyRequestScreen.statusRowKey,
      container: true,
      label: '$name, $line',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: stacked
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  icon,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name, style: nameStyle),
                        Text(line, style: lineStyle),
                        const SizedBox(height: 6),
                        meter,
                      ],
                    ),
                  ),
                ],
              )
            : Row(
                children: [
                  icon,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: name, style: nameStyle),
                          TextSpan(text: ' · $line', style: lineStyle),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  meter,
                ],
              ),
      ),
    );
  }
}

/// Where a checklist step stands, and so its disc.
enum _StepState { done, current, waiting, attention }

/// One checklist step between hairlines (board r4 `.item3`): the state disc,
/// the title (with "Optional" on the history steps), the status line, the
/// actions at the right of that block, and the step's open body under it.
///
/// The step is one semantics container ("Step 1, Library, done, Synced 2
/// Nov"); its actions and body stay reachable inside it.
class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.state,
    required this.title,
    this.optional = false,
    this.status,
    this.statusKind = StatusKind.muted,
    this.actions = const [],
    this.body,
    this.isLast = false,
  });

  final int number;
  final _StepState state;
  final String title;
  final bool optional;
  final String? status;
  final StatusKind statusKind;
  final List<Widget> actions;
  final Widget? body;
  final bool isLast;

  /// The disc and the column it sits in.
  static const double disc = 20;
  static const double discColumn = 22;
  static const double gap = 12;

  /// At this text scale, or under [stackWidth], the actions drop under the
  /// status line rather than squeezing the title.
  static const double stackScale = 1.3;
  static const double stackWidth = 260;

  String get _stateWord => switch (state) {
    _StepState.done => 'done',
    _StepState.current => 'to do',
    _StepState.waiting => 'waiting',
    _StepState.attention => 'needs attention',
  };

  String get semanticsLabel => [
    'Step $number',
    title,
    if (optional) 'optional',
    _stateWord,
    ?status,
  ].join(', ');

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final hairline = Container(height: 1, color: tokens.hairline);
    return Semantics(
      container: true,
      // The actions and the body keep nodes of their own inside the step.
      explicitChildNodes: true,
      label: semanticsLabel,
      child: Stack(
        children: [
          Positioned(left: 0, right: 0, top: 0, child: hairline),
          if (isLast) Positioned(left: 0, right: 0, bottom: 0, child: hairline),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: LayoutBuilder(
              builder: (context, constraints) => _content(
                context,
                stacked:
                    constraints.maxWidth < stackWidth ||
                    MediaQuery.textScalerOf(context).scale(1) >= stackScale,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _content(BuildContext context, {required bool stacked}) {
    final tokens = context.tokens;
    final scaler = MediaQuery.textScalerOf(context);
    final titleStyle = TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      height: 1.3,
      color: tokens.text,
    );
    final statusStyle = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w500,
      height: 1.3,
      color: switch (statusKind) {
        StatusKind.ok => tokens.okInk,
        StatusKind.warn => tokens.warnInk,
        StatusKind.err => tokens.errInk,
        _ => tokens.muted,
      },
    );
    final block = ExcludeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: title, style: titleStyle),
                if (optional)
                  TextSpan(
                    text: '  Optional',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: tokens.muted,
                    ),
                  ),
              ],
            ),
          ),
          if (status != null) ...[
            const SizedBox(height: 1),
            Text(status!, style: statusStyle),
          ],
        ],
      ),
    );

    // The block's height beside a 44 pt action, so the disc can sit level
    // with the title rather than with the block's middle.
    final titleLine = scaler.scale(15) * 1.3;
    final blockHeight =
        titleLine + (status == null ? 0 : 1 + scaler.scale(12) * 1.3);
    final besideActions = actions.isNotEmpty && !stacked;
    final blockTop = besideActions
        ? ((MixtapeMetrics.minTarget - blockHeight) / 2).clamp(0.0, 44.0)
        : 0.0;
    // The actions' own centre lifted to the title line (board `.hd`
    // aligns them on its baseline); their 44 pt targets keep their size.
    final lift = besideActions
        ? -((blockHeight - titleLine) / 2).clamp(0.0, 44.0)
        : 0.0;

    final header = besideActions
        ? Row(
            children: [
              Expanded(child: block),
              const SizedBox(width: 8),
              Transform.translate(
                offset: Offset(8, lift),
                child: Row(mainAxisSize: MainAxisSize.min, children: actions),
              ),
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              block,
              if (actions.isNotEmpty)
                // The actions' own 8 pt inset, pulled back so the first word
                // lines up with the title.
                Transform.translate(
                  offset: const Offset(-8, 0),
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: actions,
                  ),
                ),
            ],
          );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: discColumn,
          child: Padding(
            padding: EdgeInsets.only(
              top: blockTop + ((titleLine - disc) / 2).clamp(0.0, 20.0),
            ),
            child: ExcludeSemantics(child: _StepDisc(state, number)),
          ),
        ),
        const SizedBox(width: gap),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              if (body != null) ...[const SizedBox(height: 4), body!],
            ],
          ),
        ),
      ],
    );
  }
}

/// The 20 pt state disc: a green check when done, the plum number for the
/// step to do now, a grey number while it waits, an amber "!" when it needs
/// attention.
class _StepDisc extends StatelessWidget {
  const _StepDisc(this.state, this.number);

  final _StepState state;
  final int number;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    const size = _Step.disc;
    final numberStyle = TextStyle(
      fontSize: 10.5,
      fontWeight: FontWeight.w700,
      height: 1,
      color: state == _StepState.current ? tokens.plum : tokens.muted,
    );
    return switch (state) {
      _StepState.done => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: statusOkGlyph(context),
          shape: BoxShape.circle,
        ),
        child: const Icon(
          CupertinoIcons.checkmark,
          size: 13,
          color: Colors.white,
        ),
      ),
      _StepState.attention => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: statusWarnGlyph(context),
          shape: BoxShape.circle,
        ),
        child: const Text(
          '!',
          textScaler: TextScaler.noScaling,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            height: 1,
            color: Colors.white,
          ),
        ),
      ),
      _ => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            width: 1.5,
            color: state == _StepState.current
                ? tokens.plum
                : tokens.muted.withValues(alpha: 0.45),
          ),
        ),
        child: Text(
          '$number',
          textScaler: TextScaler.noScaling,
          style: numberStyle,
        ),
      ),
    };
  }
}

/// "Sync Apple Music" as an icon: the two-arrow glyph drawn 30 pt in a 44 pt
/// target (board r4, A1), named for VoiceOver.
class _SyncIconButton extends StatelessWidget {
  const _SyncIconButton({required this.onPressed});

  final VoidCallback onPressed;

  static const String label = 'Sync Apple Music';

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    // excludeSemantics drops the InkResponse's tap action; declare it here.
    onTap: onPressed,
    excludeSemantics: true,
    child: InkResponse(
      key: SpotifyRequestScreen.appleSyncKey,
      // The same call to action as the "Sync Apple Music" tape button.
      onTap: Haptics.on(HapticKind.primary, onPressed),
      radius: 22,
      child: SizedBox.square(
        dimension: MixtapeMetrics.minTarget,
        child: Center(
          child: SizedBox.square(
            dimension: 30,
            child: Icon(
              CupertinoIcons.arrow_2_circlepath,
              size: 20,
              color: context.tokens.plum,
            ),
          ),
        ),
      ),
    ),
  );
}

/// A sync in flight: the thin plum bar under the status line.
class _SyncProgress extends StatelessWidget {
  const _SyncProgress({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 220),
        child: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 4,
            borderRadius: BorderRadius.circular(2),
            color: tokens.plum,
            backgroundColor: tokens.hairline,
          ),
        ),
      ),
    );
  }
}

/// A step's one line of explanation (board r4 `.item3 p`).
class _Lede extends StatelessWidget {
  const _Lede(this.text, {this.bottom = 8});

  final String text;
  final double bottom;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: bottom),
    child: Text(
      text,
      style: context.tokens.secondary.copyWith(fontSize: 12.5, height: 1.38),
    ),
  );
}

/// The muted one-liner under a file action (board r4 `.fnote2`).
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: context.tokens.meta.copyWith(height: 1.4));
}

/// The file glyph on a chip.
class _FileGlyph extends StatelessWidget {
  const _FileGlyph();

  @override
  Widget build(BuildContext context) =>
      Icon(CupertinoIcons.doc, size: 15, color: context.tokens.plum);
}

/// A glyph on a tape button, in the tape's ink.
class _TapeGlyph extends StatelessWidget {
  const _TapeGlyph(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) =>
      Icon(icon, size: 18, color: context.tokens.tapeInk);
}

/// The fold inside a step: a flush row whose words say what is under it
/// (board r4 `.how3`), a 44 pt target that says whether it is open.
class _Disclosure extends StatelessWidget {
  const _Disclosure({
    required this.title,
    required this.subtitle,
    required this.open,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Semantics(
      button: true,
      expanded: open,
      child: InkWell(
        key: SpotifyRequestScreen.goDeeperKey,
        // Folding steps open or shut is a choice between two states, not a
        // trip anywhere.
        onTap: Haptics.on(HapticKind.select, onTap),
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: MixtapeMetrics.minTarget,
          ),
          child: Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.end,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        height: 1.25,
                        color: tokens.text,
                      ),
                    ),
                    Text(subtitle, style: tokens.meta.copyWith(height: 1.35)),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                open ? CupertinoIcons.chevron_up : CupertinoIcons.chevron_down,
                size: 14,
                color: tokens.muted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Apple's request steps, flush under the disclosure row.
class _AppleSteps extends StatelessWidget {
  const _AppleSteps({required this.onOpenAddress});

  final VoidCallback onOpenAddress;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < appleRequestSteps.length; i++)
        _NumberedRow(
          number: '${i + 1}.',
          isFirst: i == 0,
          child: _StepText(
            text: appleRequestSteps[i],
            address: applePrivacyAddress,
            linkKey: const Key('link-apple-privacy'),
            onOpenAddress: onOpenAddress,
          ),
        ),
    ],
  );
}

/// The eight official steps, the iOS note, the two emails, and the checkpoint,
/// inside the deeper group.
class _DeeperSteps extends StatelessWidget {
  const _DeeperSteps({
    required this.markedAt,
    required this.onOpenAddress,
    required this.onMarkRequested,
  });

  final DateTime? markedAt;
  final VoidCallback onOpenAddress;
  final VoidCallback onMarkRequested;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < spotifyRequestSteps.length; i++)
            _NumberedRow(
              number: '${i + 1}.',
              isFirst: i == 0,
              child: _StepText(
                text: spotifyRequestSteps[i],
                address: spotifyPrivacyAddress,
                linkKey: const Key('link-spotify-privacy'),
                onOpenAddress: onOpenAddress,
              ),
            ),
          const SizedBox(height: 12),
          Text(spotifyRequestIosNote, style: tokens.meta),
          const SizedBox(height: 20),
          const _EmailsNote(),
          const SizedBox(height: 12),
          if (markedAt != null) ...[
            Text(
              'Requested ${elapsedWait(markedAt!)}',
              key: const Key('requested-elapsed'),
              style: tokens.rowTitle,
            ),
            const SizedBox(height: 2),
            Text(
              "Spotify's confirmation email comes first. Check your inbox and press "
              "Confirm if you haven't yet.",
              style: tokens.meta,
            ),
          ] else ...[
            Align(
              alignment: Alignment.centerLeft,
              child: TextAction(
                key: const Key('mark-requested'),
                label: "I've requested it",
                haptic: HapticKind.success,
                onPressed: onMarkRequested,
              ),
            ),
            Text(
              "We'll remind you in three days to check your inbox.",
              style: tokens.meta,
            ),
          ],
        ],
      ),
    );
  }
}

/// A flush numbered row: a hairline above every row but the first, no box.
///
/// [FlushRow] itself is not used here — its title is a single ellipsised line
/// below 150% text, and every step on this screen is a wrapping sentence.
class _NumberedRow extends StatelessWidget {
  const _NumberedRow({
    required this.number,
    required this.isFirst,
    required this.child,
  });

  final String number;
  final bool isFirst;
  final Widget child;

  /// The number column's width, and so the hairline's inset (board r4
  /// `.step`).
  static const double numberColumn = 24;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 32),
      child: Stack(
        children: [
          if (!isFirst)
            Positioned(
              left: numberColumn,
              right: 0,
              top: 0,
              child: Container(height: 1, color: tokens.hairline),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: numberColumn,
                  child: Text(
                    number,
                    style: tokens.meta.copyWith(
                      fontWeight: FontWeight.w700,
                      color: tokens.muted,
                    ),
                  ),
                ),
                Expanded(child: child),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One official step's `**bold**` / `*italic*` markup, with [address] as the
/// one tappable run.
class _StepText extends StatelessWidget {
  const _StepText({
    required this.text,
    required this.address,
    required this.linkKey,
    required this.onOpenAddress,
  });

  final String text;
  final String address;
  final Key linkKey;
  final VoidCallback onOpenAddress;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final body = _stepStyle(context);
    return Text.rich(
      TextSpan(
        style: body,
        children: requestCopySpans(
          text,
          addressText: address,
          address: (address) => InkWell(
            key: linkKey,
            onTap: Haptics.on(HapticKind.tap, onOpenAddress),
            // The approval's 44 px link target: the padding grows the line
            // box, the baseline alignment keeps the word on the text baseline.
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                address,
                style: body.copyWith(
                  fontWeight: FontWeight.bold,
                  decoration: TextDecoration.underline,
                  color: tokens.plum,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Renders one step's `**bold**` / `*italic*` markup; the one bold run that
/// is [addressText] becomes the tappable widget [address] builds.
List<InlineSpan> requestCopySpans(
  String text, {
  required Widget Function(String address) address,
  String addressText = spotifyPrivacyAddress,
}) {
  final spans = <InlineSpan>[];
  final markup = RegExp(r'\*\*(.+?)\*\*|\*(.+?)\*');
  var last = 0;
  for (final match in markup.allMatches(text)) {
    if (match.start > last) {
      spans.add(TextSpan(text: text.substring(last, match.start)));
    }
    final bold = match.group(1);
    if (bold == addressText) {
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: address(bold!),
        ),
      );
    } else if (bold != null) {
      spans.add(
        TextSpan(
          text: bold,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      );
    } else {
      spans.add(
        TextSpan(
          text: match.group(2),
          style: const TextStyle(fontStyle: FontStyle.italic),
        ),
      );
    }
    last = match.end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
  return spans;
}

/// What the two emails look like — a section word over flush copy, not a card
/// (the approval bars decorative containers and left rails).
class _EmailsNote extends StatelessWidget {
  const _EmailsNote();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionWord('What the two emails look like'),
        Text(
          'First, a confirmation email from Spotify, minutes after you press Request '
          'data. It has a Confirm button. Press it, or nothing is prepared.',
          style: tokens.secondary,
        ),
        const SizedBox(height: 8),
        Text(
          'Then a "your data is ready" email for each package, each with a Download '
          'button. Two emails, often days apart. Each link lasts about two weeks.',
          style: tokens.secondary,
        ),
      ],
    );
  }
}
