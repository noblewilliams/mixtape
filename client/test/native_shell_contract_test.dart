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
    expect(dock, contains('UIImpactFeedbackGenerator'));
    // The board's 22 pt margins, pinned by hand: a bare bar is edge-to-edge.
    expect(
      dock,
      contains(
        'tabBar.leadingAnchor.constraint(equalTo: hostView.leadingAnchor, '
        'constant: 22)',
      ),
    );
    // A route inside a mix wins over a mini-player update.
    expect(dock, contains('isRouteHidden'));
    // Cancelled fades must not apply their completion.
    expect(dock, contains('guard finished else { return }'));
    // The bar lives in the window, out of Flutter's compositor's reach.
    expect(appDelegate, contains('ShellDock('));
    expect(appDelegate, contains('#available(iOS 26'));
    expect(appDelegate, contains('hostView: window'));
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
