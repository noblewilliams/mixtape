import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/dj/dj_models.dart';
import '../format/relative_time.dart';
import '../providers/dj_providers.dart';

const _forgetFailedMessage = "couldn't forget that — try again";
const _forgottenMessage = 'forgot that';

/// "What the DJ knows" (see
/// `docs/superpowers/plans/2026-08-30-p4-taste-learning.md` Task 4): lists
/// [DjMemory] notes newest-first over [memoriesProvider], with swipe-to-
/// forget over a deferred-commit undo window.
///
/// The undo model is deliberately NOT the same as queue_screen's
/// settle-based hiding (that screen is server-canonical throughout — every
/// dismissal immediately posts an op and un-hides only when the response
/// lands). Here the row is hidden immediately on swipe, same Dismissible
/// requirement, but the DELETE itself is deferred behind a 5s undo window:
/// tapping Undo cancels it with NO server call at all, and only letting the
/// snackbar expire (or get superseded) actually commits the delete. So a
/// dismissed id lives in [_pendingIds] the whole time the snackbar is up —
/// on Undo it's simply removed (no network round trip involved); on commit
/// [MemoriesNotifier.forget] fires the DELETE and, only on success, drops it
/// from the provider's own list — a failure instead restores the row here.
class MemoryScreen extends ConsumerStatefulWidget {
  const MemoryScreen({super.key});

  @override
  ConsumerState<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends ConsumerState<MemoryScreen> {
  /// Rows optimistically hidden pending the undo window's outcome — mirrors
  /// queue_screen's `_hiddenTrackIds` in spirit (Dismissible requires the
  /// swiped item gone from the very next build), but these are lifted only
  /// by an explicit Undo tap or a failed commit, never by a settle that
  /// happens on its own.
  final Set<String> _pendingIds = {};

  void _handleDismiss(DjMemory memory) {
    setState(() => _pendingIds.add(memory.id));

    // Flipped by the Undo action below; read only after `closed` resolves,
    // by which point Dart's single-threaded event loop guarantees any Undo
    // tap has already run (SnackBarAction hides the bar — and so completes
    // `closed` — only AFTER its own onPressed callback returns).
    var undone = false;

    final messenger = ScaffoldMessenger.of(context);
    final controller = messenger.showSnackBar(
      SnackBar(
        content: const Text(_forgottenMessage),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            undone = true;
            if (mounted) setState(() => _pendingIds.remove(memory.id));
          },
        ),
      ),
    );

    controller.closed.then((_) async {
      if (undone) return; // cancelled — no server call, ever.
      final ok = await ref.read(memoriesProvider.notifier).forget(memory.id);
      if (!mounted) return;
      if (!ok) {
        setState(() => _pendingIds.remove(memory.id));
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text(_forgetFailedMessage)));
      }
      // Success: the row's id stays in _pendingIds (harmless — the notifier
      // has already dropped it from the underlying list too) until the next
      // rebuild reconciles both away together; nothing further to do here.
    });
  }

  @override
  Widget build(BuildContext context) {
    final memoriesAsync = ref.watch(memoriesProvider);

    if (memoriesAsync.hasError && !memoriesAsync.hasValue) {
      return _MemoryErrorScreen(onRetry: () => ref.invalidate(memoriesProvider));
    }

    if (!memoriesAsync.hasValue) {
      return Scaffold(
        appBar: AppBar(title: const Text('What the DJ knows')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final visible = memoriesAsync.value!
        .where((m) => !_pendingIds.contains(m.id))
        .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('What the DJ knows')),
      body: SafeArea(
        child: visible.isEmpty
            ? const _EmptyMemories()
            : ListView.builder(
                key: const Key('memories-list'),
                itemCount: visible.length,
                itemBuilder: (context, index) {
                  final memory = visible[index];
                  return _MemoryRow(
                    key: ValueKey('memory-row-${memory.id}'),
                    memory: memory,
                    onDismissed: () => _handleDismiss(memory),
                  );
                },
              ),
      ),
    );
  }
}

class _MemoryErrorScreen extends StatelessWidget {
  const _MemoryErrorScreen({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('What the DJ knows')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 48, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 16),
              const Text("couldn't load what the DJ knows", textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('memories-retry'),
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyMemories extends StatelessWidget {
  const _EmptyMemories();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.psychology_outlined, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            const Text(
              "the DJ hasn't learned anything yet — tell it what you like in a session",
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _MemoryRow extends StatelessWidget {
  const _MemoryRow({super.key, required this.memory, required this.onDismissed});

  final DjMemory memory;
  final VoidCallback onDismissed;

  Widget _dismissBackground(ThemeData theme, Alignment alignment) => Container(
        color: theme.colorScheme.errorContainer,
        alignment: alignment,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Icon(Icons.delete_outline, color: theme.colorScheme.onErrorContainer),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dismissible(
      key: ValueKey('dismissible-memory-${memory.id}'),
      background: _dismissBackground(theme, Alignment.centerLeft),
      secondaryBackground: _dismissBackground(theme, Alignment.centerRight),
      onDismissed: (_) => onDismissed(),
      child: Material(
        color: theme.colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(memory.note),
              const SizedBox(height: 4),
              Text(
                relativeTime(memory.createdAt),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
