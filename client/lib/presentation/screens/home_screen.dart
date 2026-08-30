import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/api/api_client.dart';
import '../../data/dj/dj_api.dart';
import '../../data/dj/dj_models.dart';
import '../providers/auth_provider.dart';
import '../providers/dj_providers.dart';
import '../providers/library_sync_provider.dart';
import 'chat_screen.dart';

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
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _promptController = TextEditingController();
  bool _starting = false;
  String? _error;
  bool _showArchived = false;

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
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
      final sessionId = await ref.read(sessionStarterProvider)(prompt);
      if (!mounted) return;
      _promptController.clear();
      _navigateToChat(sessionId);
    } on DjApiException catch (e) {
      if (!mounted) return;
      final sessionId = e.sessionId;
      if (sessionId != null) {
        // The session row persisted despite the turn failing — Home's job
        // is done; ChatScreen owns showing the error/retry affordance.
        _promptController.clear();
        _navigateToChat(sessionId);
      } else {
        setState(() => _error = e.message);
      }
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

  void _navigateToChat(String sessionId) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ChatScreen(sessionId: sessionId)),
    );
  }

  void _openSyncSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _LibrarySyncSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sessionsAsync = ref.watch(sessionsProvider);
    final sync = ref.watch(librarySyncProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('mixtape'),
        actions: [
          IconButton(
            key: const Key('sync-action'),
            tooltip: 'Sync library',
            icon: sync is SyncRunning
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            onPressed: _openSyncSheet,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(authProvider.notifier).signOut(),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const Key('prompt-field'),
                    controller: _promptController,
                    enabled: !_starting,
                    minLines: 1,
                    maxLines: 3,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _submit(),
                    decoration: const InputDecoration(
                      hintText: "what's the moment?",
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(16)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton(
                    key: const Key('start-session'),
                    onPressed: _starting ? null : _submit,
                    child: _starting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Start the tape'),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      key: const Key('start-error'),
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: switch (sessionsAsync) {
                AsyncData(:final value) => _SessionsList(
                    sessions: value,
                    showArchived: _showArchived,
                    onToggleArchived: () =>
                        setState(() => _showArchived = !_showArchived),
                    onTapSession: _navigateToChat,
                  ),
                AsyncError() => const Center(
                    child: Text("couldn't load your sessions"),
                  ),
                _ => const Center(child: CircularProgressIndicator()),
              },
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
    required this.onToggleArchived,
    required this.onTapSession,
  });

  final List<DjSession> sessions;
  final bool showArchived;
  final VoidCallback onToggleArchived;
  final ValueChanged<String> onTapSession;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final archived = archivedSessions(sessions);
    final visible = showArchived ? sessions : nonArchivedSessions(sessions);
    final hasToggle = archived.isNotEmpty;

    if (visible.isEmpty && !hasToggle) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No sessions yet — tell the DJ what you want to hear.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
    }

    return ListView.builder(
      key: const Key('sessions-list'),
      itemCount: visible.length + (hasToggle ? 1 : 0),
      itemBuilder: (context, index) {
        if (hasToggle && index == 0) {
          return TextButton(
            key: const Key('toggle-archived'),
            onPressed: onToggleArchived,
            child: Text(
              showArchived ? 'Hide archived' : 'Show archived (${archived.length})',
            ),
          );
        }
        final session = visible[index - (hasToggle ? 1 : 0)];
        return ListTile(
          key: Key('session-${session.id}'),
          title: Text(session.title),
          subtitle: Text(_relativeTime(session.updatedAt)),
          onTap: () => onTapSession(session.id),
          trailing: session.status == 'archived'
              ? null
              : IconButton(
                  key: Key('archive-${session.id}'),
                  tooltip: 'Archive',
                  icon: const Icon(Icons.archive_outlined),
                  onPressed: () => ref.read(sessionsProvider.notifier).archive(session.id),
                ),
        );
      },
    );
  }
}

String _relativeTime(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return '${dt.month}/${dt.day}/${dt.year}';
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
                Text(progress == 0 ? 'Syncing…' : 'Syncing… ${(progress * 100).round()}%'),
              ],
            ),
          SyncDone(:final total) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Synced $total ${total == 1 ? 'song' : 'songs'}. The DJ is listening.',
                  textAlign: TextAlign.center,
                ),
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
