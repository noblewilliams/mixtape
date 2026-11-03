/// Whether anything is drawn over a piece of native glass.
///
/// A `UiKitView` composites above every Flutter layer, route barriers
/// included, so native Liquid Glass under a menu, alert or sheet punches
/// through its dim. Its own route being current is not enough to know: menus
/// and alerts go on the root navigator, where a tab's screen stays current on
/// its own navigator beneath them. Every navigator that can stack something
/// over glass carries a [GlassOcclusionObserver]; a surface asks
/// [GlassOcclusion.isCovered] whether any route sits above the route holding
/// it, on any of them. A route leaving counts until its exit animation ends,
/// so the glass does not come back while the dim is still fading out.
library;

import 'package:flutter/widgets.dart';

/// Watches one navigator for [GlassOcclusion]. Give each navigator its own.
class GlassOcclusionObserver extends NavigatorObserver {
  /// The navigator's routes still on screen, bottom first, including any
  /// popped route whose exit animation is running.
  final List<Route<dynamic>> _onScreen = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // A navigator's first route: anything left from an earlier navigator
    // this observer watched is gone.
    if (previousRoute == null) _onScreen.clear();
    GlassOcclusion._observers.add(this);
    _onScreen.add(route);
    GlassOcclusion._changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    final animation = route is TransitionRoute ? route.animation : null;
    if (animation == null || animation.status == AnimationStatus.dismissed) {
      _drop(route);
      return;
    }
    void listener(AnimationStatus status) {
      if (status != AnimationStatus.dismissed) return;
      animation.removeStatusListener(listener);
      _drop(route);
    }

    animation.addStatusListener(listener);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _drop(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = oldRoute == null ? -1 : _onScreen.indexOf(oldRoute);
    if (newRoute != null) {
      if (index >= 0) {
        _onScreen[index] = newRoute;
      } else {
        _onScreen.add(newRoute);
      }
    } else if (index >= 0) {
      _onScreen.removeAt(index);
    }
    GlassOcclusion._changed();
  }

  void _drop(Route<dynamic> route) {
    if (_onScreen.remove(route)) GlassOcclusion._changed();
  }
}

abstract final class GlassOcclusion {
  static final Set<GlassOcclusionObserver> _observers = {};
  static final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  /// Fires whenever a watched navigator's on-screen routes change.
  static Listenable get changes => _revision;

  static void _changed() => _revision.value++;

  /// True when some watched navigator has a route on screen above the route
  /// that holds [context].
  static bool isCovered(BuildContext context) {
    Set<BuildContext>? ancestors;
    for (final observer in _observers.toList()) {
      if (observer.navigator == null) {
        _observers.remove(observer);
        continue;
      }
      // A disposed route is off screen whatever the list still says.
      final routes = observer._onScreen
          .where((route) => route.navigator != null)
          .toList(growable: false);
      if (routes.length < 2) continue;
      if (ancestors == null) {
        ancestors = {context};
        context.visitAncestorElements((element) {
          ancestors!.add(element);
          return true;
        });
      }
      for (var i = routes.length - 1; i >= 0; i--) {
        final route = routes[i];
        final subtree = route is ModalRoute ? route.subtreeContext : null;
        if (subtree != null && ancestors.contains(subtree)) {
          if (i < routes.length - 1) return true;
          break;
        }
      }
    }
    return false;
  }
}
