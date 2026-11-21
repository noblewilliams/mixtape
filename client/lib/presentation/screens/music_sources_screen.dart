/// What the retired "Your music" screen shared with the rest of the app: the
/// pushed Library scaffold, a source's status word and detail, and the removal
/// flow with its copy (September 4 approval,
/// `docs/mockups/approved/2026-09-04-web-your-music-integration.md`).
///
/// The screen itself is gone (add your music board r3/r4, 2026-11-21): the
/// Library tab's "Add music" opens Add your music, where each service's steps
/// carry their own Sync, Import again, Replace and Remove.
library;

import 'package:mixtape/presentation/widgets/foundation/mixtape_feedback.dart';
import 'package:flutter/cupertino.dart'
    show
        CupertinoAlertDialog,
        CupertinoDialogAction,
        CupertinoIcons,
        showCupertinoDialog;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/listening/listening_models.dart';
import '../format/import_format.dart';
import '../format/source_labels.dart';
import '../providers/onboarding_provider.dart';
import '../widgets/foundation/glass_cluster.dart';
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/large_title_scaffold.dart';
import '../widgets/foundation/status_word.dart';

/// What Library says when the sources fail to load.
const String kSourcesLoadFailedTitle = 'Couldn’t load your music';

const _removeFailedMessage = "couldn't remove — try again";

/// A pushed Library screen: the gradient, the glass Back cluster pinned at
/// the top-left by [LargeTitleScaffold.leading], and the large title under it.
class LibraryBackScaffold extends StatelessWidget {
  const LibraryBackScaffold({
    super.key,
    required this.title,
    required this.slivers,
    required this.backKey,
    this.trailing,
    this.controller,
    this.onRefresh,
  });

  final String title;
  final List<Widget> slivers;
  final Key backKey;
  final Widget? trailing;
  final ScrollController? controller;
  final Future<void> Function()? onRefresh;

  /// A row of breathing room under the last row.
  static const double bottomInset = 24;

  @override
  Widget build(BuildContext context) => GradientBackground(
    child: Scaffold(
      backgroundColor: Colors.transparent,
      body: LargeTitleScaffold(
        title: title,
        leading: GlassCluster(
          children: [
            GlassButton(
              key: backKey,
              icon: CupertinoIcons.chevron_left,
              label: 'Back',
              onPressed: () => Navigator.of(context).maybePop(),
            ),
          ],
        ),
        trailing: trailing,
        controller: controller,
        onRefresh: onRefresh,
        slivers: slivers,
      ),
    ),
  );
}

/// The status word a source shows: what actually landed, not that a row
/// exists (same rule as `source_labels.dart`).
({StatusKind kind, String label}) sourceStatusFor(
  MusicSource source,
  OnboardingState state,
) {
  switch (source.source) {
    case 'apple_live':
      return (kind: StatusKind.ok, label: 'Connected');
    case 'spotify_export':
      final label = spotifyStatusLabel(state);
      final ok = label == 'Both in' || label == 'Saved music imported';
      return (kind: ok ? StatusKind.ok : StatusKind.warn, label: label);
    case 'apple_export':
      return source.lastImportedAt == null
          ? (kind: StatusKind.warn, label: 'Waiting')
          : (kind: StatusKind.ok, label: 'Imported');
    default:
      return (kind: StatusKind.ok, label: 'Connected');
  }
}

/// The detail after the status word: when it landed and what it covers.
///
/// Null when the status word already says everything there is (a live Apple
/// library with no snapshot date).
String? sourceDetailFor(MusicSource source) {
  final imported = source.lastImportedAt;
  if (imported == null) {
    return source.source == 'apple_live' ? null : 'Nothing imported yet';
  }
  final ledger = ledgerRange(source.ledgerFrom, source.ledgerTo);
  // The Apple export's own status word is "Imported": saying it twice reads
  // as a stutter, so its detail is the date alone.
  final when = source.source == 'apple_export'
      ? shortDate(imported)
      : 'Imported ${shortDate(imported)}';
  return ledger == null ? when : '$when · $ledger';
}

/// Confirm, delete, and refresh — the September 4 removal flow, behind each
/// Remove on Add your music.
///
/// A failed delete keeps the row and says so on the nearest
/// [ScaffoldMessenger].
Future<void> removeSourceFlow(
  BuildContext context,
  WidgetRef ref,
  MusicSource source,
) async {
  final confirmed = await confirmSourceRemoval(context, source);
  if (confirmed != true || !context.mounted) return;
  try {
    await ref.read(listeningApiProvider).deleteSource(source.source);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        mixtapeSnackBar(
          message: _removeFailedMessage,
          kind: FeedbackKind.error,
        ),
      );
    }
    return;
  }
  await ref.read(onboardingProvider.notifier).refresh();
}

/// The removal confirmation.
///
/// Copy unchanged from the September 4 approval: what goes, what stays.
Future<bool?> confirmSourceRemoval(BuildContext context, MusicSource source) =>
    showCupertinoDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: Text('Remove ${sourceName(source)}?'),
        content: Text(removalCopyFor(source)),
        actions: [
          CupertinoDialogAction(
            key: const Key('remove-keep'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep it'),
          ),
          CupertinoDialogAction(
            key: const Key('remove-confirm'),
            isDestructiveAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

/// Matches what the server's delete does for each source (spec "Schema":
/// the export's rows go; seeds, interview notes, and a live library stay).
String removalCopyFor(MusicSource source) => switch (source.source) {
  'apple_export' =>
    'Deletes the listening history that came from the export. Your synced Apple Music '
        'library stays, and the DJ forgets nothing you told it.',
  _ =>
    'Deletes your listening history, liked songs, artists, and playlists from Mixtape. The '
        'DJ forgets nothing you told it in the interview, and the songs you pasted stay.',
};
