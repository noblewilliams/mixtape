/// "Bring your Spotify music": the Exportify quick start, the official data
/// request, and the checkpoint that starts the wait.
///
/// Behaviour and copy are the September 8 Exportify approval
/// (`docs/mockups/approved/2026-09-08-exportify-import.md`) over the
/// September 4 web import record; plan task 8.7 restyles it onto the
/// September 17 shell (`docs/mockups/approved/2026-09-17-mobile-shell.md`):
/// the large title on the gradient, section words, flush rows, an inset group
/// for the deeper block, and tape/chip/text controls.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../format/relative_time.dart';
import '../providers/device_providers.dart';
import '../providers/onboarding_provider.dart';
import '../theme/mixtape_theme.dart';
import '../widgets/foundation/glass_cluster.dart';
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/inset_group.dart';
import '../widgets/foundation/label_chip.dart';
import '../widgets/foundation/large_title_scaffold.dart';
import '../widgets/foundation/section_word.dart';
import '../widgets/foundation/tape_button.dart';
import '../widgets/foundation/text_action.dart';
import 'import_sheet.dart';

/// The address in step 1, as it reads on screen and where it opens.
const String spotifyPrivacyAddress = 'spotify.com/account/privacy';
final Uri spotifyPrivacyUrl = Uri.parse(
  'https://www.spotify.com/account/privacy/',
);

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

/// What "Choose files" accepts, under the chip.
const String exportifyFileNote =
    'Exportify ZIP or CSV files, or an official Spotify ZIP. Read on this '
    'device first; review before uploading.';

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

/// The request flow: the quick start, the eight official steps, what the two
/// emails look like, and "I've requested it". Shown by the service gate as its
/// second step ([onDone] set, "Done, take me to the tapes" at the bottom) and
/// pushed from Home's waiting card for a Spotify listener who has not imported
/// yet ([onDone] null, the glass back button is the way out).
class SpotifyRequestScreen extends ConsumerStatefulWidget {
  const SpotifyRequestScreen({super.key, this.onDone});

  final VoidCallback? onDone;

  /// The deeper block's disclosure row, and so the way tests open it.
  static const Key goDeeperKey = Key('go-deeper');

  @override
  ConsumerState<SpotifyRequestScreen> createState() =>
      _SpotifyRequestScreenState();
}

class _SpotifyRequestScreenState extends ConsumerState<SpotifyRequestScreen> {
  bool _deeperOpen = false;

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
    final tokens = context.tokens;
    final markedAt = ref.watch(onboardingProvider).value?.markedRequestedAt;
    final openLink = ref.watch(linkOpenerProvider);

    return GradientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: LargeTitleScaffold(
          title: 'Bring your Spotify music',
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
                  const SectionWord('Export your saved music'),
                  for (var i = 0; i < exportifyQuickStartSteps.length; i++)
                    _NumberedRow(
                      number: '${i + 1}',
                      isFirst: i == 0,
                      child: Text(
                        exportifyQuickStartSteps[i],
                        style: tokens.body,
                      ),
                    ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TapeButton(
                      key: const Key('open-exportify'),
                      label: 'Open Exportify ↗',
                      onPressed: () => unawaited(openLink(exportifyUrl)),
                    ),
                  ),
                  Text(
                    'Opens exportify.app outside Mixtape.',
                    style: tokens.meta,
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: LabelChip(
                      key: const Key('choose-import-files'),
                      label: 'Choose files',
                      onPressed: () => unawaited(showImportSheet(context)),
                    ),
                  ),
                  Text(exportifyFileNote, style: tokens.meta),
                  const SizedBox(height: 20),
                  InsetGroup(
                    children: [
                      InsetRow(
                        key: SpotifyRequestScreen.goDeeperKey,
                        title: 'Go deeper with your history',
                        // Collapsed, the row carries the wait so the listener
                        // sees it without opening the block; open, the block's
                        // own line says it and the row goes back to its
                        // description.
                        subtitle: !_deeperOpen && markedAt != null
                            ? 'Requested ${elapsedWait(markedAt)}'
                            : 'Help the DJ learn your repeat favourites and past listening.',
                        trailing: Icon(
                          _deeperOpen
                              ? Icons.expand_less
                              : Icons.expand_more,
                          size: 20,
                          color: tokens.muted,
                        ),
                        onTap: () =>
                            setState(() => _deeperOpen = !_deeperOpen),
                      ),
                      if (_deeperOpen)
                        _DeeperSteps(
                          markedAt: markedAt,
                          onOpenAddress: () =>
                              unawaited(openLink(spotifyPrivacyUrl)),
                          onMarkRequested: _markRequested,
                        ),
                    ],
                  ),
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

/// One official step's `**bold**` / `*italic*` markup, with the address as the
/// one tappable run.
class _StepText extends StatelessWidget {
  const _StepText({required this.text, required this.onOpenAddress});

  final String text;
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
          address: (address) => InkWell(
            key: const Key('link-spotify-privacy'),
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
/// is the address becomes the tappable widget [address] builds.
List<InlineSpan> requestCopySpans(
  String text, {
  required Widget Function(String address) address,
}) {
  final spans = <InlineSpan>[];
  final markup = RegExp(r'\*\*(.+?)\*\*|\*(.+?)\*');
  var last = 0;
  for (final match in markup.allMatches(text)) {
    if (match.start > last) {
      spans.add(TextSpan(text: text.substring(last, match.start)));
    }
    final bold = match.group(1);
    if (bold == spotifyPrivacyAddress) {
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
