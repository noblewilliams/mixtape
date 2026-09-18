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
/// carry results (the shape sheet returns an `EnergyShapeChoice`).
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
