/// "Your music": every connected source with what landed and when, "Import
/// again" on Spotify rows, and "Remove" on the export rows
/// (`docs/mockups/approved/2026-09-04-web-your-music-integration.md`,
/// restyled for `docs/mockups/approved/2026-09-17-mobile-shell.md` → Library
/// by plan task 8.1).
///
/// Reads the same source rows the onboarding state carries (they are the
/// `/me/music-sources` rows), so Home's waiting card, the Library tab and this
/// list never disagree. Pushed from the Library tab's More menu and from an
/// Apple source row.
library;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/listening/listening_models.dart';
import '../format/import_format.dart';
import '../format/source_labels.dart';
import '../providers/onboarding_provider.dart';
import '../theme/mixtape_theme.dart';
import '../widgets/foundation/flush_row.dart';
import '../widgets/foundation/glass_cluster.dart';
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/large_title_scaffold.dart';
import '../widgets/foundation/section_word.dart';
import '../widgets/foundation/square_art.dart';
import '../widgets/foundation/status_word.dart';
import '../widgets/foundation/tape_button.dart';
import '../widgets/foundation/text_action.dart';
import '../widgets/library_sync_sheet.dart';
import 'import_sheet.dart';
import 'playlist_browser_screen.dart';
import 'spotify_request_screen.dart';

const _removeFailedMessage = "couldn't remove — try again";

/// The leading mark's side on a source row (board L1: `--artw:44px`).
const double kSourceMarkSize = 44;

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

/// The 44 pt square mark: the Apple glyph for Apple sources, a note for the
/// rest.
class SourceMark extends StatelessWidget {
  const SourceMark({super.key, required this.source});

  final String source;

  @override
  Widget build(BuildContext context) => SquareArt(
    size: kSourceMarkSize,
    child: Icon(
      source.startsWith('apple') ? Icons.apple : Icons.music_note_outlined,
      size: 22,
      color: context.tokens.text,
    ),
  );
}

/// A source's subtitle: the status word, then the detail after a separator.
///
/// The separator is its own [Text] so the detail line stays one string, and
/// the [Wrap] lets both fall to a second line at large text sizes.
class SourceSubtitle extends StatelessWidget {
  const SourceSubtitle({
    super.key,
    required this.source,
    required this.state,
    this.statusKey,
  });

  final MusicSource source;
  final OnboardingState state;
  final Key? statusKey;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final status = sourceStatusFor(source, state);
    final detail = sourceDetailFor(source);
    final meta = tokens.meta.copyWith(fontSize: 12.5, color: tokens.muted);

    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        StatusWord(key: statusKey, label: status.label, kind: status.kind),
        if (detail != null) ...[
          Text(' · ', style: meta),
          Text(detail, style: meta),
        ],
      ],
    );
  }
}

class MusicSourcesScreen extends ConsumerWidget {
  const MusicSourcesScreen({super.key});

  static const Key backKey = Key('sources-back');
  static const Key syncKey = Key('sources-sync');

  Future<void> _import(BuildContext context, WidgetRef ref) =>
      openImportFlow(context, ref);

  Future<void> _addSpotify(BuildContext context, WidgetRef ref) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const SpotifyRequestScreen()));
    if (context.mounted) {
      await ref.read(onboardingProvider.notifier).refresh();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onboarding = ref.watch(onboardingProvider);
    return LibraryBackScaffold(
      title: 'Your music',
      backKey: backKey,
      trailing: GlassCluster(
        children: [
          GlassButton(
            key: syncKey,
            icon: Icons.sync,
            label: 'Sync library',
            onPressed: () => LibrarySyncSheet.show(context),
          ),
          GlassButton(
            key: const Key('browse-playlists'),
            icon: Icons.queue_music_rounded,
            label: 'Browse playlists',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PlaylistBrowserScreen()),
            ),
          ),
        ],
      ),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.only(
            bottom: LibraryBackScaffold.bottomInset,
          ),
          sliver: SliverToBoxAdapter(child: _body(context, ref, onboarding)),
        ),
      ],
    );
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    AsyncValue<OnboardingState> onboarding,
  ) {
    if (onboarding.hasError && !onboarding.hasValue) {
      return _Centred(
        children: [
          Text(
            "couldn't load your sources",
            textAlign: TextAlign.center,
            style: context.tokens.body,
          ),
          const SizedBox(height: 16),
          TapeButton(
            key: const Key('sources-retry'),
            label: 'Try again',
            onPressed: () => ref.read(onboardingProvider.notifier).refresh(),
          ),
        ],
      );
    }
    final state = onboarding.value;
    if (state == null) {
      // The same quiet stand-in rows the playlists use while they load.
      return const Padding(
        padding: EdgeInsets.only(top: 16),
        child: PlaylistSkeletonRows(rows: 3),
      );
    }
    if (state.sources.isEmpty) {
      return _Centred(
        children: [
          Text(
            'Nothing connected yet.',
            key: const Key('sources-empty'),
            textAlign: TextAlign.center,
            style: context.tokens.body,
          ),
          const SizedBox(height: 8),
          TextAction(
            key: const Key('sources-add-spotify'),
            label: 'Add Spotify music',
            onPressed: () => _addSpotify(context, ref),
          ),
          const SizedBox(height: 16),
          TapeButton(
            key: const Key('sources-import'),
            label: 'Choose Spotify files',
            onPressed: () => _import(context, ref),
          ),
        ],
      );
    }

    final hasSpotify = state.sources.any(
      (source) => source.source == 'spotify_export',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionWord('Sources'),
        FlushList(
          children: [
            for (final source in state.sources)
              SourceRow(
                key: Key('source-${source.source}'),
                source: source,
                state: state,
                onImportAgain: source.source == 'spotify_export'
                    ? () => _import(context, ref)
                    : null,
                onRemove:
                    source.source == 'spotify_export' ||
                        source.source == 'apple_export'
                    ? () => removeSourceFlow(context, ref, source)
                    : null,
              ),
            if (!hasSpotify)
              FlushRow(
                key: const Key('sources-add-spotify'),
                leading: const SizedBox.square(
                  dimension: kSourceMarkSize,
                  child: Center(child: Icon(Icons.add, size: 22)),
                ),
                leadingSize: kSourceMarkSize,
                title: 'Add Spotify music',
                subtitle: 'Bring a Spotify export across',
                onTap: () => _addSpotify(context, ref),
              ),
          ],
        ),
      ],
    );
  }
}

/// Confirm, delete, and refresh — the September 4 removal flow, shared with
/// the Library tab's source sheet.
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text(_removeFailedMessage)));
    }
    return;
  }
  await ref.read(onboardingProvider.notifier).refresh();
}

/// The removal confirmation, shared with the Library tab's source sheet.
///
/// Copy unchanged from the September 4 approval: what goes, what stays.
Future<bool?> confirmSourceRemoval(BuildContext context, MusicSource source) =>
    showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove ${sourceName(source)}?'),
        content: Text(removalCopyFor(source)),
        actions: [
          TextButton(
            key: const Key('remove-keep'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            key: const Key('remove-confirm'),
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

/// One source as a flush row, with its actions underneath.
class SourceRow extends StatelessWidget {
  const SourceRow({
    super.key,
    required this.source,
    required this.state,
    required this.onImportAgain,
    required this.onRemove,
  });

  final MusicSource source;
  final OnboardingState state;
  final VoidCallback? onImportAgain;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final actions = <Widget>[
      if (onImportAgain != null)
        TextAction(
          key: Key('import-again-${source.source}'),
          label: 'Import again',
          onPressed: onImportAgain,
        ),
      if (onRemove != null)
        TextAction(
          key: Key('remove-${source.source}'),
          label: 'Remove',
          quiet: true,
          onPressed: onRemove,
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FlushRow(
          leading: SourceMark(source: source.source),
          leadingSize: kSourceMarkSize,
          title: sourceName(source),
          subtitleWidget: SourceSubtitle(
            source: source,
            state: state,
            statusKey: Key('source-status-${source.source}'),
          ),
        ),
        if (actions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(
              left: kSourceMarkSize + FlushRow.gap - 8,
              bottom: 4,
            ),
            child: Wrap(children: actions),
          ),
      ],
    );
  }
}

class _Centred extends StatelessWidget {
  const _Centred({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 64),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: children,
    ),
  );
}
