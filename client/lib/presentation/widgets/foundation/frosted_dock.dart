/// The Flutter dock — the fallback for iOS 16–25 and Android
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md` → Dock, Platform
/// differences).
///
/// Same geometry, blur and radius as the native `ShellDock`; a hairline edge
/// and no refraction. On iOS 26 this widget is not drawn at all: the real
/// `UITabBar` and its `UIGlassEffect` mini-player sit in the window instead.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../data/shell/mini_player_state.dart';
import '../../theme/mixtape_theme.dart';
import 'frosted_surface.dart';
import 'square_art.dart';

/// How much room a screen leaves below its content so the dock never covers
/// it. The mini-player's band is always reserved — the board's rule is that
/// the layout must not shift when something starts playing — so this is
/// mini + gap + tab bar + the 8 pt breathing room, on top of the safe area.
const double kFrostedDockHeight =
    MixtapeMetrics.miniPlayerHeight +
    MixtapeMetrics.dockGap +
    MixtapeMetrics.tabBarHeight +
    _dockBottomInset;

const double _dockBottomInset = 8;

/// The four approved tabs, in shell order.
const List<_DockTab> _tabs = [
  _DockTab('Home', CupertinoIcons.house, CupertinoIcons.house_fill),
  _DockTab(
    'Mixes',
    CupertinoIcons.music_note_list,
    CupertinoIcons.music_note_list,
  ),
  _DockTab('Library', CupertinoIcons.book, CupertinoIcons.book_fill),
  _DockTab('You', CupertinoIcons.person, CupertinoIcons.person_fill),
];

class _DockTab {
  const _DockTab(this.title, this.icon, this.selectedIcon);

  final String title;
  final IconData icon;
  final IconData selectedIcon;
}

class FrostedDock extends StatelessWidget {
  const FrostedDock({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.mini = const MiniPlayerState.hidden(),
    this.onMiniTap,
    this.onMiniPlayPause,
    this.onMiniNext,
    this.minimized = false,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;

  /// What is playing. Hidden leaves the band empty but reserved.
  final MiniPlayerState mini;

  /// Tapping the mini-player anywhere but its two buttons.
  final VoidCallback? onMiniTap;
  final VoidCallback? onMiniPlayPause;
  final VoidCallback? onMiniNext;

  /// Scroll has pushed the tab bar down to the active tab's size.
  final bool minimized;

  static const Key miniPlayerKey = Key('frosted-dock-mini-player');
  static const Key tabBarKey = Key('frosted-dock-tab-bar');
  static const Key tabScaleKey = Key('frosted-dock-tab-scale');
  static const Key playPauseKey = Key('frosted-dock-play-pause');
  static const Key nextKey = Key('frosted-dock-next');

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final still = media.disableAnimations;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        MixtapeMetrics.dockSideMargin,
        0,
        MixtapeMetrics.dockSideMargin,
        media.padding.bottom + _dockBottomInset,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: MixtapeMetrics.miniPlayerHeight,
            // Offstage, not absent: the band stays reserved so the tab bar
            // never moves when a mix starts.
            child: Offstage(
              offstage: !mini.visible,
              child: AnimatedOpacity(
                opacity: mini.visible ? 1 : 0,
                duration: still ? Duration.zero : _fade,
                curve: Curves.easeOut,
                child: _MiniPlayer(
                  key: miniPlayerKey,
                  mini: mini,
                  onTap: onMiniTap,
                  onPlayPause: onMiniPlayPause,
                  onNext: onMiniNext,
                ),
              ),
            ),
          ),
          const SizedBox(height: MixtapeMetrics.dockGap),
          AnimatedScale(
            key: tabScaleKey,
            scale: minimized ? _minimizedScale : 1,
            alignment: Alignment.bottomCenter,
            duration: still ? Duration.zero : _minimize,
            curve: Curves.easeOut,
            child: _TabBar(
              key: tabBarKey,
              currentIndex: currentIndex,
              onTap: onTap,
            ),
          ),
        ],
      ),
    );
  }

  static const double _minimizedScale = 0.7;
  static const Duration _minimize = Duration(milliseconds: 300);
  static const Duration _fade = Duration(milliseconds: 200);
}

class _TabBar extends StatelessWidget {
  const _TabBar({super.key, required this.currentIndex, required this.onTap});

  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return FrostedSurface(
      borderRadius: BorderRadius.circular(MixtapeMetrics.pillRadius),
      child: SizedBox(
        height: MixtapeMetrics.tabBarHeight,
        child: Row(
          children: [
            for (var index = 0; index < _tabs.length; index++)
              Expanded(
                child: _TabItem(
                  tab: _tabs[index],
                  selected: index == currentIndex,
                  tokens: tokens,
                  onTap: () => onTap(index),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.tab,
    required this.selected,
    required this.tokens,
    required this.onTap,
  });

  final _DockTab tab;
  final bool selected;
  final MixtapeTokens tokens;
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
      // The glyph and its 10 pt label are decoration; one node per tab.
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          // 4 pt leaves the selected lozenge 48 pt tall inside the 56 pt bar.
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: selected
                  ? (dark
                        ? const Color.fromRGBO(255, 255, 255, 0.14)
                        : const Color.fromRGBO(255, 255, 255, 0.60))
                  : null,
              borderRadius: BorderRadius.circular(MixtapeMetrics.pillRadius),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  selected ? tab.selectedIcon : tab.icon,
                  size: MixtapeMetrics.tabIcon,
                  color: ink,
                ),
                const SizedBox(height: 2),
                Text(
                  tab.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  // The dock keeps its size at 200% text (board:
                  // Accessibility), so the label does not scale with it.
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

class _MiniPlayer extends StatelessWidget {
  const _MiniPlayer({
    super.key,
    required this.mini,
    required this.onTap,
    required this.onPlayPause,
    required this.onNext,
  });

  final MiniPlayerState mini;
  final VoidCallback? onTap;
  final VoidCallback? onPlayPause;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return FrostedSurface(
      borderRadius: BorderRadius.circular(MixtapeMetrics.pillRadius),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          height: MixtapeMetrics.miniPlayerHeight,
          child: Row(
            children: [
              const SizedBox(width: 7),
              SquareArt(
                url: mini.artworkUrl,
                size: MixtapeMetrics.miniArt,
                radius: 4,
                placeholder: tokens.tapeFill,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mini.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textScaler: TextScaler.noScaling,
                      style: tokens.body.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
                    Text(
                      mini.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textScaler: TextScaler.noScaling,
                      style: tokens.meta.copyWith(height: 1.2),
                    ),
                  ],
                ),
              ),
              _MiniButton(
                buttonKey: FrostedDock.playPauseKey,
                semanticsLabel: mini.playing ? 'Pause' : 'Play',
                icon: mini.playing
                    ? CupertinoIcons.pause_fill
                    : CupertinoIcons.play_fill,
                // A track Apple Music will not play here has no play/pause;
                // Next, the one way out of it, stays live (board → Dock).
                enabled: !mini.unavailable,
                color: mini.unavailable ? tokens.muted : tokens.text,
                onTap: onPlayPause,
              ),
              _MiniButton(
                buttonKey: FrostedDock.nextKey,
                semanticsLabel: 'Next',
                icon: CupertinoIcons.forward_fill,
                color: tokens.text,
                onTap: onNext,
              ),
              const SizedBox(width: 2),
            ],
          ),
        ),
      ),
    );
  }
}

/// 36 pt of glyph inside a 44 pt target — the board's accessibility floor.
class _MiniButton extends StatelessWidget {
  const _MiniButton({
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

  /// A disabled control still claims its tap — letting it fall through would
  /// open Now Playing from a button that is meant to do nothing.
  final bool enabled;

  @override
  Widget build(BuildContext context) => Semantics(
    label: semanticsLabel,
    button: true,
    enabled: enabled,
    container: true,
    excludeSemantics: true,
    child: GestureDetector(
      key: buttonKey,
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : () {},
      child: SizedBox.square(
        dimension: MixtapeMetrics.minTarget,
        child: Center(
          child: SizedBox.square(
            dimension: 36,
            child: Center(child: Icon(icon, size: 19, color: color)),
          ),
        ),
      ),
    ),
  );
}
