import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_client.dart';
import '../../data/dj/dj_models.dart';
import '../format/relative_time.dart';
import '../providers/auth_provider.dart';
import '../providers/dj_providers.dart';

/// Explicit confirmation precedes deletion. The provider confirms the result
/// with a canonical read; the screen never offers to undo a committed delete.
class MemoryScreen extends ConsumerStatefulWidget {
  const MemoryScreen({super.key});

  @override
  ConsumerState<MemoryScreen> createState() => _MemoryScreenState();
}

enum _ForgetResult { forgotten, remains, unknown, stale }

class _MemoryScreenState extends ConsumerState<MemoryScreen> {
  final _headingFocus = FocusNode(debugLabel: 'Remembered preferences heading');
  bool _dialogOpen = false;
  bool _forgetting = false;
  bool _uncertain = false;
  bool _expiring = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(memoriesProvider.notifier).refresh());
    });
  }

  @override
  void dispose() {
    _headingFocus.dispose();
    super.dispose();
  }

  void _focusHeading() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) {
        _headingFocus.requestFocus();
      }
    });
  }

  Future<void> _expireSession() async {
    if (_expiring || ref.read(authProvider) != AuthStatus.signedIn) return;
    _expiring = true;
    try {
      await ref.read(authProvider.notifier).signOut();
    } catch (_) {
      // The expired-session state remains visible if local sign-out fails.
    } finally {
      if (mounted) _expiring = false;
    }
  }

  Future<void> _openConfirmation(DjMemory memory, FocusNode origin) async {
    if (_dialogOpen || _forgetting) return;
    _dialogOpen = true;
    await showDialog<void>(
      context: context,
      builder: (_) =>
          _ForgetDialog(memory: memory, onConfirm: () => _forget(memory)),
    );
    if (!mounted) return;
    _dialogOpen = false;
    if (origin.context?.mounted ?? false) {
      origin.requestFocus();
    } else {
      _focusHeading();
    }
  }

  Future<_ForgetResult> _forget(DjMemory memory) async {
    if (_forgetting || !ref.read(memoriesProvider.notifier).canForget) {
      return _ForgetResult.stale;
    }
    setState(() {
      _forgetting = true;
      _uncertain = false;
    });
    var forgotten = false;
    try {
      forgotten = await ref.read(memoriesProvider.notifier).forget(memory.id);
    } catch (_) {
      // Keep the draft confirmation retryable if a local failure occurred.
    }
    if (!mounted) return _ForgetResult.stale;
    if (ref.read(authProvider) != AuthStatus.signedIn) {
      setState(() => _forgetting = false);
      return _ForgetResult.stale;
    }
    final unknown = ref.read(memoriesProvider).hasError;
    setState(() {
      _forgetting = false;
      _uncertain = unknown;
    });
    if (!_dialogOpen) _focusHeading();
    if (forgotten) {
      return _ForgetResult.forgotten;
    }
    return unknown ? _ForgetResult.unknown : _ForgetResult.remains;
  }

  Future<void> _reload() async {
    if (_forgetting) return;
    await ref.read(memoriesProvider.notifier).refresh();
    if (!mounted) return;
    if (!ref.read(memoriesProvider).hasError) {
      setState(() => _uncertain = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final memories = ref.watch(memoriesProvider);
    ref.listen(memoriesProvider, (_, next) {
      final error = next.error;
      if (error is ApiException && error.statusCode == 401) {
        unawaited(_expireSession());
      }
    });
    final error = memories.error;
    final expired = error is ApiException && error.statusCode == 401;
    return Scaffold(
      appBar: AppBar(
        title: Focus(
          focusNode: _headingFocus,
          skipTraversal: true,
          child: const Text('What the DJ knows'),
        ),
      ),
      body: SafeArea(
        child: memories.hasError
            ? _MemoryNotice(
                message: expired
                    ? 'Your session expired. Sign in again to manage your notes.'
                    : _uncertain
                    ? 'Couldn’t confirm the result. Reload your notes before trying again.'
                    : 'Couldn’t load your notes.',
                action: expired ? 'Sign in again' : 'Reload notes',
                onAction: expired
                    ? _expireSession
                    : () {
                        setState(() => _uncertain = false);
                        ref.invalidate(memoriesProvider);
                      },
              )
            : !memories.hasValue
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _reload,
                child: memories.requireValue.isEmpty
                    ? const _MemoryNotice(
                        message:
                            'Nothing remembered yet. Tell the DJ “remember…” when a preference should stay with you.',
                      )
                    : ListView.builder(
                        key: const Key('memories-list'),
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 16,
                        ),
                        itemCount: memories.requireValue.length + 1,
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return const Padding(
                              padding: EdgeInsets.only(bottom: 12),
                              child: Text(
                                'Preferences you asked the DJ to remember.',
                              ),
                            );
                          }
                          final memory = memories.requireValue[index - 1];
                          return _MemoryRow(
                            key: ValueKey('memory-row-${memory.id}'),
                            memory: memory,
                            busy: _forgetting,
                            onForget: (origin) =>
                                _openConfirmation(memory, origin),
                          );
                        },
                      ),
              ),
      ),
    );
  }
}

class _MemoryNotice extends StatelessWidget {
  const _MemoryNotice({required this.message, this.action, this.onAction});
  final String message;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => ListView(
    physics: const AlwaysScrollableScrollPhysics(),
    padding: const EdgeInsets.all(24),
    children: [
      Text(message),
      if (action != null)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            key: const Key('memories-retry'),
            onPressed: onAction,
            child: Text(action!),
          ),
        ),
    ],
  );
}

class _MemoryRow extends StatefulWidget {
  const _MemoryRow({
    super.key,
    required this.memory,
    required this.busy,
    required this.onForget,
  });
  final DjMemory memory;
  final bool busy;
  final ValueChanged<FocusNode> onForget;

  @override
  State<_MemoryRow> createState() => _MemoryRowState();
}

class _MemoryRowState extends State<_MemoryRow> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.memory.note),
              const SizedBox(height: 4),
              Text(
                relativeTime(widget.memory.createdAt),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        TextButton(
          key: ValueKey('forget-memory-${widget.memory.id}'),
          focusNode: _focus,
          onPressed: widget.busy ? null : () => widget.onForget(_focus),
          child: const Text('Forget'),
        ),
      ],
    ),
  );
}

class _ForgetDialog extends StatefulWidget {
  const _ForgetDialog({required this.memory, required this.onConfirm});
  final DjMemory memory;
  final Future<_ForgetResult> Function() onConfirm;

  @override
  State<_ForgetDialog> createState() => _ForgetDialogState();
}

class _ForgetDialogState extends State<_ForgetDialog> {
  bool _busy = false;
  bool _failed = false;

  Future<void> _confirm() async {
    if (_busy) return;
    setState(() => _busy = true);
    final result = await widget.onConfirm();
    if (!mounted) return;
    if (result != _ForgetResult.remains) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      _failed = true;
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
    title: const Text('Forget this preference?'),
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.memory.note),
        const SizedBox(height: 16),
        const Text('The DJ will stop using this note.'),
        const SizedBox(height: 4),
        const Text('You can’t undo this.'),
        if (_failed) ...[
          const SizedBox(height: 12),
          const Text('Couldn’t forget this note. Try again.'),
        ],
      ],
    ),
    actions: [
      TextButton(
        autofocus: true,
        onPressed: () => Navigator.of(context).pop(),
        child: Text(_busy ? 'Close' : 'Keep note'),
      ),
      TextButton(
        onPressed: _busy ? null : _confirm,
        child: Text(_busy ? 'Forgetting…' : 'Forget note'),
      ),
    ],
  );
}
