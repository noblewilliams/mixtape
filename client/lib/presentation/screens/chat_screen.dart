import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/dj_providers.dart';
import '../widgets/queue_card.dart';

/// The DJ conversation for one session (see
/// `docs/superpowers/plans/2026-08-29-p3b-dj-client.md` Task 4): transcript
/// + inline queue card + composer, over [chatProvider].
class ChatScreen extends ConsumerStatefulWidget {
  const ChatScreen({super.key, required this.sessionId, this.initialError});

  final String sessionId;

  /// Set only when Home navigates here after a create-session failure that
  /// still persisted a session row (see `dj_providers.dart`'s
  /// `sessionStarterProvider` doc comment) — the server's error message,
  /// which never made it into the transcript itself. Seeded once, as a
  /// synthetic error bubble, right after the initial load (see
  /// [_ChatScreenState.build]'s `ref.listen`). Does not change the
  /// screen's contract otherwise: every other caller passes null.
  final String? initialError;

  @override
  ConsumerState<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends ConsumerState<ChatScreen> {
  final _scrollController = ScrollController();
  final _textController = TextEditingController();

  int _lastMessageCount = -1;
  Timer? _listeningTimer;
  bool _showListeningCaption = false;
  bool _seededInitialError = false;

  @override
  void dispose() {
    _scrollController.dispose();
    _textController.dispose();
    _listeningTimer?.cancel();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  void _startListeningTimer() {
    _showListeningCaption = false;
    _listeningTimer?.cancel();
    _listeningTimer = Timer(const Duration(seconds: 10), () {
      if (mounted) setState(() => _showListeningCaption = true);
    });
  }

  void _cancelListeningTimer() {
    _listeningTimer?.cancel();
    _listeningTimer = null;
    _showListeningCaption = false;
  }

  /// Unforeseen-exception guard: [ChatNotifier.send] already resolves every
  /// error type it knows about into an error bubble and never rethrows —
  /// this catch-all exists purely so an entirely unanticipated exception
  /// can't become an unhandled async error with a bricked composer.
  ///
  /// [fromComposer] gates clearing the draft: true when the composer's own
  /// send button/submit fired this (the just-sent text IS the draft, safe
  /// to clear), false for a retry (which resends a DIFFERENT, already-sent
  /// turn's text — clearing the controller here would silently wipe
  /// whatever new draft the user has since started typing).
  Future<void> _send(String text, {bool fromComposer = false}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (fromComposer) _textController.clear();
    try {
      await ref.read(chatProvider(widget.sessionId).notifier).send(trimmed);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('something unexpected happened')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final chatAsync = ref.watch(chatProvider(widget.sessionId));

    ref.listen(chatProvider(widget.sessionId), (previous, next) {
      final state = next.value;
      if (state == null) return;

      // Display guarded on being the top route: QueueScreen watches the
      // same provider and runs the same listener, so with the queue pushed
      // over this screen one error would otherwise queue two identical
      // snackbars. Clearing is unconditional — a transientError left in
      // state gets carried forward by copyWith and would surface later
      // against an unrelated event. Both listeners see the same captured
      // `state`, so either clearing first can't hide it from the other.
      if (state.transientError != null) {
        if (ModalRoute.of(context)?.isCurrent == true) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(state.transientError!)));
        }
        ref.read(chatProvider(widget.sessionId).notifier).clearTransientError();
      }

      // One-shot: fires on the first state this listener ever sees with a
      // value (i.e. right after the initial load resolves), guarded by
      // _seededInitialError so a later rebuild (background refresh, a sent
      // turn, ...) can never re-seed a duplicate bubble.
      if (!_seededInitialError && widget.initialError != null) {
        _seededInitialError = true;
        ref
            .read(chatProvider(widget.sessionId).notifier)
            .seedInitialError(widget.initialError!);
      }

      final wasSending = previous?.value?.sending ?? false;
      if (state.sending && !wasSending) {
        _startListeningTimer();
      } else if (!state.sending && wasSending) {
        _cancelListeningTimer();
      }

      if (state.messages.length != _lastMessageCount) {
        _lastMessageCount = state.messages.length;
        _scrollToBottom();
      }
    });

    // Riverpod 3 retries a throwing build() with backoff; during that
    // retry the state is technically AsyncLoading but still carries the
    // last error forward (AsyncValue.hasError / .error, per
    // isReloading/copyWithPrevious). Checking hasError FIRST — rather than
    // isLoading — means the user sees the error+retry screen immediately
    // instead of a spinner that silently retries for several seconds before
    // ever admitting anything is wrong. This is screen-only: chatProvider
    // itself is untouched.
    //
    // `!chatAsync.hasValue` is load-bearing: the SAME retrying AsyncLoading
    // state also retains a PREVIOUS value when one exists (e.g. a live
    // transcript already on screen whose background refetch just failed).
    // Only fall back to the full-screen error when there is truly nothing
    // to show instead — never let a failed refetch blank out a transcript
    // the user is already looking at.
    if (chatAsync.hasError && !chatAsync.hasValue) {
      return _ChatErrorScreen(
        onRetry: () => ref.invalidate(chatProvider(widget.sessionId)),
      );
    }

    if (!chatAsync.hasValue) {
      return Scaffold(
        appBar: AppBar(), // present on every state so the bar never pops in/out as loading resolves
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final state = chatAsync.value!;
    final currentVersion = state.queueVersion;

    // The LATEST message whose queueVersion matches the current one gets
    // the live card; every OTHER queue-bearing message gets a compact chip.
    int? liveQueueMessageIndex;
    for (var i = state.messages.length - 1; i >= 0; i--) {
      if (state.messages[i].message.queueVersion == currentVersion) {
        liveQueueMessageIndex = i;
        break;
      }
    }
    final needsStandaloneCard =
        liveQueueMessageIndex == null && state.queue.isNotEmpty;

    final items = <Widget>[];
    for (var i = 0; i < state.messages.length; i++) {
      final message = state.messages[i];
      // A dead retry (no preceding user turn to resend — shouldn't happen
      // in practice, but a synthesized/edge-case transcript could lack
      // one) hides the button entirely rather than wiring it to a no-op.
      final precedingText = message.isError
          ? _precedingUserText(state.messages, i)
          : '';
      final canRetry = message.isError && precedingText.isNotEmpty;
      items.add(
        _MessageBubble(
          message: message,
          onRetry: canRetry ? () => _send(precedingText) : null,
          retryEnabled: !state.sending,
        ),
      );
      final version = message.message.queueVersion;
      if (version != null) {
        if (i == liveQueueMessageIndex) {
          // The server tags version-changed messages even when a turn
          // EMPTIES the queue — an empty live card would just be a header
          // with nothing under it, so skip rendering it entirely rather
          // than showing that.
          if (state.queue.isNotEmpty) {
            items.add(QueueCard(sessionId: widget.sessionId, queue: state.queue));
          }
        } else {
          items.add(_QueueUpdatedChip(version: version));
        }
      }
    }
    if (needsStandaloneCard) {
      items.add(QueueCard(sessionId: widget.sessionId, queue: state.queue));
    }
    if (state.sending) {
      items.add(_TypingIndicator(showCaption: _showListeningCaption));
    }

    return Scaffold(
      appBar: AppBar(title: Text(state.session.title)),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: items.length,
                itemBuilder: (context, index) => items[index],
              ),
            ),
            _Composer(
              controller: _textController,
              enabled: !state.sending,
              onSend: (text) => _send(text, fromComposer: true),
            ),
          ],
        ),
      ),
    );
  }

  /// The text of the nearest USER message before [index] — that's the turn
  /// an error bubble at [index] is a response to, and what "resend" means.
  String _precedingUserText(List<ChatMessage> messages, int index) {
    for (var i = index - 1; i >= 0; i--) {
      if (messages[i].message.role == 'user') return messages[i].message.content;
    }
    return '';
  }
}

class _ChatErrorScreen extends StatelessWidget {
  const _ChatErrorScreen({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(), // present on every state — see the hasError branch's comment
      body: Center(
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
              const Text(
                "couldn't load this conversation",
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                key: const Key('chat-retry'),
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

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    this.onRetry,
    this.retryEnabled = true,
  });

  final ChatMessage message;
  /// Null hides the retry affordance entirely (a non-error bubble, or an
  /// error bubble with no preceding user turn to resend — see the
  /// dead-retry guard at the call site).
  final VoidCallback? onRetry;
  /// Whether an already-visible retry button is actionable right now
  /// (false while another send is in flight) — the button still renders,
  /// just dimmed and inert, rather than disappearing.
  final bool retryEnabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isUser = message.message.role == 'user';
    final Color background;
    final Color foreground;
    // The DJ's own voice (and its error apologies) gets a thin tinted
    // accent bar — never the user's own bubble, which stays plain.
    Color? accent;
    if (message.isError) {
      background = theme.colorScheme.errorContainer;
      foreground = theme.colorScheme.onErrorContainer;
      accent = theme.colorScheme.error;
    } else if (isUser) {
      background = theme.colorScheme.primaryContainer;
      foreground = theme.colorScheme.onPrimaryContainer;
    } else {
      background = theme.colorScheme.surfaceContainerHighest;
      // onSurface, not the muted onSurfaceVariant — the DJ's voice should
      // read as a first-class speaker, not de-emphasized Material grey.
      foreground = theme.colorScheme.onSurface;
      accent = theme.colorScheme.primary;
    }

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        key: message.isError ? const Key('error-bubble') : null,
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(16),
        ),
        // IntrinsicHeight: `stretch` needs a bounded cross-axis (height) to
        // fill, which this Row otherwise doesn't have (its Container has no
        // explicit height, so height is normally content-driven) — without
        // it, `stretch` forces an infinite-height layout crash.
        child: IntrinsicHeight(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (accent != null) ...[
                Container(
                  key: const Key('dj-accent-bar'),
                  width: 3.5,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  message.message.content,
                  style: TextStyle(color: foreground),
                ),
              ),
              if (onRetry != null) ...[
                const SizedBox(width: 4),
                IconButton(
                  key: const Key('retry-message'),
                  tooltip: 'Resend',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.refresh,
                    size: 18,
                    color: retryEnabled
                        ? foreground
                        : foreground.withValues(alpha: 0.4),
                  ),
                  onPressed: retryEnabled ? onRetry : null,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _QueueUpdatedChip extends StatelessWidget {
  const _QueueUpdatedChip({required this.version});

  final int version;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Chip(
          key: const Key('queue-updated-chip'),
          avatar: const Icon(Icons.queue_music, size: 16),
          label: Text('queue updated · v$version'),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}

class _TypingIndicator extends StatefulWidget {
  const _TypingIndicator({required this.showCaption});

  final bool showCaption;

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      key: const Key('typing-indicator'),
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _controller,
              builder: (context, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(3, (i) {
                  final t = (_controller.value + i / 3) % 1.0;
                  final opacity =
                      0.3 + 0.7 * (1 - (t - 0.5).abs() * 2).clamp(0.0, 1.0);
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Opacity(
                      opacity: opacity,
                      child: Icon(
                        Icons.circle,
                        size: 8,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  );
                }),
              ),
            ),
            if (widget.showCaption) ...[
              const SizedBox(height: 4),
              Text(
                'the DJ is listening…',
                key: const Key('listening-caption'),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.enabled,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool enabled;
  final ValueChanged<String> onSend;

  static const _maxLength = 2000;
  // Silent-cap guard: the field enforces 2000 unconditionally, but the
  // counter itself only shows up once it's actually relevant, rather than
  // nagging from character zero.
  static const _counterVisibleAt = 1800;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            final hasText = value.text.trim().isNotEmpty;
            final canSend = enabled && hasText;
            final showCounter = value.text.length > _counterVisibleAt;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('composer-field'),
                    controller: controller,
                    enabled: enabled,
                    maxLength: _maxLength,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: canSend ? onSend : null,
                    decoration: InputDecoration(
                      hintText: 'Tell the DJ what you want to hear…',
                      counterText: showCounter ? null : '',
                      border: const OutlineInputBorder(
                        borderRadius: BorderRadius.all(Radius.circular(24)),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  key: const Key('send-button'),
                  tooltip: 'Send',
                  onPressed: canSend ? () => onSend(controller.text) : null,
                  icon: const Icon(Icons.send),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
