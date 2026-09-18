/// The four-tab shell
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md` → Dock, Conversation
/// and arrangement, Accessibility; plan task 2.2).
///
/// Four tab [Navigator]s in an [IndexedStack], so every tab keeps its own
/// history and its own scroll position. The dock is either the real
/// `UITabBar` hosted in the iOS window — in which case Flutter draws no dock
/// at all and only speaks to it over `mixtape/shell` — or the
/// [FrostedDock] fallback with the same geometry.
///
/// The shell follows the host pattern the founder shipped in goalympics
/// (`app_shell.dart`): scroll-driven minimise, show on returning to a tab
/// root, hide on dispose.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/shell/mini_player_state.dart';
import '../../../data/shell/shell_channel.dart';
import '../../providers/playback_provider.dart';
import '../../providers/shell_providers.dart';
import '../../widgets/foundation/frosted_dock.dart';
import '../../widgets/foundation/frosted_surface.dart';
import '../../widgets/foundation/gradient_background.dart';
import '../home_screen.dart';
import '../mixes_screen.dart';
import '../playback_screen.dart';
import '../tabs/library_tab.dart';
import '../tabs/you_tab.dart';

class ShellScreen extends ConsumerStatefulWidget {
  const ShellScreen({super.key});

  /// Identifies a tab's own subtree inside the [IndexedStack].
  static Key tabKey(AppTab tab) => ValueKey('shell-tab-${tab.name}');

  /// The stack that keeps all four tabs alive — the shell's own, not one a
  /// screen inside a tab happens to build.
  static const Key tabStackKey = Key('shell-tabs');

  /// Room the Mixes tab leaves under its list on top of the dock's own
  /// height, which the shell contributes through [MediaQuery.padding].
  static const EdgeInsets tabListInset = EdgeInsets.only(bottom: 16);

  @override
  ConsumerState<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends ConsumerState<ShellScreen> {
  final ShellChannel _dock = ShellChannel.instance;

  /// One navigator per tab, so a pushed conversation stays inside its tab.
  late final List<GlobalKey<NavigatorState>> _navigators = [
    for (final tab in AppTab.values)
      GlobalKey<NavigatorState>(debugLabel: 'shell-${tab.name}'),
  ];

  late final List<_TabRouteObserver> _observers = [
    for (var index = 0; index < AppTab.values.length; index++)
      _TabRouteObserver(onChanged: _syncDockVisibility),
  ];

  /// Whether the tab that is up has a route above its root — a conversation,
  /// an arrangement, a modal sheet or a dialog. The dock owns none of the
  /// screen then (board: "tab bar hidden inside a mix"). Per tab, not global:
  /// a conversation left open in Mixes must not hide the dock on Home.
  bool _routeAbove = false;

  /// Scroll has pushed the tab bar down to the active tab's size.
  bool _minimized = false;

  Brightness? _appearance;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    _dock.init();
    _subscriptions.addAll([
      _dock.onTabChanged.listen(_onDockTab),
      _dock.onMiniPlayerTapped.listen((_) => _openNowPlaying()),
      _dock.onMiniPlayerPlayPause.listen((_) => _playPause()),
      _dock.onMiniPlayerNext.listen((_) => _next()),
    ]);
    // A fresh shell: the dock is up, on the first tab. Deferred until the
    // platform has answered whether a native dock exists at all — see
    // [_announce].
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _announceIfResolved();
    });
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    // Sign-out replaces the whole signed-in tree; the native dock lives in the
    // window and would otherwise float over the sign-in screen. Nothing to
    // put away if the shell never got as far as showing it.
    if (_announced) _dock.hide();
    super.dispose();
  }

  int get _currentIndex => ref.read(selectedTabProvider);

  /// Whether the platform has answered [nativeDockAvailableProvider].
  ///
  /// Until it has, neither dock is drawn and nothing is sent down the
  /// channel: on iOS 26 a Flutter dock drawn for that one frame would flash
  /// beside the real one.
  bool _announced = false;

  void _announceIfResolved() {
    if (_announced || !mounted) return;
    if (!ref.read(nativeDockAvailableProvider).hasValue) return;
    _announced = true;
    _dock.setTab(_currentIndex);
    if (_routeAbove) {
      _dock.hide();
    } else {
      _dock.show();
    }
    _dock.setMiniPlayer(ref.read(miniPlayerStateProvider));
    _dock.setAppearance(isDark: _appearance == Brightness.dark);
  }

  /// Nothing reaches the dock before [_announceIfResolved] has: the state it
  /// would have missed is sent there in one go instead.
  void _tell(void Function(ShellChannel dock) send) {
    if (_announced) send(_dock);
  }

  NavigatorState? _navigatorOf(int index) => _navigators[index].currentState;

  /// A tap on either dock. Re-tapping the tab that is already up pops it back
  /// to its root, as iOS does.
  void _onTabTapped(int index) {
    if (index == _currentIndex) {
      _navigatorOf(index)?.popUntil((route) => route.isFirst);
      return;
    }
    ref.read(selectedTabProvider.notifier).select(index);
  }

  /// The native dock drove the change; same rule.
  void _onDockTab(int index) => _onTabTapped(index);

  /// Now Playing is already up on some tab, and a second tap on the
  /// mini-player must not stack another copy on top of it. Cleared when the
  /// route is popped, whichever way it was dismissed.
  bool _nowPlayingOpen = false;

  void _openNowPlaying() {
    if (_nowPlayingOpen) return;
    final navigator = _navigatorOf(_currentIndex);
    if (navigator == null) return;
    _nowPlayingOpen = true;
    navigator
        .push(MaterialPageRoute<void>(builder: (_) => const PlaybackScreen()))
        .whenComplete(() => _nowPlayingOpen = false);
  }

  void _playPause() {
    final mini = ref.read(miniPlayerStateProvider);
    // A track Apple Music refused has no transport but Next — the board's
    // rule, and the native dock does not enforce it for us.
    if (!mini.visible || mini.unavailable) return;
    ref.read(playbackProvider).command(mini.playing ? 'pause' : 'resume');
  }

  void _next() => ref.read(playbackProvider).command('next');

  /// A route came or went inside a tab, or the tab that is up changed. The
  /// dock is route-level and per tab: hidden while something sits above the
  /// selected tab's root, back at full size when nothing does — so switching
  /// into a tab with a conversation open hides it, and switching back to a
  /// tab at its root shows it again.
  void _syncDockVisibility() {
    final routeAbove = _observers[_currentIndex].depth > 0;
    if (routeAbove == _routeAbove) return;
    _routeAbove = routeAbove;
    if (routeAbove) {
      _tell((dock) => dock.hide());
    } else {
      _tell((dock) => dock.show());
      _setMinimized(false);
    }
    _rebuild();
  }

  /// goalympics' scroll-to-shrink, unchanged: shrink on the way down, restore
  /// on the way up or at the top, and never shrink a list that cannot scroll.
  bool _handleScroll(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) return false;
    if (notification is UserScrollNotification) {
      if (notification.metrics.maxScrollExtent <= 0) {
        _setMinimized(false);
      } else if (notification.direction == ScrollDirection.reverse) {
        _setMinimized(true);
      } else if (notification.direction == ScrollDirection.forward) {
        _setMinimized(false);
      }
    } else if (notification is ScrollUpdateNotification &&
        notification.metrics.pixels <= 0) {
      _setMinimized(false);
    }
    return false; // let the notification keep bubbling
  }

  void _setMinimized(bool minimized) {
    if (_minimized == minimized) return;
    _minimized = minimized;
    _tell((dock) => dock.setMinimized(minimized));
    _rebuild();
  }

  /// Route and scroll callbacks land mid-build and mid-layout; defer the
  /// rebuild rather than marking an ancestor dirty inside someone else's
  /// build.
  void _rebuild() {
    if (!mounted) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      setState(() {});
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  /// A tab's root screen, under the dock's own bottom padding.
  ///
  /// The padding sits here rather than around the whole stack so that a route
  /// pushed above a root — a conversation, Now Playing — gets none of it: the
  /// dock is hidden there, and a dead inset at the bottom of a full-screen
  /// route is just a gap.
  Widget _rootFor(AppTab tab) {
    final root = switch (tab) {
      AppTab.home => const HomeScreen(),
      AppTab.mixes => MixesScreen(
        onStartMix: () =>
            ref.read(selectedTabProvider.notifier).selectTab(AppTab.home),
        bottomInset: ShellScreen.tabListInset,
      ),
      AppTab.library => const LibraryTab(),
      AppTab.you => const YouTab(),
    };
    return Builder(
      builder: (context) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            padding: media.padding.copyWith(
              bottom: media.padding.bottom + kFrostedDockHeight,
            ),
          ),
          child: root,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentIndex = ref.watch(selectedTabProvider);
    // Until the platform has answered, no dock is drawn and nothing is sent:
    // on iOS 26 a Flutter dock drawn for that frame would flash beside the
    // real one.
    final availability = ref.watch(nativeDockAvailableProvider);
    final resolved = availability.hasValue;
    final nativeDock = availability.value ?? false;
    if (resolved && !_announced) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _announceIfResolved(),
      );
    }
    final reduceTransparency = ref.watch(reduceTransparencyProvider);
    final mini = ref.watch(miniPlayerStateProvider);

    ref.listen<int>(selectedTabProvider, (previous, next) {
      if (previous == next) return;
      _tell((dock) => dock.setTab(next));
      // Switching tabs always reveals the dock at full size — and the tab
      // arrived at may already have a conversation open, which hides it.
      _setMinimized(false);
      _syncDockVisibility();
    });
    ref.listen<MiniPlayerState>(miniPlayerStateProvider, (previous, next) {
      _tell((dock) => dock.setMiniPlayer(next));
    });

    // The dock's glass resolves against the system appearance, so the app's
    // resolved brightness has to be pushed down on every theme change.
    final brightness = Theme.of(context).brightness;
    if (brightness != _appearance) {
      _appearance = brightness;
      _tell(
        (dock) => dock.setAppearance(isDark: brightness == Brightness.dark),
      );
    }

    return GradientBackground(
      child: FrostedSurfaceMode(
        reduceTransparency: reduceTransparency,
        // The dock floats: it sits outside the Scaffold that resizes, so the
        // keyboard comes up over it instead of carrying it.
        child: Stack(
          fit: StackFit.expand,
          children: [
            Scaffold(
              backgroundColor: Colors.transparent,
              resizeToAvoidBottomInset: false,
              body: NotificationListener<ScrollNotification>(
                onNotification: _handleScroll,
                child: NavigatorPopHandler(
                  // Android back and the iOS swipe pop the tab's own
                  // history before they leave the shell.
                  onPopWithResult: (result) =>
                      _navigatorOf(currentIndex)?.maybePop(),
                  child: IndexedStack(
                    key: ShellScreen.tabStackKey,
                    index: currentIndex,
                    children: [
                      for (final tab in AppTab.values)
                        KeyedSubtree(
                          key: ShellScreen.tabKey(tab),
                          child: Navigator(
                            key: _navigators[tab.index],
                            observers: [_observers[tab.index]],
                            onGenerateRoute: (settings) =>
                                MaterialPageRoute<void>(
                                  settings: settings,
                                  builder: (_) => _rootFor(tab),
                                ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (resolved && !nativeDock && !_routeAbove)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: FrostedDock(
                  currentIndex: currentIndex,
                  onTap: _onTabTapped,
                  mini: mini,
                  minimized: _minimized,
                  onMiniTap: _openNowPlaying,
                  onMiniPlayPause: _playPause,
                  onMiniNext: _next,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Counts what sits above a tab's root route.
///
/// Sheets and dialogs opened from inside a tab go on that tab's navigator, so
/// they count too: the dock must not float over a sheet.
class _TabRouteObserver extends NavigatorObserver {
  _TabRouteObserver({required this.onChanged});

  final VoidCallback onChanged;

  int _depth = 0;
  int get depth => _depth;

  /// The tab's own root arrives with no route beneath it; everything else is
  /// something the listener pushed.
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute == null) return;
    _change(1);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _change(-1);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _change(-1);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    // A replacement keeps the depth: one route left, one arrived.
  }

  void _change(int delta) {
    final next = _depth + delta;
    _depth = next < 0 ? 0 : next;
    onChanged();
  }
}
