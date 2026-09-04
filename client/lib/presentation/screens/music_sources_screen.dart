import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/listening/listening_models.dart';
import '../format/import_format.dart';
import '../format/source_labels.dart';
import '../providers/onboarding_provider.dart';
import 'import_sheet.dart';

const _removeFailedMessage = "couldn't remove — try again";

/// "Your music": every connected source with what landed and when, "Import
/// again" on Spotify rows, and "Remove" on the export rows. Reads the same
/// source rows the onboarding state carries (they are the `/me/music-sources`
/// rows), so Home's waiting card and this list never disagree. Pushed by
/// Home; the only route it opens itself is the import sheet.
class MusicSourcesScreen extends ConsumerWidget {
  const MusicSourcesScreen({super.key});

  Future<void> _import(BuildContext context, WidgetRef ref) => openImportFlow(context, ref);

  Future<void> _remove(BuildContext context, WidgetRef ref, MusicSource source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove ${sourceName(source)}?'),
        content: Text(_removalCopy(source)),
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
    if (confirmed != true || !context.mounted) return;
    try {
      await ref.read(listeningApiProvider).deleteSource(source.source);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(_removeFailedMessage)),
        );
      }
      return;
    }
    await ref.read(onboardingProvider.notifier).refresh();
  }

  /// Matches what the server's delete does for each source (spec "Schema":
  /// the export's rows go; seeds, interview notes, and a live library stay).
  static String _removalCopy(MusicSource source) => switch (source.source) {
        'apple_export' =>
          'Deletes the listening history that came from the export. Your synced Apple Music '
              'library stays, and the DJ forgets nothing you told it.',
        _ =>
          'Deletes your listening history, liked songs, artists, and playlists from Mixtape. The '
              'DJ forgets nothing you told it in the interview, and the songs you pasted stay.',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onboarding = ref.watch(onboardingProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Your music')),
      body: SafeArea(child: _body(context, ref, onboarding)),
    );
  }

  Widget _body(BuildContext context, WidgetRef ref, AsyncValue<OnboardingState> onboarding) {
    if (onboarding.hasError && !onboarding.hasValue) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("couldn't load your sources"),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('sources-retry'),
              onPressed: () => ref.read(onboardingProvider.notifier).refresh(),
              child: const Text('Try again'),
            ),
          ],
        ),
      );
    }
    final state = onboarding.value;
    if (state == null) return const Center(child: CircularProgressIndicator());
    if (state.sources.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Nothing connected yet.', key: Key('sources-empty')),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('sources-import'),
                onPressed: () => _import(context, ref),
                child: const Text('Import a Spotify ZIP'),
              ),
            ],
          ),
        ),
      );
    }
    return ListView(
      children: [
        for (final source in state.sources)
          _SourceRow(
            key: Key('source-${source.source}'),
            source: source,
            status: source.source == 'spotify_export' ? spotifyStatusLabel(state) : null,
            onImportAgain: source.source == 'spotify_export' ? () => _import(context, ref) : null,
            onRemove: source.source == 'spotify_export' || source.source == 'apple_export'
                ? () => _remove(context, ref, source)
                : null,
          ),
      ],
    );
  }
}

class _SourceRow extends StatelessWidget {
  const _SourceRow({
    super.key,
    required this.source,
    required this.status,
    required this.onImportAgain,
    required this.onRemove,
  });

  final MusicSource source;
  final String? status;
  final VoidCallback? onImportAgain;
  final VoidCallback? onRemove;

  String get _detail {
    final imported = source.lastImportedAt;
    if (imported == null) return 'Nothing imported yet';
    final ledger = ledgerRange(source.ledgerFrom, source.ledgerTo);
    final when = 'Imported ${shortDate(imported)}';
    return ledger == null ? when : '$when · $ledger';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(sourceName(source), style: theme.textTheme.titleMedium)),
              if (status != null)
                Chip(
                  key: Key('source-status-${source.source}'),
                  label: Text(status!),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          Text(_detail, style: theme.textTheme.bodySmall),
          if (onImportAgain != null || onRemove != null)
            Row(
              children: [
                if (onImportAgain != null)
                  TextButton(
                    key: Key('import-again-${source.source}'),
                    onPressed: onImportAgain,
                    child: const Text('Import again'),
                  ),
                if (onRemove != null)
                  TextButton(
                    key: Key('remove-${source.source}'),
                    onPressed: onRemove,
                    style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                    child: const Text('Remove'),
                  ),
              ],
            ),
          const Divider(height: 1),
        ],
      ),
    );
  }
}
