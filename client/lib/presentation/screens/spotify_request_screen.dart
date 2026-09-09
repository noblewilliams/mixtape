import 'import_sheet.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../format/relative_time.dart';
import '../providers/onboarding_provider.dart';
import '../providers/device_providers.dart';

/// The address in step 1, as it reads on screen and where it opens.
const String spotifyPrivacyAddress = 'spotify.com/account/privacy';
final Uri spotifyPrivacyUrl = Uri.parse(
  'https://www.spotify.com/account/privacy/',
);

/// How long after "I've requested it" the inbox reminder fires.
const Duration requestReminderDelay = Duration(days: 3);

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

/// The request flow: the eight steps, what the two emails look like, and
/// "I've requested it". Shown by the service gate as its second step
/// ([onDone] set, "Done, take me to the tapes" at the bottom) and pushed
/// from Home's waiting card for a Spotify listener who has not imported yet
/// ([onDone] null, the AppBar's back button is the way out).
class SpotifyRequestScreen extends ConsumerWidget {
  const SpotifyRequestScreen({super.key, this.onDone});

  final VoidCallback? onDone;

  /// Both effects run detached, like session events: neither the funnel post
  /// nor the reminder can block or fail the tap. The screen moves on when
  /// the notifier's refetch brings back `markedRequestedAt`.
  void _markRequested(WidgetRef ref) {
    unawaited(ref.read(onboardingProvider.notifier).markRequested());
    unawaited(
      ref
          .read(reminderSchedulerProvider)
          .scheduleRequestReminder(after: requestReminderDelay)
          .catchError((Object _) {}),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final markedAt = ref.watch(onboardingProvider).value?.markedRequestedAt;
    final openLink = ref.watch(linkOpenerProvider);
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Bring your Spotify music'),
        automaticallyImplyLeading: onDone == null,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Export your saved music', style: textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text(
                '1. Open Exportify and connect Spotify.\n2. Choose Export All and save the ZIP as it is.\n3. Come back and choose the files. Mixtape will show what it found before importing.',
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(
                    key:const Key('open-exportify'),
                  onPressed: () =>
                      unawaited(openLink(Uri.parse('https://exportify.app/'))),
                  child: const Text('Open Exportify ↗'),
                ),
              ),
              const Text('Opens exportify.app outside Mixtape.'),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                    key:const Key('choose-import-files'),
                  onPressed: () => unawaited(showImportSheet(context)),
                  child: const Text('Choose files'),
                ),
              ),
              const Text(
                'Exportify ZIP or CSV files, or an official Spotify ZIP. Read on this device first; review before uploading.',
              ),
              const SizedBox(height: 16),
              ExpansionTile(
                key:const Key('go-deeper'),
                tilePadding: EdgeInsets.zero,
                title: const Text('Go deeper with your history'),
                subtitle: const Text(
                  'Help the DJ learn your repeat favourites and past listening.',
                ),
                children: [
                  Text(
                    'Spotify will send you your listening history. Here is how to ask for it.',
                    style: textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 16),
                  for (var i = 0; i < spotifyRequestSteps.length; i++)
                    _Step(
                      number: i + 1,
                      text: spotifyRequestSteps[i],
                      onOpenAddress: () =>
                          unawaited(openLink(spotifyPrivacyUrl)),
                    ),
                  const SizedBox(height: 8),
                  Text(spotifyRequestIosNote, style: textTheme.bodyMedium),
                  const SizedBox(height: 24),
                  const _EmailsNote(),
                  const SizedBox(height: 24),
                  if (markedAt != null) ...[
                    Text(
                      'Requested ${elapsedWait(markedAt)}',
                      key: const Key('requested-elapsed'),
                      style: textTheme.titleMedium,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "Spotify's confirmation email comes first. Check your inbox and press "
                      "Confirm if you haven't yet.",
                      style: textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ] else ...[
                    FilledButton(
                      key: const Key('mark-requested'),
                      onPressed: () => _markRequested(ref),
                      child: const Text("I've requested it"),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "We'll remind you in three days to check your inbox.",
                      style: textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
              if (onDone != null) ...[
                const SizedBox(height: 12),
                OutlinedButton(
                  key: const Key('request-done'),
                  onPressed: onDone,
                  child: const Text('Done, take me to the tapes'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.text,
    required this.onOpenAddress,
  });

  final int number;
  final String text;
  final VoidCallback onOpenAddress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = theme.textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 28,
            child: Text(
              '$number.',
              style: body?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                style: body,
                children: requestCopySpans(
                  text,
                  address: (address) => InkWell(
                    key: const Key('link-spotify-privacy'),
                    onTap: onOpenAddress,
                    child: Text(
                      address,
                      style: body?.copyWith(
                        fontWeight: FontWeight.bold,
                        decoration: TextDecoration.underline,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
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

class _EmailsNote extends StatelessWidget {
  const _EmailsNote();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('What the two emails look like', style: textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'First, a confirmation email from Spotify, minutes after you press Request '
              'data. It has a Confirm button. Press it, or nothing is prepared.',
              style: textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Then a "your data is ready" email for each package, each with a Download '
              'button. Two emails, often days apart. Each link lasts about two weeks.',
              style: textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}
