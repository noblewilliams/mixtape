/// The per-tab route observer, and the scope that hands it to the screens
/// inside that tab.
///
/// The shell already watches each tab's navigator to hide the dock while
/// something sits above a tab root. A tab root that has to react to the same
/// fact — Home's panel must disappear under any modal (smoke round four,
/// note 2) — subscribes to that same observer as a [RouteAware] rather than
/// polling `ModalRoute.isCurrent` every frame.
library;

import 'package:flutter/material.dart';

/// The observer type the shell installs on every tab navigator.
///
/// `ModalRoute<dynamic>` rather than `ModalRoute<void>` on purpose:
/// [RouteObserver] notifies a subscriber only when both the route arriving and
/// the route below it are of its own type, and the sheets that open over Home
/// carry results (the menus and pickers return what was chosen).
typedef ShellRouteObserver = RouteObserver<ModalRoute<dynamic>>;

/// Publishes a tab's [ShellRouteObserver] to everything built inside it.
class ShellRouteObserverScope extends InheritedWidget {
  const ShellRouteObserverScope({
    super.key,
    required this.observer,
    required super.child,
  });

  final ShellRouteObserver observer;

  /// The nearest tab's observer, or null when the screen is built outside the
  /// shell (a bare pump in a test, a screen shown by the gate).
  static ShellRouteObserver? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ShellRouteObserverScope>()
      ?.observer;

  @override
  bool updateShouldNotify(ShellRouteObserverScope oldWidget) =>
      oldWidget.observer != observer;
}

/// Which tab a route lives in, for everything pushed onto that tab's
/// navigator (the observer scope above wraps only the tab's root). A
/// conversation asks it whether it is actually on screen: the shell keeps
/// every tab's stack alive in an [IndexedStack], and a conversation pushed in
/// a tab the listener has left is built but not seen.
class ShellTabScope extends InheritedWidget {
  const ShellTabScope({super.key, required this.index, required super.child});

  /// The tab's index in the shell's tab order.
  final int index;

  /// The nearest tab, or null outside the shell.
  static int? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ShellTabScope>()?.index;

  @override
  bool updateShouldNotify(ShellTabScope oldWidget) => oldWidget.index != index;
}
