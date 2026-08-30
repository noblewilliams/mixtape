import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/dj/dj_models.dart';
import '../format/relative_time.dart';
import '../providers/dj_providers.dart';

const _forgetFailedMessage = "couldn't forget that — try again";
const _forgottenMessage = 'forgot that';
const _refreshFailedMessage = "couldn't refresh — showing what we had";

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
/// snackbar expire (or get superseded) actually commits the delete.
///
/// At most ONE undo window is ever open at a time (see [_handleDismiss]):
/// [ScaffoldMessenger] queues a second `showSnackBar` behind the first
/// rather than showing it immediately, which would otherwise mean a rapid
/// second swipe's undo window doesn't even START until the first one's
/// snackbar finishes — stacking up hidden, undeleted rows and multiplying
/// this screen's exposure to the unmounted-callback hazard described below.
/// Instead, a new swipe immediately FINALIZES whatever forget was still
/// pending (firing its DELETE right then — its undo chance is over) and
/// hides the current snackbar before showing its own, so exactly one undo
/// window is ever in flight and every commit happens promptly.
///
/// A dismissed id lives in `_pendingIds` for as long as its row must stay
/// hidden: from the swipe until Undo restores it, or until the commit (via
/// [_finalize]) resolves — success prunes it (the row is gone from the
/// provider's list too by then), failure also prunes it but then restores
/// the row by simply letting it reappear (the provider's list still has it).
///
/// [_finalize] (and the `closed`-future callback that normally invokes it)
/// must be safe to run after this screen has been popped: the
/// [ScaffoldMessenger] that owns the snackbar is scoped to the app's root
/// navigator, not this route, so its `closed` future keeps this callback
/// alive well past this State's `dispose()`. The actual DELETE MUST still
/// fire in that case — the undo window elapsed, so the user's intent to
/// forget is settled regardless of whether anyone is still looking at this
/// screen — but nothing UI-side (`setState`, reading `context`) may run once
/// unmounted. That's why the [MemoriesNotifier] instance is captured
/// SYNCHRONOUSLY in [_handleDismiss] (before the snackbar even shows) rather
/// than re-read via `ref.read` from inside the async callback: the notifier
/// object itself stays perfectly valid to call after this State is disposed
/// (it owns its own long-lived `ref` into the provider, unrelated to this
/// widget's), whereas `ref.read` from a disposed [ConsumerState] throws.
class MemoryScreen extends ConsumerStatefulWidget {
  const MemoryScreen({super.key});

  @override
  ConsumerState<MemoryScreen> createState() => _MemoryScreenState();
}

/// One in-flight forget: the row it's for, the notifier captured at swipe
/// time (see the class doc above), and whether it's already been settled —
/// either by an Undo tap or by [_MemoryScreenState._finalize] — so a
/// superseding swipe and the original snackbar's own `closed` future can
/// both eventually try to finalize the very same pending row without ever
/// firing its DELETE twice.
class _PendingForget {
  _PendingForget(this.memory, this.notifier);

  final DjMemory memory;
  final MemoriesNotifier notifier;
  bool settled = false;
}

class _MemoryScreenState extends ConsumerState<MemoryScreen> {
  /// Rows optimistically hidden pending the undo window's outcome — mirrors
  /// queue_screen's `_hiddenTrackIds` in spirit (Dismissible requires the
  /// swiped item gone from the very next build), but these are lifted only
  /// by an explicit Undo tap or [_finalize] resolving (success or failure),
  /// never by a settle that happens on its own.
  final Set<String> _pendingIds = {};

  /// At most one entry: the forget still waiting out its undo window. See
  /// the class doc for the at-most-one-pending contract.
  _PendingForget? _pending;

  @override
  void initState() {
    super.initState();
    // The provider is built once per auth session (not autoDispose) and
    // never refetches on its own, so reopening this screen on a warm
    // container would otherwise show a stale list forever — e.g. a
    // preference stated in a chat session just now wouldn't show up here
    // until sign-out/in. Fired post-frame (not inline here) so it never
    // races this State's own first build; failure is silent by design here
    // — the cached list is still shown either way, and the RefreshIndicator
    // below gives an explicit, failure-surfacing retry.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(memoriesProvider.notifier).refresh());
    });
  }

  void _handleDismiss(DjMemory memory) {
    final messenger = ScaffoldMessenger.of(context);

    // A new swipe supersedes whatever was still pending: its undo chance is
    // over, so finalize it (firing the DELETE right now, not waiting out
    // its window) and clear its snackbar before this one's shows — see the
    // class doc's at-most-one-pending contract.
    final previous = _pending;
    if (previous != null) {
      messenger.hideCurrentSnackBar();
      unawaited(_finalize(previous));
    }

    setState(() => _pendingIds.add(memory.id));

    // Captured synchronously, before any await — see the class doc for why
    // this (not a `ref.read` inside the async callback below) is what makes
    // the eventual DELETE safe to fire after this screen is popped.
    final notifier = ref.read(memoriesProvider.notifier);
    final pending = _PendingForget(memory, notifier);
    _pending = pending;

    final controller = messenger.showSnackBar(
      SnackBar(
        content: const Text(_forgottenMessage),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            pending.settled = true;
            if (identical(_pending, pending)) _pending = null;
            _pendingIds.remove(memory.id);
            if (mounted) setState(() {});
          },
        ),
      ),
    );

    controller.closed.then((_) async {
      try {
        await _finalize(pending);
      } catch (_) {
        // Never let an unhandled async error escape this detached
        // callback — by the time this runs the route may already be
        // gone, and per the class doc that must not stop the DELETE
        // above from having fired.
      }
    });
  }

  /// The single place a pending forget's DELETE actually fires — from
  /// either the snackbar's own `closed` future (the normal path) or a
  /// superseding swipe finalizing it early (see [_handleDismiss]). Guarded
  /// by [_PendingForget.settled] so whichever of those two call sites gets
  /// there first is the only one that does anything.
  Future<void> _finalize(_PendingForget pending) async {
    if (pending.settled) return;
    pending.settled = true;
    if (identical(_pending, pending)) _pending = null;

    // The DELETE must fire regardless of whether this screen is still
    // mounted (the undo window is over — that intent is settled either
    // way); only the UI reconciliation below is conditional on it.
    final ok = await pending.notifier.forget(pending.memory.id);
    if (!mounted) return;

    if (ok) {
      // Prune the now-committed id rather than leaving it in _pendingIds
      // forever — harmless either way (the provider's own list no longer
      // has it, so `visible`'s filter is a no-op for this id going
      // forward), but pruning is what actually keeps this set bounded to
      // rows genuinely still in flight.
      setState(() => _pendingIds.remove(pending.memory.id));
    } else {
      setState(() => _pendingIds.remove(pending.memory.id));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text(_forgetFailedMessage)));
    }
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
        child: RefreshIndicator(
          // Mirrors home_screen.dart's pull-to-refresh: refresh() never
          // throws (AsyncValue.guard-wrapped) and a failure keeps showing
          // the previously-good list via copyWithPrevious, so without this
          // snackbar the spinner would retract indistinguishably from
          // "refreshed, nothing changed" — the one thing pulling was meant
          // to find out.
          onRefresh: () async {
            final ok = await ref.read(memoriesProvider.notifier).refresh();
            if (!ok && context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text(_refreshFailedMessage)),
              );
            }
          },
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
    // A scrollable (not a bare Center) so the enclosing RefreshIndicator
    // still hooks pull-to-refresh — mirrors home_screen.dart's
    // sessions-empty state for the same reason: an empty list still needs a
    // manual way to retry.
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        Padding(
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
      ],
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
