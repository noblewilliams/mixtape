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
import '../providers/capabilities_provider.dart';
import '../providers/dj_providers.dart';
import '../providers/home_mode_provider.dart';
import '../providers/listen_later_provider.dart';
import '../theme/mixtape_theme.dart';
import '../widgets/foundation/empty_state.dart';
import '../widgets/foundation/flush_row.dart';
import '../widgets/foundation/frosted_dock.dart' show kFrostedDockHeight;
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/cassette_tile.dart';
import '../widgets/foundation/label_chip.dart';
import '../widgets/foundation/mixtape_feedback.dart';
import '../widgets/foundation/large_title_scaffold.dart';
import '../widgets/foundation/section_word.dart';
import '../widgets/foundation/segmented_toggle.dart';
import '../widgets/foundation/tape_button.dart';
import 'queue_screen.dart' show QueueScreen;
import '../widgets/listen_later_row.dart';
import '../widgets/mix_home_row.dart';
import 'chat_screen.dart';

// TODO(2.2): remove Home's copies of these once its list is gone.
const _archiveFailedMessage = "couldn't archive — try again";
const _unarchiveFailedMessage = "couldn't unarchive — try again";
const _removeFailedMessage = 'Couldn’t remove it from Listen later. Try again.';
const _restoreFailedMessage =
    'Couldn’t put it back on Listen later. Try again.';
const _markListenedFailedMessage = 'Couldn’t mark it listened. Try again.';

/// The title-row control's segments. Listen later exists only for listeners
/// album picks are offered to (album picks board L1 to L3).
enum MixesSegment { active, archived, listenLater }

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

  /// The same, while the Listen later shelf loads.
  static const String listenLaterLoadingLabel =
      'Loading your Listen later shelf';

  /// The empty state's illustration size — the app's one size (note 7).
  static const double emptyCassetteWidth = EmptyState.cassetteWidth;

  @override
  ConsumerState<MixesScreen> createState() => _MixesScreenState();
}

class _MixesScreenState extends ConsumerState<MixesScreen> {
  MixesSegment _segment = MixesSegment.active;
  bool _refreshFailed = false;
  bool _shelfRefreshFailed = false;

  bool get _onShelf => _segment == MixesSegment.listenLater;

  Future<void> _refresh() async {
    if (_onShelf) {
      final ok = await ref.read(listenLaterProvider.notifier).refresh();
      if (mounted) setState(() => _shelfRefreshFailed = !ok);
      return;
    }
    final ok = await ref.read(sessionsProvider.notifier).refresh();
    if (mounted) setState(() => _refreshFailed = !ok);
  }

  /// Opens the album session an entry was saved from; the shelf and the
  /// session list both refresh on the way back.
  void _openShelfEntry(String sessionId) {
    Navigator.of(context)
        .push(
          MaterialPageRoute(builder: (_) => ChatScreen(sessionId: sessionId)),
        )
        .then((_) {
          if (!mounted) return;
          ref.read(sessionsProvider.notifier).refresh();
          ref.read(listenLaterProvider.notifier).refresh();
        });
  }

  void _showError(ScaffoldMessengerState messenger, String message) {
    if (!mounted || !messenger.mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      mixtapeSnackBar(message: message, kind: FeedbackKind.error),
    );
  }

  /// Swipe-to-remove: the provider drops the row at once and puts it back if
  /// the server says no; the arrangement screen's Undo toast follows.
  Future<void> _removeFromShelf(String albumId) async {
    final notifier = ref.read(listenLaterProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await notifier.remove(albumId);
    if (!mounted || !messenger.mounted) return;
    if (!ok) {
      _showError(messenger, _removeFailedMessage);
      return;
    }
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      mixtapeSnackBar(
        message: 'Removed from Listen later.',
        kind: FeedbackKind.success,
        duration: MediaQuery.accessibleNavigationOf(context)
            ? const Duration(days: 1)
            : QueueScreen.undoDuration,
        actionLabel: 'Undo',
        onAction: () async {
          messenger.hideCurrentSnackBar();
          final restored = await ref
              .read(listenLaterProvider.notifier)
              .restore(albumId);
          if (!restored) _showError(messenger, _restoreFailedMessage);
        },
      ),
    );
  }

  Future<void> _markListened(String albumId) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await ref
        .read(listenLaterProvider.notifier)
        .markListened(albumId);
    if (!ok) _showError(messenger, _markListenedFailedMessage);
  }

  /// "Find an album": ask Home to open on Album, then switch to it.
  void _findAnAlbum() {
    ref.read(homeModeRequestProvider.notifier).request(SessionKind.album);
    widget.onStartMix?.call();
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
        mixtapeSnackBar(
          message: archived ? _archiveFailedMessage : _unarchiveFailedMessage,
          kind: FeedbackKind.error,
        ),
      );
    } else if (archived) {
      messenger.showSnackBar(
        mixtapeSnackBar(
          message: 'Mix archived',
          kind: FeedbackKind.success,
          duration: MediaQuery.accessibleNavigationOf(context)
              ? const Duration(days: 1)
              : const Duration(seconds: 3),
          actionLabel: 'Undo',
          onAction: () async {
            messenger.hideCurrentSnackBar();
            final restored = await ref
                .read(sessionsProvider.notifier)
                .unarchive(id);
            if (!restored && mounted && messenger.mounted) {
              messenger.showSnackBar(
                mixtapeSnackBar(
                  message: _unarchiveFailedMessage,
                  kind: FeedbackKind.error,
                ),
              );
            }
          },
        ),
      );
    }
    return ok;
  }

  @override
  Widget build(BuildContext context) {
    final sessionsAsync = ref.watch(sessionsProvider);
    final albumsOn = ref.watch(albumPicksEnabledProvider);
    // The shelf's segment left (signed out of albums, the server turned them
    // off): fall back to Active rather than show a segment that isn't there.
    if (!albumsOn && _onShelf) _segment = MixesSegment.active;

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
            accessoriesBelowTitle:
                albumsOn &&
                !_MixesSegmentedControl.fitsBesideTitle(context, 'Mixes'),
            titleAccessory: _MixesSegmentedControl(
              segment: _segment,
              listenLater: albumsOn,
              onChanged: (value) => setState(() => _segment = value),
            ),
            onRefresh: _refresh,
            slivers: [
              if (_refreshFailed && !_onShelf)
                _RefreshFailedBanner(
                  title: 'Couldn’t refresh your mixes.',
                  body: 'Showing your last loaded mixes.',
                  onRetry: _refresh,
                ),
              if (_shelfRefreshFailed && _onShelf)
                _RefreshFailedBanner(
                  key: const Key('listen-later-refresh-failed'),
                  title: 'Couldn’t refresh your Listen later shelf.',
                  body: 'Showing your last loaded shelf.',
                  onRetry: _refresh,
                ),
              if (_onShelf)
                _shelf(ref.watch(listenLaterProvider), sessionsAsync.value)
              else
                _body(sessionsAsync),
            ],
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
    final archived = _segment == MixesSegment.archived;
    final visible = archived
        ? archivedSessions(sessions)
        : nonArchivedSessions(sessions);

    if (visible.isEmpty) {
      return _SessionsEmptyState(
        archived: archived,
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
            onCaseColor: (color) => ref
                .read(sessionsProvider.notifier)
                .setCaseColor(session.id, color),
            onArchive: () => _setArchived(session.id, archived: true),
            onRestore: () => _setArchived(session.id, archived: false),
          );
        },
      ),
    );
  }

  /// The Listen later shelf: unlistened rows, then a "Listened" heading and
  /// the listened rows, in the provider's order.
  Widget _shelf(
    AsyncValue<List<ListenLaterEntry>> shelfAsync,
    List<DjSession>? sessions,
  ) {
    if (shelfAsync.hasError && !shelfAsync.hasValue) {
      return SliverPadding(
        padding: widget.bottomInset,
        sliver: _SessionsErrorState(
          title: 'Couldn’t load your Listen later shelf',
          retryKey: const Key('listen-later-retry'),
          onRetry: () => ref.invalidate(listenLaterProvider),
        ),
      );
    }
    if (!shelfAsync.hasValue) {
      return SliverPadding(
        padding: widget.bottomInset,
        sliver: const _SessionsSkeleton(
          label: MixesScreen.listenLaterLoadingLabel,
        ),
      );
    }
    final entries = shelfAsync.requireValue;
    if (entries.isEmpty) {
      return EmptyStateSliver(
        key: const Key('listen-later-empty'),
        child: EmptyState(
          title: 'Nothing saved for later',
          body: 'Ask for an album, then tap Listen later to keep it here.',
          action: LabelChip(label: 'Find an album', onPressed: _findAnAlbum),
        ),
      );
    }

    final titles = {
      for (final s in sessions ?? const <DjSession>[]) s.id: s.title,
    };
    final firstListened = entries.indexWhere((e) => e.listened);
    final children = <Widget>[];
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index];
      if (index == firstListened) {
        children.add(const SectionWord('Listened'));
      }
      final sessionId = entry.sessionId;
      children.add(
        ListenLaterRow(
          key: Key('listen-later-${entry.id}'),
          entry: entry,
          // The heading takes the hairline's place above its first row.
          isFirst: index == 0 || index == firstListened,
          savedFrom: sessionId == null ? null : titles[sessionId],
          onOpen: sessionId == null ? null : () => _openShelfEntry(sessionId),
          onMarkListened: () => _markListened(entry.id),
          onRemove: () => _removeFromShelf(entry.id),
        ),
      );
    }
    return SliverPadding(
      padding: widget.bottomInset,
      sliver: SliverList.list(
        key: const Key('listen-later-list'),
        children: children,
      ),
    );
  }
}

/// The board's `.segc`: Active / Archived, and Listen later when album
/// picks are offered, in the house toggle
/// (`widgets/foundation/segmented_toggle.dart`), which "Add your music" wears
/// too — one segmented control, app-wide (smoke round five, note 3).
///
/// No `SemanticsRole.tabBar` wrapper: Flutter's debug role check requires a
/// tab bar's direct children to be tab nodes, and the toggle's own per-segment
/// semantics sit in between, so the segments stay plain selected buttons.
class _MixesSegmentedControl extends StatelessWidget {
  const _MixesSegmentedControl({
    required this.segment,
    required this.listenLater,
    required this.onChanged,
  });

  final MixesSegment segment;
  final bool listenLater;
  final ValueChanged<MixesSegment> onChanged;

  /// The control is chrome beside the title, so its labels stop growing here —
  /// as `UISegmentedControl` does — rather than pushing the control wider than
  /// a 320 pt phone. The rows themselves still scale all the way up.
  static const double maxLabelScale = 1.3;

  /// The title row hands its accessories unbounded width, so the ceiling is
  /// the control's own. Two segments stop at 240. Three sit beside the title
  /// only where they fit whole ([fitsBesideTitle]) and otherwise take their
  /// own row below it, so their ceiling is the screen's content width; a
  /// label that would pass it ellipsises.
  static const double maxWidth = 240;

  static const List<String> _threeLabels = [
    'Active',
    'Archived',
    'Listen later',
  ];

  /// Whether the three segments leave [title] its full width beside them.
  /// The house toggle draws equal segments, so three of them are three times
  /// the widest label; where that would squeeze the large title, the control
  /// drops to its own row below it, leading-aligned, as the board's
  /// `.large-title` wraps.
  static bool fitsBesideTitle(BuildContext context, String title) {
    final scaler = MediaQuery.textScalerOf(context);
    final labelScaler = scaler.clamp(maxScaleFactor: maxLabelScale);
    double measure(String text, TextStyle style, TextScaler s) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        textScaler: s,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    const labelStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w600);
    final widest = _threeLabels
        .map((label) => measure(label, labelStyle, labelScaler))
        .reduce((a, b) => a > b ? a : b);
    final control =
        _threeLabels.length * (widest + 2 * SegmentedToggle.segmentPadding) +
        2 * SegmentedToggle.chrome;
    final titleWidth = measure(title, context.tokens.largeTitle, scaler);
    final available =
        MediaQuery.sizeOf(context).width - 2 * MixtapeMetrics.screenSidePadding;
    return titleWidth + LargeTitleScaffold.titleGap + control <= available;
  }

  @override
  Widget build(BuildContext context) => MediaQuery.withClampedTextScaling(
    maxScaleFactor: maxLabelScale,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: listenLater
            ? MediaQuery.sizeOf(context).width -
                  2 * MixtapeMetrics.screenSidePadding
            : maxWidth,
      ),
      child: SegmentedToggle<MixesSegment>(
        value: segment,
        onChanged: onChanged,
        options: [
          const SegmentedOption(
            value: MixesSegment.active,
            label: 'Active',
            key: Key('active-mixes'),
          ),
          const SegmentedOption(
            value: MixesSegment.archived,
            label: 'Archived',
            key: Key('archived-mixes'),
          ),
          if (listenLater)
            const SegmentedOption(
              value: MixesSegment.listenLater,
              label: 'Listen later',
              key: Key('listen-later-mixes'),
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
  const _SessionsSkeleton({this.label = MixesScreen.loadingLabel});

  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return SliverToBoxAdapter(
      child: Semantics(
        container: true,
        liveRegion: true,
        label: label,
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
                      Opacity(
                        opacity: .16,
                        child: CassetteTile(
                          width: MixHomeRow.artSize,
                          caseColor: tokens.muted,
                        ),
                      ),
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
  const _SessionsErrorState({
    required this.onRetry,
    this.title = 'Couldn’t load your mixes',
    this.retryKey = const Key('sessions-retry'),
  });

  final VoidCallback onRetry;
  final String title;
  final Key retryKey;

  @override
  Widget build(BuildContext context) {
    return EmptyStateSliver(
      child: EmptyState(
        title: title,
        body: 'Try again in a moment.',
        artwork: EmptyStateArtwork.connection,
        action: KeyedSubtree(
          key: retryKey,
          child: OutlinedButton(
            onPressed: onRetry,
            child: const Text('Try again'),
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

/// A failed pull-to-refresh over a list that is still shown: say so above it,
/// with a Retry, rather than replace the list.
class _RefreshFailedBanner extends StatelessWidget {
  const _RefreshFailedBanner({
    super.key,
    required this.title,
    required this.body,
    required this.onRetry,
  });

  final String title;
  final String body;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: context.tokens.rowTitle.copyWith(fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(body, style: context.tokens.meta.copyWith(fontSize: 11)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: onRetry,
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(48, 44),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              side: BorderSide(color: context.tokens.hairline),
            ),
            child: const Text('Retry', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    ),
  );
}
