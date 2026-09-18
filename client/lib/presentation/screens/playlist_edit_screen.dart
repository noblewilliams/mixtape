/// The private DJ draft of one playlist, restyled onto the native design
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md` → conversation frame;
/// plan `docs/superpowers/plans/2026-09-17-native-design-implementation.md`
/// task 8.2).
///
/// Behaviour is the September 6 editing approval's: the source is never
/// written, the draft's canonical version and exact change summary ride the
/// conversation, Review shows the real operation before anything is applied,
/// and partial or unknown Apple outcomes reconcile before any retry.
///
/// Pushed inside a tab `Navigator`: glass back and action clusters, no app bar.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/playlists/playlist_edit_models.dart';
import '../providers/playlist_providers.dart';
import '../theme/mixtape_theme.dart';
import '../widgets/conversation_turn.dart';
import '../widgets/energy_journey.dart' show EnergyControlVisibility;
import '../widgets/foundation/glass_cluster.dart';
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/liquid_glass_surface.dart';
import '../widgets/foundation/square_art.dart';
import '../widgets/foundation/tape_button.dart';
import '../widgets/foundation/text_action.dart';
import '../widgets/home_panel.dart' show HomePanel;
import '../widgets/mix_prompt_input.dart';
import '../widgets/playlist_artwork.dart';
import '../widgets/foundation/mixtape_sheet.dart';

class PlaylistEditScreen extends ConsumerStatefulWidget {
  const PlaylistEditScreen({super.key, required this.draftId});

  final String draftId;

  static const Key backKey = Key('playlist-edit-back');
  static const Key moreKey = Key('playlist-edit-more');

  /// The Review glyph in the title cluster — keyed as it was when Review was a
  /// button in the truth bar.
  static const Key reviewKey = Key('review-draft');

  /// The panel's Review action.
  static const Key reviewActionKey = Key('review-draft-action');

  static const Key composerKey = Key('playlist-edit-composer');
  static const Key applyKey = Key('apply-draft');
  static const Key keepEditingKey = Key('keep-editing');
  static const Key retryKey = Key('retry-request');

  /// The DJ's opening line when a fresh draft has no turns yet.
  static const String opener =
      'Tell me what you want to add, remove, replace, or move.';

  /// The review row's artwork.
  static const double reviewArtSize = 38;

  /// Said when the draft could not be read again; nothing was changed.
  static const String refreshFailed = "Couldn't refresh this private draft.";

  @override
  ConsumerState<PlaylistEditScreen> createState() => _PlaylistEditScreenState();
}

class _PlaylistEditScreenState extends ConsumerState<PlaylistEditScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();

  /// A `UiKitView` composites above a route barrier, so the panel's native
  /// glass stands down while the review sheet is open.
  bool _reviewOpen = false;

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    await ref
        .read(playlistEditThreadProvider(widget.draftId).notifier)
        .send(text);
  }

  Future<void> _openMore(BuildContext anchor) async {
    final box = anchor.findRenderObject();
    final overlay = Navigator.of(context).overlay?.context.findRenderObject();
    if (box is! RenderBox || overlay is! RenderBox) return;
    final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
      items: const [
        PopupMenuItem(value: 'refresh', child: Text('Refresh draft')),
      ],
    );
    if (!mounted || action != 'refresh') return;
    try {
      await ref
          .read(playlistEditThreadProvider(widget.draftId).notifier)
          .refresh();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(PlaylistEditScreen.refreshFailed)),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final thread = ref.watch(playlistEditThreadProvider(widget.draftId));
    ref.listen(playlistEditThreadProvider(widget.draftId), (previous, next) {
      final state = next.value;
      if (state?.transientError != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(state!.transientError!)));
        ref
            .read(playlistEditThreadProvider(widget.draftId).notifier)
            .clearTransientError();
      }
      if ((next.value?.messages.length ?? 0) !=
          (previous?.value?.messages.length ?? 0)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_scrollController.hasClients) return;
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
          );
        });
      }
    });

    final state = thread.value;
    return _frame(
      title: state?.view.draft.baseName ?? 'Playlist edit',
      state: state,
      body: thread.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => _Failure(
          onRetry: () =>
              ref.invalidate(playlistEditThreadProvider(widget.draftId)),
        ),
        data: _transcript,
      ),
    );
  }

  /// Chrome shared by every state: the gradient, the glass clusters, the
  /// floating SnackBars (no dock on this route) and the bottom panel.
  Widget _frame({
    required String title,
    required Widget body,
    required PlaylistEditThreadState? state,
  }) {
    final theme = Theme.of(context);
    final changes = state?.view.diff.changeCount ?? 0;
    return GradientBackground(
      child: Theme(
        data: theme.copyWith(
          snackBarTheme: theme.snackBarTheme.copyWith(
            behavior: SnackBarBehavior.floating,
            insetPadding: const EdgeInsets.all(16),
          ),
        ),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _TopBar(
                  title: title,
                  onBack: () => Navigator.of(context).maybePop(),
                  onReview: state != null && changes > 0
                      ? () => _openReview(state.view)
                      : null,
                  onMore: state == null ? null : _openMore,
                ),
                Expanded(child: body),
                if (state != null) _panel(state),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The turns, flush on the gradient.
  Widget _transcript(PlaylistEditThreadState state) {
    final changes = state.view.diff.changeCount;
    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(
        MixtapeMetrics.screenSidePadding,
        8,
        MixtapeMetrics.screenSidePadding,
        12,
      ),
      children: [
        if (state.messages.isEmpty)
          const ConversationTurn(
            text: PlaylistEditScreen.opener,
            kind: ConversationTurnKind.dj,
          ),
        for (final message in state.messages)
          if (message.isError)
            _FailedTurn(
              text: message.message.content,
              onRetry: message.retryContent == null || state.sending
                  ? null
                  : () => ref
                        .read(
                          playlistEditThreadProvider(widget.draftId).notifier,
                        )
                        .send(message.retryContent!),
            )
          else
            ConversationTurn(
              text: message.message.content,
              kind: message.message.role == 'user'
                  ? ConversationTurnKind.user
                  : ConversationTurnKind.dj,
            ),
        if (changes > 0) _ChangeSummary(view: state.view),
        if (state.sending) const WorkingIndicator(showCaption: false),
      ],
    );
  }

  /// The bottom panel: the composer and Review, on the shell's glass.
  Widget _panel(PlaylistEditThreadState state) {
    final tokens = context.tokens;
    final media = MediaQuery.of(context);
    final changes = state.view.diff.changeCount;
    final composerEnabled =
        !state.sending && state.applyStatus == PlaylistApplyUiStatus.idle;

    return LiquidGlassSurface(
      allowNative: !_reviewOpen,
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(HomePanel.topRadius),
      ),
      fallbackBlurSigma: 30,
      fallbackTint: tokens.panel,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          HomePanel.sidePadding,
          10,
          HomePanel.sidePadding,
          media.padding.bottom + 8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (changes > 0)
              Padding(
                padding: const EdgeInsets.only(left: 2, bottom: 8),
                child: Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '$changes ${changes == 1 ? 'change' : 'changes'}',
                      style: tokens.meta,
                    ),
                    Text(
                      'Source untouched',
                      style: tokens.meta.copyWith(color: tokens.muted),
                    ),
                  ],
                ),
              ),
            // The composer draws its own Shape chip for Home; a playlist draft
            // has no energy journey to shape.
            //
            // `busy` is the composer's own lock: it makes the field read-only
            // and guards `_submit`, so neither the send key nor Return can
            // start a turn while a turn is in flight OR while an apply result
            // stands unreconciled.
            EnergyControlVisibility(
              visible: false,
              child: MixPromptInput(
                key: PlaylistEditScreen.composerKey,
                controller: _controller,
                busy: !composerEnabled,
                onSubmit: _send,
              ),
            ),
            const SizedBox(height: 10),
            TapeButton(
              key: PlaylistEditScreen.reviewActionKey,
              label: 'Review',
              onPressed: changes > 0 ? () => _openReview(state.view) : null,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openReview(PlaylistEditView view) async {
    setState(() => _reviewOpen = true);
    try {
      await showMixtapeSheet<void>(
        context,
        isScrollControlled: true,
        builder: (context) => _ReviewSheet(draftId: widget.draftId, view: view),
      );
    } finally {
      if (mounted) setState(() => _reviewOpen = false);
    }
  }
}

/// Back on the left, the draft's base name centred, Review and More on the
/// right — all in the board's glass clusters, with no app bar.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.onBack,
    required this.onReview,
    required this.onMore,
  });

  final String title;
  final VoidCallback onBack;
  final VoidCallback? onReview;
  final Future<void> Function(BuildContext anchor)? onMore;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Row(
        children: [
          GlassCluster(
            children: [
              GlassButton(
                key: PlaylistEditScreen.backKey,
                icon: Icons.arrow_back_ios_new,
                label: 'Back',
                onPressed: onBack,
              ),
            ],
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tokens.smallTitle,
              ),
            ),
          ),
          GlassCluster(
            children: [
              GlassButton(
                key: PlaylistEditScreen.reviewKey,
                icon: Icons.checklist_rounded,
                label: 'Review',
                onPressed: onReview,
              ),
              Builder(
                builder: (anchor) => GlassButton(
                  key: PlaylistEditScreen.moreKey,
                  icon: Icons.more_horiz,
                  label: 'More',
                  onPressed: onMore == null ? null : () => onMore!(anchor),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A DJ turn that failed, with the exact request offered again beneath it.
class _FailedTurn extends StatelessWidget {
  const _FailedTurn({required this.text, required this.onRetry});

  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      ConversationTurn(text: text, kind: ConversationTurnKind.error),
      TextAction(
        key: PlaylistEditScreen.retryKey,
        label: 'Try that request again',
        onPressed: onRetry,
      ),
    ],
  );
}

/// The canonical draft version and the compact exact change summary, flush on
/// the gradient under the turn that produced them.
class _ChangeSummary extends StatelessWidget {
  const _ChangeSummary({required this.view});

  final PlaylistEditView view;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(top: 10, left: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Draft updated · v${view.draft.version}',
            style: tokens.meta.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 3),
          Text(
            _summary(view.diff),
            style: tokens.meta.copyWith(color: tokens.muted),
          ),
        ],
      ),
    );
  }
}

String _summary(PlaylistEditDiff diff) {
  final parts = <String>[];
  if (diff.added.isNotEmpty) parts.add('${diff.added.length} added');
  if (diff.removed.isNotEmpty) parts.add('${diff.removed.length} removed');
  if (diff.moved.isNotEmpty) parts.add('${diff.moved.length} moved');
  if (diff.replaced.isNotEmpty) parts.add('${diff.replaced.length} replaced');
  return parts.join(' · ');
}

class _ReviewSheet extends ConsumerWidget {
  const _ReviewSheet({required this.draftId, required this.view});

  final String draftId;
  final PlaylistEditView view;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = context.tokens;
    final thread = ref.watch(playlistEditThreadProvider(draftId)).value;
    final currentView = thread?.view ?? view;
    final applyStatus = thread?.applyStatus ?? PlaylistApplyUiStatus.idle;
    final supported = ref.watch(playlistApplySupportedProvider);
    final spotify = currentView.draft.sourceType == 'spotify_export';
    final unresolved = currentView.entries
        .where((entry) => !entry.resolved)
        .length;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        18,
        6,
        18,
        18 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Review private draft',
            style: tokens.meta.copyWith(color: tokens.muted),
          ),
          const SizedBox(height: 4),
          Text('Create a revised copy', style: tokens.smallTitle),
          const SizedBox(height: 12),
          Text(
            spotify
                ? 'This Spotify export stays untouched. A later apply step can create an Apple Music copy after every song is matched.'
                : 'Apple Music cannot safely place structural edits into the middle of this source. Mixtape will create a revised copy and leave “${currentView.draft.baseName}” untouched.',
            style: tokens.body,
          ),
          const SizedBox(height: 17),
          Text(_summary(currentView.diff), style: tokens.rowTitle),
          const SizedBox(height: 10),
          for (var i = 0; i < currentView.review.added.length; i++)
            _ReviewRow(
              key: ValueKey('review-row-added-$i'),
              icon: Icons.add_rounded,
              ink: tokens.okInk,
              entry: currentView.review.added[i],
              detail: _placement(
                currentView.entries,
                currentView.review.added[i].position,
              ),
            ),
          for (var i = 0; i < currentView.review.removed.length; i++)
            _ReviewRow(
              key: ValueKey('review-row-removed-$i'),
              icon: Icons.remove_rounded,
              ink: tokens.errInk,
              entry: currentView.review.removed[i],
              detail:
                  'Removed from position ${currentView.review.removed[i].position + 1}',
            ),
          for (var i = 0; i < currentView.review.moved.length; i++)
            _ReviewRow(
              key: ValueKey('review-row-moved-$i'),
              icon: Icons.swap_vert_rounded,
              ink: tokens.muted,
              entry: currentView.review.moved[i],
              detail:
                  'Moved from ${currentView.review.moved[i].fromPosition! + 1} to ${currentView.review.moved[i].position + 1}',
            ),
          for (var i = 0; i < currentView.review.replaced.length; i++)
            _ReviewRow(
              key: ValueKey('review-row-replaced-$i'),
              icon: Icons.sync_alt_rounded,
              ink: tokens.muted,
              entry: currentView.review.replaced[i].after,
              detail:
                  'Replaces “${currentView.review.replaced[i].before.title}” at position ${currentView.review.replaced[i].after.position + 1}',
            ),
          if (unresolved > 0) ...[
            const SizedBox(height: 12),
            Text(
              '$unresolved local or unmatched ${unresolved == 1 ? 'song blocks' : 'songs block'} apply. Mixtape will not leave anything out.',
              style: tokens.body.copyWith(color: tokens.errInk),
            ),
          ],
          if (applyStatus != PlaylistApplyUiStatus.idle) ...[
            const SizedBox(height: 12),
            _ApplyStatus(status: applyStatus),
          ],
          const SizedBox(height: 18),
          TapeButton(
            key: PlaylistEditScreen.applyKey,
            label: _applyLabel(applyStatus, supported),
            leading: applyStatus.busy
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
            onPressed:
                supported &&
                    currentView.capability.applyAvailable &&
                    !applyStatus.busy &&
                    applyStatus != PlaylistApplyUiStatus.applied
                ? () => ref
                      .read(playlistEditThreadProvider(draftId).notifier)
                      .applyRevisedCopy()
                : null,
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextAction(
              key: PlaylistEditScreen.keepEditingKey,
              label: 'Keep editing',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }

  String _applyLabel(PlaylistApplyUiStatus status, bool supported) {
    if (!supported) return 'Apple Music apply requires iPhone';
    return switch (status) {
      PlaylistApplyUiStatus.applied => 'Created in Apple Music',
      PlaylistApplyUiStatus.partial ||
      PlaylistApplyUiStatus.unknown => 'Reconcile result',
      PlaylistApplyUiStatus.sourceConflict => 'Source changed',
      PlaylistApplyUiStatus.blocked => 'Resolve unmatched songs first',
      PlaylistApplyUiStatus.failed => 'Try again',
      _ => 'Create revised playlist',
    };
  }

  String _placement(List<PlaylistEditEntry> entries, int position) {
    final before = position > 0 ? entries[position - 1].title : null;
    final after = position + 1 < entries.length
        ? entries[position + 1].title
        : null;
    if (before != null && after != null) {
      return 'After “$before” · before “$after”';
    }
    if (before != null) return 'After “$before” · at the end';
    if (after != null) return 'Before “$after” · at the beginning';
    return 'Only song in the draft';
  }
}

class _ApplyStatus extends StatelessWidget {
  const _ApplyStatus({required this.status});

  final PlaylistApplyUiStatus status;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final (title, detail, icon) = switch (status) {
      PlaylistApplyUiStatus.applied => (
        'Created in Apple Music',
        'The revised copy is saved and your source is untouched.',
        Icons.check_circle_outline_rounded,
      ),
      PlaylistApplyUiStatus.partial => (
        'Some songs were not added',
        'Mixtape will inspect the created copy before doing anything else.',
        Icons.warning_amber_rounded,
      ),
      PlaylistApplyUiStatus.unknown => (
        'Result needs checking',
        'Mixtape will inspect the same operation. It will not create another copy.',
        Icons.help_outline_rounded,
      ),
      PlaylistApplyUiStatus.sourceConflict => (
        'The source changed',
        'Sync the playlist, then review a fresh draft before applying.',
        Icons.sync_problem_rounded,
      ),
      PlaylistApplyUiStatus.blocked => (
        'This draft cannot be applied yet',
        'Every song must have an exact Apple Music match.',
        Icons.block_rounded,
      ),
      PlaylistApplyUiStatus.failed => (
        'Could not prepare the copy',
        'Nothing was confirmed. You can try this operation again.',
        Icons.error_outline_rounded,
      ),
      _ => ('Working…', 'Keep Mixtape open for a moment.', Icons.sync_rounded),
    };
    final ink = switch (status) {
      PlaylistApplyUiStatus.applied => tokens.okInk,
      PlaylistApplyUiStatus.partial ||
      PlaylistApplyUiStatus.unknown ||
      PlaylistApplyUiStatus.sourceConflict => tokens.warnInk,
      PlaylistApplyUiStatus.blocked ||
      PlaylistApplyUiStatus.failed => tokens.errInk,
      _ => tokens.muted,
    };
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 19, color: ink),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: tokens.rowTitle.copyWith(fontSize: 14, color: ink),
                ),
                const SizedBox(height: 2),
                Text(detail, style: tokens.meta.copyWith(color: tokens.muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One line of the source/draft comparison: the operation's mark in its own
/// ink, the song, and where it lands.
class _ReviewRow extends StatelessWidget {
  const _ReviewRow({
    super.key,
    required this.icon,
    required this.ink,
    required this.entry,
    required this.detail,
  });

  final IconData icon;
  final Color ink;
  final PlaylistEditReviewEntry entry;
  final String detail;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 19, color: ink),
          const SizedBox(width: 10),
          SquareArt(
            url: playlistArtworkUrl(
              entry.artworkUrlTemplate,
              size: (PlaylistEditScreen.reviewArtSize * 3).round(),
            ),
            placeholder: playlistArtworkColor(entry.artworkBgColor),
            size: PlaylistEditScreen.reviewArtSize,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.title, style: tokens.rowTitle),
                Text(
                  entry.artist,
                  style: tokens.meta.copyWith(color: tokens.muted),
                ),
                const SizedBox(height: 3),
                Text(detail, style: tokens.meta.copyWith(color: tokens.muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Failure extends StatelessWidget {
  const _Failure({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text("Couldn't load this private draft.", style: tokens.body),
          const SizedBox(height: 14),
          TapeButton(label: 'Try again', onPressed: onRetry),
        ],
      ),
    );
  }
}
