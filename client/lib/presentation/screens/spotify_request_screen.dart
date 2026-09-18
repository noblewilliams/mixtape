/// "Add your music": one screen for both services, with a native segmented
/// control under the title — Apple Music | Spotify (founder, smoke round four,
/// note 4).
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

import 'package:flutter/cupertino.dart'
    show CupertinoIcons, CupertinoSlidingSegmentedControl;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/listening/listening_models.dart';
import '../format/import_format.dart';
import '../format/relative_time.dart';
import '../providers/device_providers.dart';
import '../providers/library_sync_provider.dart';
import '../providers/onboarding_provider.dart';
import '../theme/mixtape_theme.dart';
import '../widgets/foundation/glass_cluster.dart';
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/inset_group.dart';
import '../widgets/foundation/label_chip.dart';
import '../widgets/foundation/large_title_scaffold.dart';
import '../widgets/foundation/section_word.dart';
import '../widgets/foundation/status_word.dart';
import '../widgets/foundation/tape_button.dart';
import '../widgets/foundation/text_action.dart';
import '../widgets/library_sync_sheet.dart';
import 'import_sheet.dart';

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

/// The one line under the Exportify row. It was two — where the link goes and
/// what the picker takes — and the founder read the pair as clutter beside a
/// row that now holds both actions (smoke round four, note 4).
const String exportifyRowNote =
    'Opens exportify.app outside Mixtape. Takes an Exportify ZIP or CSV files, '
    'or an official Spotify ZIP; read on this device first, reviewed before '
    'uploading.';

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

/// What the Apple picker takes, and the privacy rule it keeps.
const String appleFileNote =
    'An Apple Media Services ZIP, read on this device first. Mixtape shows counts '
    'only — never a song or artist name — and you review before uploading.';

/// The Apple pane's opening line, from the web's own sync panel
/// (`web/src/components/AppleMusicSyncPanel.tsx`).
const String appleSyncIntro =
    'Bring your Apple Music songs and playlists into Mixtape, so the DJ builds '
    'from what you already listen to.';

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

  /// The pane to open on, for the rows that name a service themselves —
  /// "Add Spotify music" on the Library tab and on Your music. Null lets the
  /// default rule below decide.
  final int? initialSegment;

  /// The deeper block's disclosure row, and so the way tests open it. Both
  /// panes have one; only one pane is ever built.
  static const Key goDeeperKey = Key('go-deeper');

  /// The service toggle under the title.
  static const Key segmentKey = Key('add-music-segment');

  /// The Apple pane's "Sync your library".
  static const Key appleSyncKey = Key('add-music-apple-sync');

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
                  _segmentedControl(segment),
                  const SizedBox(height: 18),
                  if (segment == SpotifyRequestScreen.appleSegment)
                    _applePane(openLink)
                  else
                    _spotifyPane(openLink, markedAt),
                  if (widget.onDone != null) ...[
                    const SizedBox(height: 4),
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

  /// Full width under the large title, the way iOS puts one there: centred and
  /// shrink-wrapped it floated over left-aligned copy.
  Widget _segmentedControl(int segment) => SizedBox(
    width: double.infinity,
    child: CupertinoSlidingSegmentedControl<int>(
      key: SpotifyRequestScreen.segmentKey,
      groupValue: segment,
      onValueChanged: (value) {
        if (value == null || value == segment) return;
        setState(() {
          _segment = value;
          // The other pane's deeper block is not this one's; a switch that
          // landed on a screenful of open steps reads as a different screen.
          _deeperOpen = false;
        });
      },
      children: const {
        SpotifyRequestScreen.appleSegment: _SegmentLabel('Apple Music'),
        SpotifyRequestScreen.spotifySegment: _SegmentLabel('Spotify'),
      },
    ),
  );

  /// Apple: sync the live library, then the optional Media Services export.
  Widget _applePane(Future<bool> Function(Uri) openLink) {
    final tokens = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionWord('Sync your Apple Music'),
        Text(appleSyncIntro, style: tokens.body),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: TapeButton(
            key: SpotifyRequestScreen.appleSyncKey,
            label: 'Sync your library',
            onPressed: () => LibrarySyncSheet.show(context),
          ),
        ),
        const _AppleSyncStatus(),
        const SizedBox(height: 20),
        InsetGroup(
          children: [
            InsetRow(
              key: SpotifyRequestScreen.goDeeperKey,
              title: 'Go deeper with your history',
              subtitle:
                  'Apple can send you everything you have played. Optional, '
                  'and the sync above works without it.',
              trailing: Icon(
                _deeperOpen ? Icons.expand_less : Icons.expand_more,
                size: 20,
                color: tokens.muted,
              ),
              onTap: () => setState(() => _deeperOpen = !_deeperOpen),
            ),
            if (_deeperOpen)
              _AppleSteps(
                onOpenAddress: () => unawaited(openLink(applePrivacyUrl)),
              ),
          ],
        ),
      ],
    );
  }

  /// Spotify: the quick start, the two actions on one row, and the deeper
  /// block with the eight official steps.
  Widget _spotifyPane(Future<bool> Function(Uri) openLink, DateTime? markedAt) {
    final tokens = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionWord('Export your saved music'),
        for (var i = 0; i < exportifyQuickStartSteps.length; i++)
          _NumberedRow(
            number: '${i + 1}',
            isFirst: i == 0,
            child: Text(exportifyQuickStartSteps[i], style: tokens.body),
          ),
        const SizedBox(height: 12),
        // One row, not two stacked blocks: open the exporter, then choose what
        // it gave you (smoke round four, note 4). It wraps only when the text
        // is too large for both to sit side by side.
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TapeButton(
              key: const Key('open-exportify'),
              label: 'Open Exportify ↗',
              onPressed: () => unawaited(openLink(exportifyUrl)),
            ),
            LabelChip(
              key: const Key('choose-import-files'),
              label: 'Choose files',
              onPressed: () => unawaited(showImportSheet(context)),
            ),
          ],
        ),
        Text(exportifyRowNote, style: tokens.meta),
        const SizedBox(height: 20),
        InsetGroup(
          children: [
            InsetRow(
              key: SpotifyRequestScreen.goDeeperKey,
              title: 'Go deeper with your history',
              // Collapsed, the row carries the wait so the listener sees it
              // without opening the block; open, the block's own line says it
              // and the row goes back to its description.
              subtitle: !_deeperOpen && markedAt != null
                  ? 'Requested ${elapsedWait(markedAt)}'
                  : 'Help the DJ learn your repeat favourites and past listening.',
              trailing: Icon(
                _deeperOpen ? Icons.expand_less : Icons.expand_more,
                size: 20,
                color: tokens.muted,
              ),
              onTap: () => setState(() => _deeperOpen = !_deeperOpen),
            ),
            if (_deeperOpen)
              _DeeperSteps(
                markedAt: markedAt,
                onOpenAddress: () => unawaited(openLink(spotifyPrivacyUrl)),
                onMarkRequested: _markRequested,
              ),
          ],
        ),
      ],
    );
  }
}

/// One segment's label. Padded to a 44 pt control: the house rule audits the
/// segmented control like every other native control on the screen.
class _SegmentLabel extends StatelessWidget {
  const _SegmentLabel(this.text);

  final String text;

  /// The control adds 2 pt above and below, which makes 44.
  static const double minHeight = 40;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: minHeight),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      child: Center(
        widthFactor: 1,
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: context.tokens.rowTitle,
        ),
      ),
    ),
  );
}

/// Where the Apple library sync got to, under the Sync button: the run this
/// session started, or the date the account last had one.
class _AppleSyncStatus extends ConsumerWidget {
  const _AppleSyncStatus();

  static const Key statusKey = Key('apple-sync-status');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(librarySyncProvider);
    final onboarding = ref.watch(onboardingProvider).value;
    MusicSource? live;
    for (final source in onboarding?.sources ?? const <MusicSource>[]) {
      if (source.source == 'apple_live') live = source;
    }

    final (StatusKind kind, String label) = switch (sync) {
      SyncRunning(:final progress) => (
        StatusKind.warn,
        progress == 0 ? 'Syncing…' : 'Syncing… ${(progress * 100).round()}%',
      ),
      SyncFailed() => (StatusKind.err, "Last sync didn't finish"),
      SyncDone() => (StatusKind.ok, 'Synced just now'),
      SyncIdle() when live != null => (
        StatusKind.ok,
        'Last synced ${shortDate(live.lastImportedAt ?? live.connectedAt)}',
      ),
      SyncIdle() => (StatusKind.warn, 'Not synced yet'),
    };

    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 2),
      child: Align(
        alignment: Alignment.centerLeft,
        child: StatusWord(key: statusKey, label: label, kind: kind),
      ),
    );
  }
}

/// Apple's request steps and the way back in with the ZIP, inside the deeper
/// group.
class _AppleSteps extends StatelessWidget {
  const _AppleSteps({required this.onOpenAddress});

  final VoidCallback onOpenAddress;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Apple will send you a copy of what you have played. Here is how to '
            'ask for it.',
            style: tokens.body,
          ),
          const SizedBox(height: 12),
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
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: LabelChip(
              key: const Key('choose-apple-files'),
              label: 'Choose files',
              onPressed: () => unawaited(showImportSheet(context)),
            ),
          ),
          Text(appleFileNote, style: tokens.meta),
        ],
      ),
    );
  }
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
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Spotify will send you your listening history. Here is how to ask for it.',
            style: tokens.body,
          ),
          const SizedBox(height: 12),
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

  /// The number column's width, and so the hairline's inset.
  static const double numberColumn = 28;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: MixtapeMetrics.minTarget),
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
            padding: const EdgeInsets.symmetric(vertical: 10),
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
    final body = tokens.body;
    return Text.rich(
      TextSpan(
        style: body,
        children: requestCopySpans(
          text,
          addressText: address,
          address: (address) => InkWell(
            key: linkKey,
            onTap: onOpenAddress,
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
