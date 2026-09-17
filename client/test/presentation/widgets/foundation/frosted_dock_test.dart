import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/shell/mini_player_state.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/frosted_dock.dart';

const _tabs = ['Home', 'Mixes', 'Library', 'You'];

Future<void> _pump(
  WidgetTester tester,
  Widget dock, {
  bool dark = false,
  Size size = const Size(390, 844),
  bool disableAnimations = false,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? MixtapeTheme.dark() : MixtapeTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          padding: const EdgeInsets.only(bottom: 34),
          disableAnimations: disableAnimations,
        ),
        child: Scaffold(
          body: Stack(
            children: [Positioned(left: 0, right: 0, bottom: 0, child: dock)],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

const _mini = MiniPlayerState(
  visible: true,
  title: 'Slow kitchen morning',
  artist: 'Khruangbin',
  playing: true,
);

void main() {
  testWidgets('draws four labelled tabs and reports the one tapped', (
    tester,
  ) async {
    var tapped = -1;
    await _pump(
      tester,
      FrostedDock(currentIndex: 0, onTap: (index) => tapped = index),
    );

    for (final label in _tabs) {
      expect(find.text(label), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('^$label\$')),
        findsOneWidget,
        reason: '$label needs its own semantics label',
      );
    }

    await tester.tap(find.text('Library'));
    expect(tapped, 2);
  });

  testWidgets('no mini-player until one is visible', (tester) async {
    await _pump(tester, FrostedDock(currentIndex: 0, onTap: (_) {}));
    expect(find.text('Khruangbin'), findsNothing);

    await _pump(
      tester,
      FrostedDock(currentIndex: 0, onTap: (_) {}, mini: _mini),
    );
    await tester.pumpAndSettle();

    expect(find.text('Slow kitchen morning'), findsOneWidget);
    expect(find.text('Khruangbin'), findsOneWidget);
  });

  testWidgets('mini-player reports tap, play/pause and next', (tester) async {
    var taps = 0;
    var playPauses = 0;
    var nexts = 0;
    await _pump(
      tester,
      FrostedDock(
        currentIndex: 0,
        onTap: (_) {},
        mini: _mini,
        onMiniTap: () => taps++,
        onMiniPlayPause: () => playPauses++,
        onMiniNext: () => nexts++,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(FrostedDock.playPauseKey));
    await tester.tap(find.byKey(FrostedDock.nextKey));
    await tester.tap(find.text('Slow kitchen morning'));

    expect(playPauses, 1);
    expect(nexts, 1);
    expect(taps, 1);
  });

  testWidgets('every dock control clears a 44 pt target', (tester) async {
    await _pump(
      tester,
      FrostedDock(
        currentIndex: 1,
        onTap: (_) {},
        mini: _mini,
        onMiniPlayPause: () {},
        onMiniNext: () {},
      ),
    );
    await tester.pumpAndSettle();

    for (final key in [FrostedDock.playPauseKey, FrostedDock.nextKey]) {
      final size = tester.getSize(find.byKey(key));
      expect(size.width, greaterThanOrEqualTo(MixtapeMetrics.minTarget));
      expect(size.height, greaterThanOrEqualTo(MixtapeMetrics.minTarget));
    }

    for (final label in _tabs) {
      final size = tester.getSize(find.bySemanticsLabel(RegExp('^$label\$')));
      expect(size.width, greaterThanOrEqualTo(MixtapeMetrics.minTarget));
      expect(size.height, greaterThanOrEqualTo(MixtapeMetrics.minTarget));
    }
  });

  testWidgets('minimized shrinks the tab bar to 70% from the bottom', (
    tester,
  ) async {
    await _pump(tester, FrostedDock(currentIndex: 0, onTap: (_) {}));
    expect(
      tester.widget<AnimatedScale>(find.byKey(FrostedDock.tabScaleKey)).scale,
      1.0,
    );

    await _pump(
      tester,
      FrostedDock(currentIndex: 0, onTap: (_) {}, minimized: true),
    );
    final scaled = tester.widget<AnimatedScale>(
      find.byKey(FrostedDock.tabScaleKey),
    );

    expect(scaled.scale, 0.7);
    expect(scaled.alignment, Alignment.bottomCenter);
    expect(scaled.duration, const Duration(milliseconds: 300));
    expect(scaled.curve, Curves.easeOut);
  });

  testWidgets('minimizing is instant when animations are disabled', (
    tester,
  ) async {
    await _pump(
      tester,
      FrostedDock(currentIndex: 0, onTap: (_) {}, minimized: true),
      disableAnimations: true,
    );

    expect(
      tester
          .widget<AnimatedScale>(find.byKey(FrostedDock.tabScaleKey))
          .duration,
      Duration.zero,
    );
  });

  testWidgets('holds the board geometry', (tester) async {
    await _pump(
      tester,
      FrostedDock(currentIndex: 0, onTap: (_) {}, mini: _mini),
    );
    await tester.pumpAndSettle();

    final mini = tester.getRect(find.byKey(FrostedDock.miniPlayerKey));
    final tabs = tester.getRect(find.byKey(FrostedDock.tabBarKey));

    expect(mini.height, MixtapeMetrics.miniPlayerHeight);
    expect(tabs.height, MixtapeMetrics.tabBarHeight);
    expect(mini.left, MixtapeMetrics.dockSideMargin);
    expect(tabs.left, MixtapeMetrics.dockSideMargin);
    expect(390 - mini.right, MixtapeMetrics.dockSideMargin);
    expect(tabs.top - mini.bottom, MixtapeMetrics.dockGap);
    // The selected lozenge: 48 pt inside the 56 pt bar.
    final lozenge = tester.getSize(
      find
          .descendant(
            of: find.bySemanticsLabel(RegExp('^Home\$')),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    expect(lozenge.height, 48);
    // Safe area plus the board's 8 pt breathing room.
    expect(844 - tabs.bottom, 34 + 8);
    expect(
      kFrostedDockHeight,
      MixtapeMetrics.miniPlayerHeight +
          MixtapeMetrics.dockGap +
          MixtapeMetrics.tabBarHeight +
          8,
    );
  });

  for (final width in [320.0, 430.0]) {
    for (final dark in [false, true]) {
      testWidgets('renders at $width in ${dark ? 'dark' : 'light'}', (
        tester,
      ) async {
        await _pump(
          tester,
          FrostedDock(
            currentIndex: 3,
            onTap: (_) {},
            mini: _mini,
            onMiniPlayPause: () {},
            onMiniNext: () {},
          ),
          dark: dark,
          size: Size(width, 800),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('You'), findsOneWidget);
      });
    }
  }
}
