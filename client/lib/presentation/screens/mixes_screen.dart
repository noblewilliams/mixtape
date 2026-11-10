/// The Mixes tab: every conversation with the DJ
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md` → Mixes; frames M1/M2
/// in `docs/mockups/2026-09-17-mobile-shell-r3.html`).
///
/// Moved off Home by plan task 2.3. Since 2026-11-09 it follows WhatsApp's
/// chat list (founder): the toggle is Active | Listen later, archived mixes sit
/// behind an "Archived" row at the top of Active, and a swipe left opens a
/// row's More and Archive actions and waits for a tap.
///
/// It lives inside a tab `Navigator`, so it never assumes it is the root route:
/// pushes go to the nearest [Navigator] and there is no app bar of its own.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
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
import '../widgets/foundation/glass_segmented_control.dart';
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/cassette_tile.dart';
import '../widgets/foundation/label_chip.dart';
import '../widgets/foundation/mixtape_feedback.dart';
import '../widgets/foundation/mixtape_menu.dart' show MixMenuIcons;
import '../widgets/foundation/large_title_scaffold.dart';
import '../widgets/foundation/section_word.dart';
import '../widgets/foundation/segmented_toggle.dart';
import '../widgets/foundation/swipe_actions.dart';
import '../widgets/foundation/tape_button.dart';
import 'queue_screen.dart' show QueueScreen;
import '../widgets/listen_later_row.dart';
import '../widgets/mix_home_row.dart';
import 'archived_mixes_screen.dart';
import 'chat_screen.dart';
import 'mix_archive_feedback.dart';

const _removeFailedMessage = 'Couldn’t remove it from Listen later. Try again.';
const _restoreFailedMessage =
    'Couldn’t put it back on Listen later. Try again.';
const _markListenedFailedMessage = 'Couldn’t mark it listened. Try again.';

/// The title-row control's segments. Listen later exists only for listeners
/// album picks are offered to (album picks board L1 to L3); without it there
/// is nothing to toggle, so the control is not drawn at all. Archived is a
/// row at the top of Active, not a segment.
enum MixesSegment { active, listenLater }

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

  /// The "Archived" row at the top of Active.
  static const Key archivedRowKey = Key('archived-mixes-row');

  /// How far past the top a pull has to go to bring the Archived row out.
  /// Short of the refresh control's 100 pt, so a small pull reveals it and a
  /// long one also refreshes.
  static const double archivedRevealPull = 44;

  @override
  ConsumerState<MixesScreen> createState() => _MixesScreenState();
}

class _MixesScreenState extends ConsumerState<MixesScreen> {
  MixesSegment _segment = MixesSegment.active;
  bool _refreshFailed = false;
  bool _shelfRefreshFailed = false;

  /// The Archived row hides above the list until a pull down brings it out,
  /// as WhatsApp's did, and hides again once it has scrolled out of sight.
  final ScrollController _scroll = ScrollController();
  final GlobalKey _archivedRow = GlobalKey();
  bool _archivedRevealed = false;

  /// Bumped when the row hides off screen, so it goes at once rather than
  /// animating shut out of sight while the list is moved to cover it.
  int _archivedEpoch = 0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical ||
        _onShelf) {
      return false;
    }
    if (notification is ScrollUpdateNotification &&
        !_archivedRevealed &&
        notification.dragDetails != null &&
        notification.metrics.pixels <= -MixesScreen.archivedRevealPull) {
      setState(() => _archivedRevealed = true);
      HapticFeedback.selectionClick();
    } else if (notification is ScrollEndNotification && _archivedRevealed) {
      _hideArchivedIfOutOfSight();
    }
    return false;
  }

  /// Once the user has scrolled the revealed row out above the screen, it
  /// goes back into hiding; the list moves up by its height in the same
  /// frame, so nothing on screen shifts.
  void _hideArchivedIfOutOfSight() {
    final box = _archivedRow.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return;
    if (box.localToGlobal(Offset(0, box.size.height)).dy > 0) return;
    final height = box.size.height;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_archivedRevealed) return;
      setState(() {
        _archivedRevealed = false;
        _archivedEpoch++;
      });
      if (_scroll.hasClients) {
        _scroll.jumpTo(math.max(0, _scroll.offset - height));
      }
    });
  }

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

  Future<bool> _setArchived(String id, {required bool archived}) =>
      setMixArchived(context, ref, id, archived: archived);

  /// WhatsApp's Archived: its own screen, pushed inside this tab.
  void _openArchived() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const ArchivedMixesScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final sessionsAsync = ref.watch(sessionsProvider);
    final albumsOn = ref.watch(albumPicksEnabledProvider);
    // The shelf's segment left (signed out of albums, the server turned them
    // off): fall back to Active rather than show a segment that isn't there.
    if (!albumsOn && _onShelf) _segment = MixesSegment.active;

    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: GradientBackground(
        // A transparent Scaffold, no app bar: the large title is the chrome.
        // Inside the shell, toasts render in the shell's own Scaffold, which
        // lifts them clear of the dock (`ShellScreen.toastClearance`); this
        // theme only places them when Mixes stands alone, as in its tests.
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
            body: SwipeActionsGroup(
              child: LargeTitleScaffold(
                controller: _scroll,
                title: 'Mixes',
                accessoriesBelowTitle:
                    albumsOn &&
                    !_MixesSegmentedControl.fitsBesideTitle(context, 'Mixes'),
                titleAccessory: albumsOn
                    ? _MixesSegmentedControl(
                        segment: _segment,
                        onChanged: (value) => setState(() => _segment = value),
                      )
                    : null,
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
                    ..._body(sessionsAsync),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Mirrors Home's `hasError && !hasValue` rule: the full-screen error state
  /// only when there is truly nothing to show. A failed refresh over a
  /// previously-good list keeps the list and says so in a SnackBar.
  List<Widget> _body(AsyncValue<List<DjSession>> sessionsAsync) {
    if (sessionsAsync.hasError && !sessionsAsync.hasValue) {
      // The list's states keep the dock inset as list padding; the empty
      // state below takes its own from the shared placement rule instead.
      // invalidate, not refresh(): reaching this branch means build() itself
      // failed, which leaves Riverpod's retry backoff scheduled on this
      // element. invalidate() replaces the element, cancelling that timer.
      return [
        SliverPadding(
          padding: widget.bottomInset,
          sliver: _SessionsErrorState(
            onRetry: () => ref.invalidate(sessionsProvider),
          ),
        ),
      ];
    }
    if (!sessionsAsync.hasValue) {
      return [
        SliverPadding(
          padding: widget.bottomInset,
          sliver: const _SessionsSkeleton(),
        ),
      ];
    }

    final sessions = sessionsAsync.requireValue;
    final active = nonArchivedSessions(sessions);
    final archivedCount = archivedSessions(sessions).length;
    // WhatsApp's rules: the row exists only while something is archived, and
    // waits above the list for a pull down. It stays out when there is no
    // list to hide behind (the empty state points at it) and for VoiceOver,
    // which cannot pull for it.
    final showArchived =
        archivedCount > 0 &&
        (_archivedRevealed ||
            active.isEmpty ||
            MediaQuery.accessibleNavigationOf(context));
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final archivedSliver = SliverToBoxAdapter(
      child: KeyedSubtree(
        key: ValueKey(_archivedEpoch),
        child: AnimatedSize(
          duration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: showArchived
              ? _ArchivedRow(
                  key: _archivedRow,
                  count: archivedCount,
                  onOpen: _openArchived,
                )
              : const SizedBox(width: double.infinity),
        ),
      ),
    );

    if (active.isEmpty) {
      return [
        archivedSliver,
        _SessionsEmptyState(
          hasArchived: archivedCount > 0,
          onStartMix: widget.onStartMix,
        ),
      ];
    }

    return [
      archivedSliver,
      SliverPadding(
        padding: widget.bottomInset,
        sliver: SliverList.builder(
          key: const Key('sessions-list'),
          itemCount: active.length,
          // By key, not position: a row keeps its state (open, mid-archive,
          // mid-rename) when a row above it is archived or put back.
          findChildIndexCallback: (key) {
            final index = active.indexWhere(
              (s) => Key('session-${s.id}') == key,
            );
            return index < 0 ? null : index;
          },
          itemBuilder: (context, index) {
            final session = active[index];
            return MixHomeRow(
              key: Key('session-${session.id}'),
              session: session,
              // Lazily built rows have no FlushList above them, so the first
              // row has to be told it opens the list or it draws a hairline
              // there. Under the Archived row it draws one.
              isFirst: index == 0 && !showArchived,
              // No visible actions button: long-press and the swipe.
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
      ),
    ];
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

/// Active | Listen later, beside the title: a native iOS 26 segmented control
/// on Liquid Glass ([GlassSegmentedControl]), the house toggle elsewhere.
///
/// No `SemanticsRole.tabBar` wrapper: Flutter's debug role check requires a
/// tab bar's direct children to be tab nodes, and the toggle's own per-segment
/// semantics sit in between, so the segments stay plain selected buttons.
class _MixesSegmentedControl extends StatelessWidget {
  const _MixesSegmentedControl({
    required this.segment,
    required this.onChanged,
  });

  final MixesSegment segment;
  final ValueChanged<MixesSegment> onChanged;

  /// The control is chrome beside the title, so its labels stop growing here —
  /// as `UISegmentedControl` does — rather than pushing the control wider than
  /// a phone. The rows themselves still scale all the way up.
  static const double maxLabelScale = GlassSegmentedControl.maxTextScale;

  static const List<String> _labels = ['Active', 'Listen later'];

  /// Whether the segments leave [title] its full width beside them; where
  /// they would squeeze the large title, the control drops to its own row
  /// below it, leading-aligned, as the board's `.large-title` wraps.
  static bool fitsBesideTitle(BuildContext context, String title) {
    final scaler = MediaQuery.textScalerOf(context);
    final labelScaler = scaler.clamp(maxScaleFactor: maxLabelScale);
    // Measured in the styles the Scaffold's text actually resolves to: a bare
    // style misses the theme's iOS font family, which measured the control
    // narrower than it draws and let "Mixes" wrap beside it (founder,
    // 2026-11-03).
    final inherited = Theme.of(context).textTheme.bodyMedium!;
    final labelStyle = inherited.merge(
      const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    );
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

    final widest = _labels
        .map((label) => measure(label, labelStyle, labelScaler))
        .reduce((a, b) => a > b ? a : b)
        .ceilToDouble();
    // The wider of the two drawings: the native control's segments, or the
    // house toggle's with its inset.
    final native =
        _labels.length * (widest + 2 * GlassSegmentedControl.segmentPadding);
    final drawn =
        _labels.length * (widest + 2 * SegmentedToggle.segmentPadding) +
        2 * SegmentedToggle.chrome;
    final control = native > drawn ? native : drawn;
    final titleWidth = measure(
      title,
      inherited.merge(context.tokens.largeTitle),
      scaler,
    ).ceilToDouble();
    final available =
        MediaQuery.sizeOf(context).width - 2 * MixtapeMetrics.screenSidePadding;
    return titleWidth + LargeTitleScaffold.titleGap + control <= available;
  }

  @override
  Widget build(BuildContext context) => MediaQuery.withClampedTextScaling(
    maxScaleFactor: maxLabelScale,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth:
            MediaQuery.sizeOf(context).width -
            2 * MixtapeMetrics.screenSidePadding,
      ),
      child: GlassSegmentedControl<MixesSegment>(
        value: segment,
        onChanged: onChanged,
        options: const [
          SegmentedOption(
            value: MixesSegment.active,
            label: 'Active',
            key: Key('active-mixes'),
          ),
          SegmentedOption(
            value: MixesSegment.listenLater,
            label: 'Listen later',
            key: Key('listen-later-mixes'),
          ),
        ],
      ),
    ),
  );
}

/// WhatsApp's "Archived" row, at the top of Active: one slim line — a small
/// archive glyph in the tape column, the word level with the mix titles, and
/// how many mixes wait behind it. Much shorter and quieter than a mix row
/// (founder, 2026-11-09), and out of sight until a pull down.
class _ArchivedRow extends StatelessWidget {
  const _ArchivedRow({super.key, required this.count, required this.onOpen});

  final int count;
  final VoidCallback onOpen;

  /// The row's resting height: slim, but a full-width line to touch.
  static const double minHeight = 40;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Semantics(
      button: true,
      label: count == 1 ? 'Archived, 1 mix' : 'Archived, $count mixes',
      excludeSemantics: true,
      onTap: onOpen,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: MixesScreen.archivedRowKey,
          onTap: onOpen,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: minHeight),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: MixHomeRow.artSize,
                    child: Icon(
                      MixMenuIcons.archive,
                      size: 16,
                      color: tokens.muted,
                    ),
                  ),
                  const SizedBox(width: FlushRow.gap),
                  Expanded(
                    child: Text(
                      'Archived',
                      style: tokens.meta.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: tokens.smoke,
                      ),
                    ),
                  ),
                  Text(
                    '$count',
                    style: tokens.meta.copyWith(
                      fontSize: 13,
                      color: tokens.muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
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
                  padding: const EdgeInsets.symmetric(
                    vertical: MixHomeRow.verticalPadding,
                  ),
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

/// The shared load-error state, placed like the empty one.
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
      child: LoadErrorState(title: title, retryKey: retryKey, onRetry: onRetry),
    );
  }
}

/// The board's first-run state: the cassette carries it, and one tape button
/// switches to Home. With mixes in the archive and none active, it says where
/// they went instead.
class _SessionsEmptyState extends StatelessWidget {
  const _SessionsEmptyState({required this.hasArchived, this.onStartMix});

  final bool hasArchived;
  final VoidCallback? onStartMix;

  @override
  Widget build(BuildContext context) => EmptyStateSliver(
    key: const Key('sessions-empty'),
    child: EmptyState(
      title: hasArchived ? 'Nothing active' : 'No tapes yet',
      body: hasArchived
          ? 'Your archived mixes are under Archived. Start a new one from Home.'
          : 'Your first mix will appear here. Start one from Home.',
      action: onStartMix != null
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
