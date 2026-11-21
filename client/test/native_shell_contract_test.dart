import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final dock = File('ios/Runner/ShellDock.swift').readAsStringSync();
  final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
  final project = File(
    'ios/Runner.xcodeproj/project.pbxproj',
  ).readAsStringSync();

  test('the dock speaks the mixtape/shell contract', () {
    expect(dock, contains('mixtape/shell'));

    for (final method in [
      'isAvailable',
      'setTab',
      'show',
      'hide',
      'setMinimized',
      'setMiniPlayer',
      'setAppearance',
      'getReduceTransparency',
    ]) {
      expect(dock, contains('case "$method"'), reason: '$method is handled');
    }

    for (final callback in [
      'tabChanged',
      'miniPlayerTapped',
      'miniPlayerPlayPause',
      'miniPlayerNext',
      'reduceTransparencyChanged',
    ]) {
      expect(
        dock,
        contains('invokeMethod("$callback"'),
        reason: '$callback is reported back',
      );
    }
  });

  test('the mini-player honours the unavailable flag', () {
    // The key travels in the setMiniPlayer map (MiniPlayerState.toMap).
    expect(dock, contains('args["unavailable"] as? Bool ?? false'));
    // Play/pause goes dead and dim; Next is the way out, so it stays live.
    expect(dock, contains('playPauseButton.isEnabled = !unavailable'));
    expect(dock, contains('playPauseButton.alpha = unavailable ? 0.35 : 1'));
    expect(dock, contains('nextButton.isEnabled = true'));
    // Same line the pill and Now Playing say.
    expect(dock, contains('"Not available in your region"'));
    expect(dock, contains('playPauseButton.accessibilityHint'));
  });

  test('the dock carries the four approved tabs', () {
    for (final title in ['Home', 'Mixes', 'Library', 'You']) {
      expect(dock, contains('title: "$title"'));
    }
    expect(dock, contains('"house"'));
    expect(dock, contains('"house.fill"'));
    expect(dock, contains('"books.vertical"'));
    expect(dock, contains('"person"'));
    expect(dock, contains('"person.fill"'));
    // Mixes wants the cassette; older symbol sets fall back to a list.
    expect(dock, contains('"recordingtape"'));
    expect(dock, contains('"music.note.list"'));
  });

  test('the dock is iOS 26 glass, hosted in the window', () {
    expect(dock, contains('UIGlassEffect'));
    expect(dock, contains('#available(iOS 26'));
    expect(dock, contains('UIVisualEffectView'));
    expect(dock, contains('bringSubviewToFront'));
    // Tab switches tick like every other toggler (Haptics → select).
    expect(dock, contains('UISelectionFeedbackGenerator'));
    // The board's 22 pt margins, pinned by hand: a bare bar is edge-to-edge.
    // Measured from the safe area's sides, so a system bar standing on a
    // side edge (iPhone Duo) pushes the dock over with the content.
    for (final view in ['tabBar', 'miniPlayer']) {
      expect(
        dock,
        contains(
          '$view.leadingAnchor.constraint(\n'
          '        equalTo: hostView.safeAreaLayoutGuide.leadingAnchor, '
          'constant: 22)',
        ),
      );
      expect(
        dock,
        contains(
          '$view.trailingAnchor.constraint(\n'
          '        equalTo: hostView.safeAreaLayoutGuide.trailingAnchor, '
          'constant: -22)',
        ),
      );
    }
    // A route inside a mix wins over a mini-player update.
    expect(dock, contains('isRouteHidden'));
    // Cancelled fades must not apply their completion.
    expect(dock, contains('guard finished else { return }'));
    // The bar lives in the window, out of Flutter's compositor's reach.
    expect(appDelegate, contains('ShellDock('));
    expect(appDelegate, contains('#available(iOS 26'));
    expect(appDelegate, contains('hostView: window'));
  });

  // 2026-11-17 (founder): on iOS 27.1 the window's root is a tab controller
  // whose own tab bar the system stands in the iPhone Duo's vertical bar.
  test('the tabs move into the system vertical bar on iOS 27.1', () {
    expect(dock, contains('class ShellTabController: UITabBarController'));
    expect(dock, contains('@available(iOS 27.1, *)'));
    expect(dock, contains('traitCollection.verticalBarEdge != .unspecified'));
    expect(
      dock,
      contains('UITraitCollection.systemTraitsAffectingVerticalBarEdge'),
    );
    // One Flutter controller moves between the tab slots, and a move never
    // tells it it disappeared.
    expect(
      dock,
      contains(
        'override var shouldAutomaticallyForwardAppearanceMethods: Bool '
        '{ false }',
      ),
    );
    expect(dock, contains('window.rootViewController = host'));
    // The bare dock stands down while the tabs are in the vertical bar, and
    // Flutter is told where they are.
    expect(dock, contains('let showBare = !isVertical'));
    expect(dock, contains('"verticalBarChanged"'));
    expect(dock, contains('case "isVerticalBar":'));
    // Mixtape's ink, not the system blue.
    expect(dock, contains('host.view.tintColor = host.tabBar.tintColor'));
  });

  test('the dock answers and watches reduced transparency and motion', () {
    expect(dock, contains('UIAccessibility.isReduceTransparencyEnabled'));
    expect(
      dock,
      contains('UIAccessibility.reduceTransparencyStatusDidChangeNotification'),
    );
    expect(dock, contains('UIAccessibility.isReduceMotionEnabled'));
  });

  test('the liquid glass platform view is registered', () {
    expect(dock, contains('mixtape/liquid_glass'));
    expect(dock, contains('LiquidGlassViewFactory'));
    expect(dock, contains('isDark'));
    expect(dock, contains('systemThinMaterial'));
    // Flutter's clip never reaches a platform view: the glass must round
    // itself to the radius the widget hands over (the Home panel's corners).
    expect(dock, contains('"cornerRadius"'));
    expect(dock, contains('effectView.layer.cornerRadius'));
    expect(dock, contains('effectView.clipsToBounds = true'));
    // The header buttons ask for a true circle (revision 3, header buttons).
    expect(dock, contains('params?["circle"]'));
    expect(dock, contains('circle ? .circular : .continuous'));
    expect(appDelegate, contains('mixtape/liquid_glass'));
    expect(appDelegate, contains('LiquidGlassViewFactory()'));
  });

  test('ShellDock.swift is a member of the Runner target', () {
    expect(
      project,
      contains('/* ShellDock.swift */ = {isa = PBXFileReference'),
    );
    expect(
      project,
      contains('/* ShellDock.swift in Sources */ = {isa = PBXBuildFile'),
    );

    final sources = RegExp(
      r'isa = PBXSourcesBuildPhase;[\s\S]*?files = \([\s\S]*?\);',
    ).allMatches(project);
    expect(
      sources.any((m) => m.group(0)!.contains('ShellDock.swift in Sources')),
      isTrue,
      reason: 'ShellDock.swift must be compiled by a Sources build phase',
    );
  });
}
