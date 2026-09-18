/// "What the DJ knows" (`docs/mockups/approved/2026-09-17-mobile-shell.md` →
/// You; the September 8 parity approval for Forget; plan
/// `docs/superpowers/plans/2026-09-17-native-design-implementation.md` task
/// 8.4).
///
/// Flush rows of remembered notes under the board's large title, with the
/// explicit Forget confirmation and canonical recovery the parity record
/// approved. Explicit confirmation precedes deletion; the provider confirms
/// the result with a canonical read, and the screen never offers to undo a
/// committed delete.
///
/// The More cluster carries what the board put here rather than on a screen
/// of its own: Clear learned listening (the Listening preferences action,
/// copy unchanged) and the taste interview.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_client.dart';
import '../../data/dj/dj_models.dart';
import '../../data/playback/playback_controller.dart' show playbackUuid;
import '../format/relative_time.dart';
import '../providers/auth_provider.dart';
import '../providers/dj_providers.dart';
import '../providers/playback_provider.dart';
import '../theme/mixtape_theme.dart';
import '../widgets/foundation/cassette_tile.dart';
import '../widgets/foundation/glass_cluster.dart';
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/large_title_scaffold.dart';
import '../widgets/foundation/tape_button.dart';
import '../widgets/foundation/text_action.dart';
import 'interview_screen.dart';

class MemoryScreen extends ConsumerStatefulWidget {
  const MemoryScreen({super.key});

  static const Key backKey = Key('memories-back');
  static const Key moreKey = Key('memories-more');
  static const Key clearLearnedKey = Key('memories-clear-learned');
  static const Key interviewKey = Key('memories-interview');
  static const Key retryKey = Key('memories-retry');
  static const Key listKey = Key('memories-list');

  static const String emptyTitle = 'Nothing remembered yet';
  static const String emptyBody =
      'Tell the DJ what you like in a conversation, or in the taste '
      'interview.';

  static const String loadFailed = 'Couldn’t load your notes.';
  static const String uncertainResult =
      'Couldn’t confirm the result. Reload your notes before trying again.';
  static const String expired =
      'Your session expired. Sign in again to manage your notes.';
  static const String tryAgain = 'Try again';
  static const String signInAgain = 'Sign in again';

  static const String clearLearned = 'Clear learned listening';
  static const String tellTheDj = 'Tell the DJ about your taste';

  /// `playback_screen.dart`'s Listening preferences copy, kept word for word.
  static const String clearTitle = 'Clear learned listening?';
  static const String clearBody =
      'Remove listening activity collected for learning. Imported history, '
      'mixes and written preferences stay.';
  static const String cleared = 'Learned listening cleared.';
  static const String clearUnconfirmed =
      'Could not confirm clearing. Retry to check the same request.';

  /// The illustration on the empty state.
  static const double emptyCassetteWidth = 140;

  @override
  ConsumerState<MemoryScreen> createState() => _MemoryScreenState();
}

enum _ForgetResult { forgotten, remains, unknown, stale }

enum _MoreAction { clearLearned, interview }

class _MemoryScreenState extends ConsumerState<MemoryScreen> {
  final _headingFocus = FocusNode(debugLabel: 'Remembered preferences heading');
  bool _dialogOpen = false;
  bool _forgetting = false;
  bool _uncertain = false;
  bool _expiring = false;
  bool _clearing = false;

  /// The same request id is retried, so a lost answer never clears twice.
  String? _clearId;

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

  // --- The More cluster -----------------------------------------------

  Future<void> _openMore(BuildContext anchor) async {
    final box = anchor.findRenderObject();
    final overlay = Navigator.of(context).overlay?.context.findRenderObject();
    if (box is! RenderBox || overlay is! RenderBox) return;
    final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    final action = await showMenu<_MoreAction>(
      context: context,
      position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
      items: const [
        PopupMenuItem(
          key: MemoryScreen.clearLearnedKey,
          value: _MoreAction.clearLearned,
          child: Text(MemoryScreen.clearLearned),
        ),
        PopupMenuItem(
          key: MemoryScreen.interviewKey,
          value: _MoreAction.interview,
          child: Text(MemoryScreen.tellTheDj),
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _MoreAction.clearLearned:
        await _clearLearnedListening();
      case _MoreAction.interview:
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const InterviewScreen()));
    }
  }

  /// The Listening preferences screen's clear, reproduced through the same
  /// controller so there is one implementation of the action, not two.
  Future<void> _clearLearnedListening() async {
    if (_clearing) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog.adaptive(
        title: const Text(MemoryScreen.clearTitle),
        content: const Text(MemoryScreen.clearBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text(MemoryScreen.clearLearned),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _clearing = true);
    _clearId ??= playbackUuid();
    try {
      await ref.read(playbackProvider).clear(_clearId!);
      _clearId = null;
      if (messenger.mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text(MemoryScreen.cleared)),
        );
      }
    } catch (_) {
      if (messenger.mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text(MemoryScreen.clearUnconfirmed)),
        );
      }
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  // --- Chrome ----------------------------------------------------------

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
    final sessionExpired = error is ApiException && error.statusCode == 401;

    return GradientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: LargeTitleScaffold(
          title: 'What the DJ knows',
          onRefresh: _reload,
          // Pinned top-left, as Apple Music's pushed screens carry Back; the
          // trailing cluster rides the same row.
          leading: GlassCluster(
            children: [
              GlassButton(
                key: MemoryScreen.backKey,
                icon: Icons.chevron_left,
                label: 'Back',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ],
          ),
          trailing: GlassCluster(
            children: [
              Builder(
                builder: (anchor) => GlassButton(
                  key: MemoryScreen.moreKey,
                  icon: Icons.more_horiz,
                  label: 'More',
                  onPressed: () => unawaited(_openMore(anchor)),
                ),
              ),
            ],
          ),
          slivers: [
            SliverToBoxAdapter(
              child: Focus(
                focusNode: _headingFocus,
                skipTraversal: true,
                child: const SizedBox.shrink(),
              ),
            ),
            _body(memories, sessionExpired),
          ],
        ),
      ),
    );
  }

  Widget _body(AsyncValue<List<DjMemory>> memories, bool sessionExpired) {
    if (memories.hasError) {
      return _MemoryNotice(
        message: sessionExpired
            ? MemoryScreen.expired
            : _uncertain
            ? MemoryScreen.uncertainResult
            : MemoryScreen.loadFailed,
        action: sessionExpired
            ? MemoryScreen.signInAgain
            : MemoryScreen.tryAgain,
        onAction: sessionExpired
            ? _expireSession
            : () {
                setState(() => _uncertain = false);
                ref.invalidate(memoriesProvider);
              },
      );
    }
    if (!memories.hasValue) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final notes = memories.requireValue;
    if (notes.isEmpty) return const _MemoryEmptyState();

    return SliverList.builder(
      key: MemoryScreen.listKey,
      itemCount: notes.length + 1,
      itemBuilder: (context, index) {
        if (index == notes.length) return const SizedBox(height: 24);
        final memory = notes[index];
        return _MemoryRow(
          key: ValueKey('memory-row-${memory.id}'),
          memory: memory,
          isFirst: index == 0,
          busy: _forgetting,
          onForget: (origin) => _openConfirmation(memory, origin),
        );
      },
    );
  }
}

/// The offline, uncertain and expired states: one line and one tape button.
class _MemoryNotice extends StatelessWidget {
  const _MemoryNotice({
    required this.message,
    required this.action,
    required this.onAction,
  });

  final String message;
  final String action;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 48),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              liveRegion: true,
              child: Text(message, style: tokens.body),
            ),
            const SizedBox(height: 16),
            TapeButton(
              key: MemoryScreen.retryKey,
              label: action,
              onPressed: onAction,
            ),
          ],
        ),
      ),
    );
  }
}

/// Nothing remembered yet: the one cassette on this screen.
class _MemoryEmptyState extends StatelessWidget {
  const _MemoryEmptyState();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Padding(
        padding: const EdgeInsets.only(top: 24, bottom: 48),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CassetteTile(width: MemoryScreen.emptyCassetteWidth),
            const SizedBox(height: 20),
            Text(
              MemoryScreen.emptyTitle,
              style: tokens.section,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              MemoryScreen.emptyBody,
              style: tokens.secondary,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// One remembered note: a 22 pt memory glyph, the note, when it was
/// remembered, and Forget.
class _MemoryRow extends StatefulWidget {
  const _MemoryRow({
    super.key,
    required this.memory,
    required this.isFirst,
    required this.busy,
    required this.onForget,
  });

  final DjMemory memory;
  final bool isFirst;
  final bool busy;
  final ValueChanged<FocusNode> onForget;

  /// The glyph column's width, and so the hairline's inset.
  static const double glyphColumn = 22;
  static const double gap = 14;

  @override
  State<_MemoryRow> createState() => _MemoryRowState();
}

class _MemoryRowState extends State<_MemoryRow> {
  final _focus = FocusNode(debugLabel: 'Forget');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Stack(
      children: [
        if (!widget.isFirst)
          Positioned(
            left: _MemoryRow.glyphColumn + _MemoryRow.gap,
            right: 0,
            top: 0,
            child: Container(height: 1, color: tokens.hairline),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.psychology_outlined,
                  size: _MemoryRow.glyphColumn,
                  color: tokens.plum,
                ),
              ),
              const SizedBox(width: _MemoryRow.gap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.memory.note, style: tokens.body),
                    const SizedBox(height: 2),
                    Text(
                      'remembered ${relativeTime(widget.memory.createdAt)}',
                      style: tokens.meta.copyWith(
                        fontSize: 12.5,
                        color: tokens.muted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Focus(
                key: ValueKey('forget-focus-${widget.memory.id}'),
                focusNode: _focus,
                child: TextAction(
                  key: ValueKey('forget-memory-${widget.memory.id}'),
                  label: 'Forget',
                  onPressed: widget.busy
                      ? null
                      : () => widget.onForget(_focus),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
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
  Widget build(BuildContext context) => AlertDialog.adaptive(
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
