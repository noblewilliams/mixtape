/// The wide-iPhone dock: the same four tabs and mini-player as the bottom
/// dock, stood on end down the trailing edge.
///
/// Drawn on an iPhone whose window is at least [kSideRailBreakpoint] wide —
/// an unfolded foldable, or any iPhone in landscape — where a bottom bar would
/// waste the short axis. An iPad keeps the standard bottom dock. Below the breakpoint the shell keeps the bottom dock
/// (native `UITabBar` on iOS 26, [FrostedDock] elsewhere).
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../data/shell/mini_player_state.dart';
import '../../theme/mixtape_theme.dart';
import 'frosted_surface.dart';
import 'square_art.dart';

/// Window width, in logical points, from which the shell docks to the side.
/// Every iPhone in portrait sits under it (≤ 440 pt); every iPhone in
/// landscape and an unfolded foldable sit over it. (iPads never use it.)
const double kSideRailBreakpoint = 600;

/// Whether the shell should dock to the side for this window.
bool useSideRail(Size size) => size.width >= kSideRailBreakpoint;

/// The rail's own width; the content column starts after it.
const double kSideRailWidth = 72;

/// The room the rail claims beside the safe area: its width plus margins.
const double kSideRailExtent = kSideRailWidth + _railMargin * 2;

const double _railMargin = 12;

class SideRailTab {
  const SideRailTab(this.title, this.icon, this.selectedIcon);

  final String title;
  final IconData icon;
  final IconData selectedIcon;
}

/// Same tabs, glyphs and order as the bottom dock.
const List<SideRailTab> kSideRailTabs = [
  SideRailTab('Home', CupertinoIcons.house, CupertinoIcons.house_fill),
  SideRailTab(
    'Mixes',
    CupertinoIcons.music_note_list,
    CupertinoIcons.music_note_list,
  ),
  SideRailTab('Library', CupertinoIcons.book, CupertinoIcons.book_fill),
  SideRailTab('You', CupertinoIcons.person, CupertinoIcons.person_fill),
];

class SideRail extends StatelessWidget {
  const SideRail({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.mini = const MiniPlayerState.hidden(),
    this.onMiniTap,
    this.onMiniPlayPause,
    this.onMiniNext,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;
  final MiniPlayerState mini;
  final VoidCallback? onMiniTap;
  final VoidCallback? onMiniPlayPause;
  final VoidCallback? onMiniNext;

  static const Key tabsKey = Key('side-rail-tabs');
  static const Key miniPlayerKey = Key('side-rail-mini-player');
  static const Key playPauseKey = Key('side-rail-play-pause');
  static const Key nextKey = Key('side-rail-next');

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return DefaultTextStyle(
      style: Theme.of(context).textTheme.bodyMedium!,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          _railMargin,
          media.padding.top + _railMargin,
          media.padding.right + _railMargin,
          media.padding.bottom + _railMargin,
        ),
        child: SizedBox(
          width: kSideRailWidth,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // A landscape phone leaves ~370 pt of height: tabs and the
              // mini-player must both fit without scrolling the rail.
              final compact = constraints.maxHeight < 460;
              return Column(
                children: [
                  const Spacer(),
                  _Tabs(
                    key: tabsKey,
                    currentIndex: currentIndex,
                    onTap: onTap,
                    compact: compact,
                  ),
                  const Spacer(),
                  if (mini.visible)
                    _RailMiniPlayer(
                      key: miniPlayerKey,
                      mini: mini,
                      compact: compact,
                      onTap: onMiniTap,
                      onPlayPause: onMiniPlayPause,
                      onNext: onMiniNext,
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.compact,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return FrostedSurface(
      borderRadius: BorderRadius.circular(36),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var index = 0; index < kSideRailTabs.length; index++)
              _RailItem(
                tab: kSideRailTabs[index],
                selected: index == currentIndex,
                tokens: tokens,
                compact: compact,
                onTap: () => onTap(index),
              ),
          ],
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.tab,
    required this.selected,
    required this.tokens,
    required this.compact,
    required this.onTap,
  });

  final SideRailTab tab;
  final bool selected;
  final MixtapeTokens tokens;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = selected ? tokens.text : tokens.muted;
    return Semantics(
      label: tab.title,
      button: true,
      selected: selected,
      container: true,
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: selected
                ? (dark
                      ? const Color.fromRGBO(255, 255, 255, 0.14)
                      : const Color.fromRGBO(255, 255, 255, 0.60))
                : null,
            borderRadius: BorderRadius.circular(32),
          ),
          child: SizedBox(
            width: double.infinity,
            height: compact ? 52 : 64,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  selected ? tab.selectedIcon : tab.icon,
                  size: MixtapeMetrics.tabIcon,
                  color: ink,
                ),
                const SizedBox(height: 3),
                Text(
                  tab.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textScaler: TextScaler.noScaling,
                  style: tokens.label.copyWith(color: ink),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The mini-player stood on end: artwork (tap to open Now Playing), then
/// play/pause and next.
class _RailMiniPlayer extends StatelessWidget {
  const _RailMiniPlayer({
    super.key,
    required this.mini,
    required this.compact,
    required this.onTap,
    required this.onPlayPause,
    required this.onNext,
  });

  final MiniPlayerState mini;
  final bool compact;
  final VoidCallback? onTap;
  final VoidCallback? onPlayPause;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final buttons = [
      _RailButton(
        buttonKey: SideRail.playPauseKey,
        semanticsLabel: mini.playing ? 'Pause' : 'Play',
        icon: mini.playing
            ? CupertinoIcons.pause_fill
            : CupertinoIcons.play_fill,
        enabled: !mini.unavailable,
        color: mini.unavailable ? tokens.muted : tokens.text,
        onTap: onPlayPause,
      ),
      _RailButton(
        buttonKey: SideRail.nextKey,
        semanticsLabel: 'Next',
        icon: CupertinoIcons.forward_fill,
        color: tokens.text,
        onTap: onNext,
      ),
    ];
    return FrostedSurface(
      borderRadius: BorderRadius.circular(36),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              label: 'Now playing: ${mini.title}, ${mini.artist}',
              button: true,
              onTap: onTap,
              excludeSemantics: true,
              child: GestureDetector(
                onTap: onTap,
                child: SquareArt(
                  url: mini.artworkUrl,
                  size: 48,
                  radius: 8,
                  placeholder: tokens.tapeFill,
                ),
              ),
            ),
            const SizedBox(height: 4),
            if (compact)
              Row(children: [for (final b in buttons) Expanded(child: b)])
            else
              ...buttons,
          ],
        ),
      ),
    );
  }
}

class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.buttonKey,
    required this.semanticsLabel,
    required this.icon,
    required this.color,
    required this.onTap,
    this.enabled = true,
  });

  final Key buttonKey;
  final String semanticsLabel;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Semantics(
    label: semanticsLabel,
    button: true,
    enabled: enabled,
    container: true,
    onTap: enabled ? onTap : null,
    excludeSemantics: true,
    child: GestureDetector(
      key: buttonKey,
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : () {},
      child: SizedBox(
        height: MixtapeMetrics.minTarget,
        child: Center(child: Icon(icon, size: 19, color: color)),
      ),
    ),
  );
}
