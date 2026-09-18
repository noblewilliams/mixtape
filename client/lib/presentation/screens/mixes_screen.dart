/// The Mixes tab: every conversation with the DJ, active or archived
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md` → Mixes; frames M1/M2
/// in `docs/mockups/2026-09-17-mobile-shell-r3.html`).
///
/// Moved off Home by plan task 2.3: the segmented control, the flush rows with
/// their 60 pt cassette tiles, swipe-to-archive with Undo and the row actions
/// menu are the September 8 interactions in the September 17 shell.
///
/// It lives inside a tab `Navigator`, so it never assumes it is the root route:
/// pushes go to the nearest [Navigator] and there is no app bar of its own.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dj/dj_models.dart';
import '../providers/dj_providers.dart';
import '../theme/mixtape_theme.dart';
import '../widgets/foundation/empty_state.dart';
import '../widgets/foundation/flush_row.dart';
import '../widgets/foundation/frosted_dock.dart' show kFrostedDockHeight;
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/square_art.dart';
import '../widgets/foundation/large_title_scaffold.dart';
import '../widgets/foundation/segmented_toggle.dart';
import '../widgets/foundation/tape_button.dart';
import '../widgets/mix_home_row.dart';
import 'chat_screen.dart';

// TODO(2.2): remove Home's copies of these once its list is gone.
const _archiveFailedMessage = "couldn't archive — try again";
const _unarchiveFailedMessage = "couldn't unarchive — try again";
const _refreshFailedMessage = "couldn't refresh — showing what we had";

/// The Mixes tab.
class MixesScreen extends ConsumerStatefulWidget {
  const MixesScreen({
    super.key,
    this.onStartMix,
    this.bottomInset = const EdgeInsets.only(bottom: defaultBottomInset),
  });

  /// Switches to Home from the first-run empty state; task 2.2 wires the tab
  /// change. Absent, the empty state simply drops the button.
  final VoidCallback? onStartMix;

  /// Room under the list for the floating dock, so the last row clears it.
  final EdgeInsets bottomInset;

  /// The dock's own height plus a row of breathing room, so the last row
  /// clears the floating dock instead of hiding behind it.
  static const double defaultBottomInset = kFrostedDockHeight + 16;

  /// One loading placeholder row, by position.
  static Key skeletonRowKey(int index) => ValueKey('mixes.skeleton-$index');

  /// How many of them stand in for the list while it loads.
  static const int skeletonRows = 3;

  /// What a screen reader is told while they are up.
  static const String loadingLabel = 'Loading your mixes';

  /// The empty state's illustration size — the app's one size (note 7).
  static const double emptyCassetteWidth = EmptyState.cassetteWidth;

  @override
  ConsumerState<MixesScreen> createState() => _MixesScreenState();
}

class _MixesScreenState extends ConsumerState<MixesScreen> {
  bool _showArchived = false;

  Future<void> _refresh() async {
    final ok = await ref.read(sessionsProvider.notifier).refresh();
    if (!ok && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text(_refreshFailedMessage)));
    }
  }

  /// Home's `_navigateToChat`, unchanged: sessions can move while ChatScreen
  /// owns the screen, so the list refreshes on the way back rather than
  /// waiting for an unrelated rebuild.
  void _openConversation(String sessionId) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(builder: (_) => ChatScreen(sessionId: sessionId)),
        )
        .then((_) {
          if (!mounted) return;
          ref.read(sessionsProvider.notifier).refresh();
        });
  }

  Future<bool> _setArchived(String id, {required bool archived}) async {
    final notifier = ref.read(sessionsProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final ok = archived
        ? await notifier.archive(id)
        : await notifier.unarchive(id);
    if (!mounted || !messenger.mounted) return ok;
    messenger.hideCurrentSnackBar();
    if (!ok) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            archived ? _archiveFailedMessage : _unarchiveFailedMessage,
          ),
        ),
      );
    } else if (archived) {
      messenger.showSnackBar(
        SnackBar(
          content: const Text('Mix archived'),
          duration: const Duration(seconds: 3),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () async {
              final restored = await ref
                  .read(sessionsProvider.notifier)
                  .unarchive(id);
              if (!restored && mounted && messenger.mounted) {
                messenger.showSnackBar(
                  const SnackBar(content: Text(_unarchiveFailedMessage)),
                );
              }
            },
          ),
        ),
      );
    }
    return ok;
  }

  @override
  Widget build(BuildContext context) {
    final sessionsAsync = ref.watch(sessionsProvider);

    return GradientBackground(
      // A transparent Scaffold, no app bar: the large title is the chrome, and
      // the Scaffold is only here to host this tab's own SnackBars. They float
      // clear of the dock, so Undo and the failure lines stay reachable.
      child: Theme(
        data: Theme.of(context).copyWith(
          snackBarTheme: Theme.of(context).snackBarTheme.copyWith(
            behavior: SnackBarBehavior.floating,
            insetPadding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              widget.bottomInset.bottom,
            ),
          ),
        ),
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: LargeTitleScaffold(
            title: 'Mixes',
            titleAccessory: _ArchiveSegmentedControl(
              showArchived: _showArchived,
              onChanged: (value) => setState(() => _showArchived = value),
            ),
            onRefresh: _refresh,
            slivers: [_body(sessionsAsync)],
          ),
        ),
      ),
    );
  }

  /// Mirrors Home's `hasError && !hasValue` rule: the full-screen error state
  /// only when there is truly nothing to show. A failed refresh over a
  /// previously-good list keeps the list and says so in a SnackBar.
  Widget _body(AsyncValue<List<DjSession>> sessionsAsync) {
    if (sessionsAsync.hasError && !sessionsAsync.hasValue) {
      // The list's states keep the dock inset as list padding; the empty
      // state below takes its own from the shared placement rule instead.
      // invalidate, not refresh(): reaching this branch means build() itself
      // failed, which leaves Riverpod's retry backoff scheduled on this
      // element. invalidate() replaces the element, cancelling that timer.
      return SliverPadding(
        padding: widget.bottomInset,
        sliver: _SessionsErrorState(
          onRetry: () => ref.invalidate(sessionsProvider),
        ),
      );
    }
    if (!sessionsAsync.hasValue) {
      return SliverPadding(
        padding: widget.bottomInset,
        sliver: const _SessionsSkeleton(),
      );
    }

    final sessions = sessionsAsync.requireValue;
    final visible = _showArchived
        ? archivedSessions(sessions)
        : nonArchivedSessions(sessions);

    if (visible.isEmpty) {
      return _SessionsEmptyState(
        archived: _showArchived,
        onStartMix: widget.onStartMix,
      );
    }

    return SliverPadding(
      padding: widget.bottomInset,
      sliver: SliverList.builder(
        key: const Key('sessions-list'),
        itemCount: visible.length,
        itemBuilder: (context, index) {
          final session = visible[index];
          return MixHomeRow(
            key: Key('session-${session.id}'),
            session: session,
            // Lazily built rows have no FlushList above them, so the first
            // row has to be told it opens the list or it draws a hairline
            // there.
            isFirst: index == 0,
            // The board's row: chevron only, actions on long-press.
            showActionsButton: false,
            onOpen: () => _openConversation(session.id),
            onRename: (title) =>
                ref.read(sessionsProvider.notifier).rename(session.id, title),
            onArchive: () => _setArchived(session.id, archived: true),
            onRestore: () => _setArchived(session.id, archived: false),
          );
        },
      ),
    );
  }
}

/// The board's `.segc`: Active / Archived in the house toggle
/// (`widgets/foundation/segmented_toggle.dart`), which "Add your music" wears
/// too — one segmented control, app-wide (smoke round five, note 3).
///
/// No `SemanticsRole.tabBar` wrapper: Flutter's debug role check requires a
/// tab bar's direct children to be tab nodes, and the toggle's own per-segment
/// semantics sit in between, so the segments stay plain selected buttons.
class _ArchiveSegmentedControl extends StatelessWidget {
  const _ArchiveSegmentedControl({
    required this.showArchived,
    required this.onChanged,
  });

  final bool showArchived;
  final ValueChanged<bool> onChanged;

  /// The control is chrome beside the title, so its labels stop growing here —
  /// as `UISegmentedControl` does — rather than pushing the control wider than
  /// a 320 pt phone. The rows themselves still scale all the way up.
  static const double maxLabelScale = 1.3;

  /// The title row hands its accessories unbounded width, so the ceiling is
  /// the control's own: both segments and the track's chrome stay inside a
  /// 320 pt screen's content width, and a label that would pass it ellipsises.
  static const double maxWidth = 240;

  @override
  Widget build(BuildContext context) => MediaQuery.withClampedTextScaling(
    maxScaleFactor: maxLabelScale,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: maxWidth),
      child: SegmentedToggle<bool>(
        value: showArchived,
        onChanged: onChanged,
        options: const [
          SegmentedOption(
            value: false,
            label: 'Active',
            key: Key('active-mixes'),
          ),
          SegmentedOption(
            value: true,
            label: 'Archived',
            key: Key('archived-mixes'),
          ),
        ],
      ),
    ),
  );
}

/// Three placeholder rows under the live chrome: the 60 pt art box and two
/// grey bars, so the list area has the shape of what is coming.
///
/// The bars say nothing to a screen reader; one live region announces the wait
/// instead.
class _SessionsSkeleton extends StatelessWidget {
  const _SessionsSkeleton();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return SliverToBoxAdapter(
      child: Semantics(
        container: true,
        liveRegion: true,
        label: MixesScreen.loadingLabel,
        child: ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var index = 0; index < MixesScreen.skeletonRows; index++)
                Padding(
                  key: MixesScreen.skeletonRowKey(index),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      SquareArt(size: MixHomeRow.artSize),
                      const SizedBox(width: FlushRow.gap),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _Bar(
                              width: 180,
                              color: tokens.hairline,
                              height: 14,
                            ),
                            const SizedBox(height: 8),
                            _Bar(
                              width: 110,
                              color: tokens.hairline,
                              height: 11,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.width, required this.color, required this.height});

  final double width;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(3),
    ),
  );
}

/// Home's cloud-off state, restyled on a [TapeButton].
class _SessionsErrorState extends StatelessWidget {
  const _SessionsErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 48, color: tokens.errInk),
              const SizedBox(height: 16),
              Text(
                "couldn't load your sessions",
                textAlign: TextAlign.center,
                style: tokens.body,
              ),
              const SizedBox(height: 16),
              KeyedSubtree(
                key: const Key('sessions-retry'),
                child: TapeButton(label: 'Try again', onPressed: onRetry),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The board's first-run state: the cassette carries it, and one tape button
/// switches to Home. Archived says its own thing and offers nothing.
class _SessionsEmptyState extends StatelessWidget {
  const _SessionsEmptyState({required this.archived, this.onStartMix});

  final bool archived;
  final VoidCallback? onStartMix;

  @override
  Widget build(BuildContext context) => EmptyStateSliver(
    key: const Key('sessions-empty'),
    child: EmptyState(
      title: archived ? 'Nothing archived' : 'No tapes yet',
      body: archived
          ? 'Swipe a mix left to archive it.'
          : 'Your first mix will appear here. Start one from Home.',
      action: !archived && onStartMix != null
          ? TapeButton(label: 'Start a mix', onPressed: onStartMix)
          : null,
    ),
  );
}
