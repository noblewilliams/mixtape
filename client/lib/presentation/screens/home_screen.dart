import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/api/api_client.dart';
import '../../data/dj/dj_api.dart';
import '../../data/dj/dj_models.dart';
import '../format/relative_time.dart';
import '../providers/auth_provider.dart';
import '../providers/dj_providers.dart';
import '../providers/library_sync_provider.dart';
import 'chat_screen.dart';
import 'memory_screen.dart';

const _archiveFailedMessage = "couldn't archive — try again";
const _unarchiveFailedMessage = "couldn't unarchive — try again";
const _refreshFailedMessage = "couldn't refresh — showing what we had";
const _renameFailedMessage = "couldn't rename — try again";

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
        // is done; ChatScreen owns showing the error/retry affordance
        // (seeded from e.message via initialError, since the failed turn
        // never made it into the transcript itself).
        _promptController.clear();
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
            key: const Key('memories-action'),
            tooltip: 'What the DJ knows',
            icon: const Icon(Icons.psychology_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const MemoryScreen()),
            ),
          ),
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
            // Sign-out is only reachable from here — Home is the sole
            // screen that pushes ChatScreen/QueueScreen, and those pushed
            // routes are never popped on an auth transition (only the
            // ProviderScope container gets rebuilt/reset — see
            // dj_providers.dart's auth-transition-safety note). That makes
            // "sign-out only happens from Home" a load-bearing invariant:
            // adding a sign-out entry point from a pushed screen would need
            // its own route-popping story first.
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
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _promptController,
                    builder: (context, value, _) {
                      // Same treatment as ChatScreen's composer: cap at the
                      // server's 2000, but only surface the counter once the
                      // draft is close enough (>1800) for it to matter.
                      final showCounter = value.text.length > 1800;
                      return TextField(
                        key: const Key('prompt-field'),
                        controller: _promptController,
                        enabled: !_starting,
                        minLines: 1,
                        maxLines: 3,
                        maxLength: 2000,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          hintText: "what's the moment?",
                          counterText: showCounter ? null : '',
                          border: const OutlineInputBorder(
                            borderRadius: BorderRadius.all(Radius.circular(16)),
                          ),
                        ),
                      );
                    },
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
            Expanded(child: _buildSessionsBody(sessionsAsync)),
          ],
        ),
      ),
    );
  }

  /// Mirrors ChatScreen's `hasError && !hasValue` pattern (see
  /// chat_screen.dart's build() comment): only fall back to the full-screen
  /// error+retry state when there's truly nothing else to show. A failed
  /// background refresh with a previously-good list on hand keeps showing
  /// that list rather than blanking it out — the RefreshIndicator wrapping
  /// it gives manual pull-to-refresh, and refresh() itself never throws
  /// (AsyncValue.guard-wrapped), so this never leaks an unhandled error.
  Widget _buildSessionsBody(AsyncValue<List<DjSession>> sessionsAsync) {
    if (sessionsAsync.hasError && !sessionsAsync.hasValue) {
      // invalidate (not refresh()) here specifically: reaching this branch
      // means build() itself just failed, which per chat_screen.dart's
      // build() comment leaves Riverpod's own retry backoff scheduled on
      // this element. invalidate() replaces the element outright, so that
      // pending backoff Timer is cancelled rather than left dangling —
      // refresh() would instead race it (and, in tests, trip the
      // pending-timer-at-teardown invariant).
      return _SessionsErrorState(onRetry: () => ref.invalidate(sessionsProvider));
    }
    if (!sessionsAsync.hasValue) {
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      // A failed refetch keeps the previous list (copyWithPrevious), so
      // without the snackbar the spinner would retract indistinguishably
      // from "refreshed, nothing changed" — the one thing the user pulled
      // to find out.
      onRefresh: () async {
        final ok = await ref.read(sessionsProvider.notifier).refresh();
        if (!ok && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text(_refreshFailedMessage)),
          );
        }
      },
      child: _SessionsList(
        sessions: sessionsAsync.value!,
        showArchived: _showArchived,
        onToggleArchived: () => setState(() => _showArchived = !_showArchived),
        onTapSession: _navigateToChat,
      ),
    );
  }
}

class _SessionsErrorState extends StatelessWidget {
  const _SessionsErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            const Text("couldn't load your sessions", textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              key: const Key('sessions-retry'),
              onPressed: onRetry,
              child: const Text('Try again'),
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
      // A scrollable (not a bare Center) so the enclosing RefreshIndicator
      // still hooks pull-to-refresh — a user whose list came back empty
      // needs a manual way to refetch too.
      return ListView(
        key: const Key('sessions-empty'),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.all(48),
            child: Text(
              'No sessions yet — tell the DJ what you want to hear.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
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
        final isArchived = session.status == 'archived';
        final theme = Theme.of(context);
        return ListTile(
          key: Key('session-${session.id}'),
          title: Text(
            session.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // Subtle dim on archived rows — the trailing action and the
            // "Archived · " subtitle prefix below carry the rest of the
            // distinction, this just keeps it visually de-emphasized in a
            // mixed (toggled-open) list.
            style: isArchived
                ? TextStyle(color: theme.colorScheme.onSurfaceVariant)
                : null,
          ),
          subtitle: Text(
            isArchived
                ? 'Archived · ${relativeTime(session.updatedAt)}'
                : relativeTime(session.updatedAt),
          ),
          onTap: () => onTapSession(session.id),
          onLongPress: () => _showRenameDialog(context, ref, session),
          trailing: IconButton(
            key: Key(isArchived ? 'unarchive-${session.id}' : 'archive-${session.id}'),
            tooltip: isArchived ? 'Unarchive' : 'Archive',
            icon: Icon(isArchived ? Icons.unarchive_outlined : Icons.archive_outlined),
            onPressed: () => _setArchived(context, ref, session.id, archived: !isArchived),
          ),
        );
      },
    );
  }

  /// Long-press affordance for a manual rename: a dialog prefilled with the
  /// row's current title, disabled while empty/whitespace-only (trimmed
  /// before both the disabled-check and the actual call), calling
  /// [SessionsNotifier.rename] on confirm. A failure leaves the row's title
  /// untouched and shows a retry snackbar — same hardening as
  /// [_setArchived] below. The dialog's own [TextEditingController] is owned
  /// by [_RenameDialog]'s State (see its doc comment) — NOT disposed here —
  /// so it stays alive through the dialog's exit transition.
  Future<void> _showRenameDialog(
    BuildContext context,
    WidgetRef ref,
    DjSession session,
  ) async {
    final newTitle = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _RenameDialog(initialTitle: session.title),
    );
    if (newTitle == null || !context.mounted) return;

    final ok = await ref.read(sessionsProvider.notifier).rename(session.id, newTitle);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text(_renameFailedMessage)));
    }
  }

  Future<void> _setArchived(
    BuildContext context,
    WidgetRef ref,
    String id, {
    required bool archived,
  }) async {
    final notifier = ref.read(sessionsProvider.notifier);
    final ok = archived ? await notifier.archive(id) : await notifier.unarchive(id);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(archived ? _archiveFailedMessage : _unarchiveFailedMessage)),
      );
    }
  }
}

/// The rename dialog's own content, as a dedicated [StatefulWidget] so its
/// [TextEditingController] is owned by ITS State — created in [initState],
/// disposed in [dispose] — rather than a local variable [_showRenameDialog]
/// disposes manually right after `showDialog`'s Future resolves. That manual
/// pattern races the dialog ROUTE's own exit transition: `showDialog`
/// resolves as soon as `Navigator.pop` is called, but the closing dialog's
/// widget tree (fade-out) is still rebuilding for a few more frames after
/// that — disposing the controller immediately throws "A TextEditingController
/// was used after being disposed." Tying disposal to this widget's own
/// lifecycle instead means Flutter only disposes it once the dialog element
/// is well and truly gone.
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initialTitle});

  final String initialTitle;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialTitle,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _controller,
      builder: (context, value, _) {
        final canConfirm = value.text.trim().isNotEmpty;
        return AlertDialog(
          title: const Text('Rename session'),
          content: TextField(
            key: const Key('rename-field'),
            controller: _controller,
            autofocus: true,
            maxLength: 120,
            decoration: const InputDecoration(hintText: 'Session name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('rename-confirm'),
              onPressed: canConfirm
                  ? () => Navigator.of(context).pop(_controller.text.trim())
                  : null,
              child: const Text('Rename'),
            ),
          ],
        );
      },
    );
  }
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
