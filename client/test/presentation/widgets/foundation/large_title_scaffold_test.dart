import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/frosted_surface.dart';
import 'package:mixtape/presentation/widgets/foundation/glass_cluster.dart';
import 'package:mixtape/presentation/widgets/foundation/large_title_scaffold.dart';

const String _title = 'Mixes';

Finder get _smallBar => find.byKey(LargeTitleScaffold.smallBarKey);

Finder get _smallTitle =>
    find.descendant(of: _smallBar, matching: find.text(_title));

Finder _row(int index) => find.byKey(ValueKey('row-$index'));

Finder get _blurBands =>
    find.descendant(of: _smallBar, matching: find.byType(BackdropFilter));

/// Pumps the scaffold with a tall body so there is something to scroll.
Future<ScrollController> _pumpScaffold(
  WidgetTester tester, {
  bool disableAnimations = false,
  bool reduceTransparency = false,
  Widget? trailing,
  Widget? titleAccessory,
  Future<void> Function()? onRefresh,
  VoidCallback? onRowTap,
  Size size = const Size(390, 844),
  double textScale = 1,
  double topInset = 0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final controller = ScrollController();
  addTearDown(controller.dispose);

  Widget app = MaterialApp(
    theme: MixtapeTheme.light(),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: disableAnimations,
          textScaler: TextScaler.linear(textScale),
          padding: EdgeInsets.only(top: topInset),
        ),
        child: LargeTitleScaffold(
          title: _title,
          controller: controller,
          trailing: trailing,
          titleAccessory: titleAccessory,
          onRefresh: onRefresh,
          slivers: [
            SliverList.builder(
              itemCount: 20,
              itemBuilder: (context, index) => GestureDetector(
                key: ValueKey('row-$index'),
                behavior: HitTestBehavior.opaque,
                onTap: onRowTap,
                child: SizedBox(height: 60, child: Text('Row $index')),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  if (reduceTransparency) {
    app = FrostedSurfaceMode(reduceTransparency: true, child: app);
  }

  await tester.pumpWidget(app);
  return controller;
}

/// Scrolls past the collapse point and lets the fade finish.
Future<void> _collapse(WidgetTester tester, ScrollController controller) async {
  controller.jumpTo(LargeTitleScaffold.collapseThreshold + 40);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  group('LargeTitleScaffold', () {
    testWidgets('shows the large title and no small bar at offset 0', (
      tester,
    ) async {
      await _pumpScaffold(tester);

      expect(find.text(_title), findsOneWidget);
      expect(_smallBar, findsNothing);
      expect(
        tester.widget<Text>(find.text(_title)).style?.fontSize,
        MixtapeTokens.light.largeTitle.fontSize,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('collapses to a small title over a blur past the threshold', (
      tester,
    ) async {
      final controller = await _pumpScaffold(tester);

      await _collapse(tester, controller);

      expect(_smallTitle, findsOneWidget);
      expect(tester.widget<FadeTransition>(_smallBar).opacity.value, 1);

      // Four clipped bands of falling sigma stand in for the board's mask.
      final blurs = tester
          .widgetList<BackdropFilter>(_blurBands)
          .map((band) => band.filter)
          .toList();
      expect(blurs, [
        for (final sigma in LargeTitleScaffold.blurSigmas)
          ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
      ]);
      expect(LargeTitleScaffold.blurSigmas, [16.0, 10.0, 6.0, 3.0]);
      expect(
        tester.widgetList<ClipRect>(
          find.descendant(of: _smallBar, matching: find.byType(ClipRect)),
        ),
        hasLength(4),
      );
      expect(
        find.descendant(of: _smallBar, matching: find.byType(RepaintBoundary)),
        findsWidgets,
      );
      expect(
        tester.widget<Text>(_smallTitle).style?.fontSize,
        MixtapeTokens.light.smallTitle.fontSize,
      );
    });

    testWidgets('expands again when the title scrolls back into view', (
      tester,
    ) async {
      final controller = await _pumpScaffold(tester);
      await _collapse(tester, controller);

      controller.jumpTo(0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(_smallBar, findsNothing);
    });

    testWidgets('flips instantly when animations are disabled', (tester) async {
      final controller = await _pumpScaffold(tester, disableAnimations: true);

      controller.jumpTo(LargeTitleScaffold.collapseThreshold + 40);
      await tester.pump();

      expect(_smallTitle, findsOneWidget);
      expect(tester.widget<FadeTransition>(_smallBar).opacity.value, 1);
    });

    testWidgets('fades in over 180 ms when animations are enabled', (
      tester,
    ) async {
      final controller = await _pumpScaffold(tester);

      controller.jumpTo(LargeTitleScaffold.collapseThreshold + 40);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));

      final half = tester.widget<FadeTransition>(_smallBar).opacity.value;
      expect(half, greaterThan(0));
      expect(half, lessThan(1));

      await tester.pump(const Duration(milliseconds: 90));

      expect(tester.widget<FadeTransition>(_smallBar).opacity.value, 1);
    });

    testWidgets('drops the blur under reduced transparency', (tester) async {
      final controller = await _pumpScaffold(tester, reduceTransparency: true);

      await _collapse(tester, controller);

      expect(_smallTitle, findsOneWidget);
      expect(_blurBands, findsNothing);

      // Still a fade, not a hard bottom edge — just an opaque one.
      final scrim = tester
          .widgetList<DecoratedBox>(
            find.descendant(of: _smallBar, matching: find.byType(DecoratedBox)),
          )
          .map((box) => box.decoration)
          .whereType<BoxDecoration>()
          .map((decoration) => decoration.gradient)
          .whereType<LinearGradient>()
          .single;
      expect(scrim.colors.first.a, 1);
      expect(scrim.colors.last.a, 0);
      expect(scrim.stops, [0, LargeTitleScaffold.blurFadeStart, 1]);
    });

    testWidgets('never draws a bottom hairline on the bar', (tester) async {
      final controller = await _pumpScaffold(tester);
      await _collapse(tester, controller);

      final borders = tester
          .widgetList<DecoratedBox>(
            find.descendant(of: _smallBar, matching: find.byType(DecoratedBox)),
          )
          .map((box) => box.decoration)
          .whereType<BoxDecoration>()
          .map((decoration) => decoration.border);

      expect(borders, everyElement(isNull));
    });

    testWidgets('lets touches through to the trailing cluster and the body', (
      tester,
    ) async {
      var clusterTaps = 0;
      var rowTaps = 0;
      final controller = await _pumpScaffold(
        tester,
        onRowTap: () => rowTaps++,
        trailing: GlassCluster(
          children: [
            GlassButton(
              icon: CupertinoIcons.search,
              label: 'Search',
              onPressed: () => clusterTaps++,
            ),
          ],
        ),
      );

      await tester.tap(find.byType(GlassButton));
      await tester.pump();
      expect(clusterTaps, 1);

      await tester.tap(_row(0));
      await tester.pump();
      expect(rowTaps, 1);

      await _collapse(tester, controller);

      // A row now runs under the pinned bar; the overlay must not eat the
      // part of it that the bar covers, small title included.
      final rect = tester.getRect(_row(1));
      final underTheBar = Offset(rect.center.dx, rect.top + 4);
      expect(
        underTheBar.dy,
        lessThan(LargeTitleScaffold.barHeight),
        reason: 'the tap point should land inside the collapsed bar',
      );
      await tester.tapAt(underTheBar);
      await tester.pump();
      expect(rowTaps, 2);
    });

    testWidgets('mounts a refresh control only when onRefresh is given', (
      tester,
    ) async {
      // The control has no extent at rest, so it counts as offstage.
      final refresh = find.byType(
        CupertinoSliverRefreshControl,
        skipOffstage: false,
      );

      await _pumpScaffold(tester);
      expect(refresh, findsNothing);

      await _pumpScaffold(tester, onRefresh: () async {});
      expect(refresh, findsOneWidget);
    });

    testWidgets('wraps the title at 200% text on a 320 pt screen', (
      tester,
    ) async {
      await _pumpScaffold(
        tester,
        size: const Size(320, 700),
        textScale: 2,
        trailing: GlassCluster(
          children: [
            GlassButton(
              icon: CupertinoIcons.search,
              label: 'Search',
              onPressed: () {},
            ),
          ],
        ),
      );

      expect(tester.takeException(), isNull);
      // Two lines of 34 pt at 200%: taller than one scaled line, not clipped.
      final title = tester.getSize(find.text(_title));
      expect(
        title.height,
        greaterThan(MixtapeTokens.light.largeTitle.fontSize! * 2),
      );
      expect(tester.getSize(find.byType(LargeTitleScaffold)).width, 320);
    });

    testWidgets('collapses at the same offset under a 54 pt safe area', (
      tester,
    ) async {
      // The inset pads the title block and the bar alike, so it cancels out.
      final controller = await _pumpScaffold(tester, topInset: 54);

      controller.jumpTo(LargeTitleScaffold.collapseThreshold - 1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_smallBar, findsNothing);

      await _collapse(tester, controller);
      expect(_smallTitle, findsOneWidget);
      expect(
        tester.getSize(_smallBar).height,
        54 + LargeTitleScaffold.barHeight,
      );
    });

    testWidgets('owns and disposes a controller when none is given', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: MixtapeTheme.light(),
          home: const LargeTitleScaffold(
            title: _title,
            slivers: [SliverToBoxAdapter(child: SizedBox(height: 1200))],
          ),
        ),
      );

      final scrollable = find.byType(Scrollable);
      final position = tester.state<ScrollableState>(scrollable).position;
      position.jumpTo(LargeTitleScaffold.collapseThreshold + 40);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(_smallTitle, findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  });

  group('GlassCluster', () {
    testWidgets('keeps 44 pt targets and semantic labels', (tester) async {
      final handle = tester.ensureSemantics();
      var plays = 0;

      await tester.pumpWidget(
        MaterialApp(
          theme: MixtapeTheme.light(),
          home: Center(
            child: GlassCluster(
              children: [
                GlassButton(
                  icon: CupertinoIcons.search,
                  label: 'Search',
                  onPressed: () {},
                ),
                GlassButton(
                  icon: CupertinoIcons.play_fill,
                  label: 'Play',
                  onPressed: () => plays++,
                ),
              ],
            ),
          ),
        ),
      );

      final buttons = find.byType(GlassButton);
      expect(buttons, findsNWidgets(2));
      for (final size
          in tester
              .widgetList<GlassButton>(buttons)
              .indexed
              .map((entry) => tester.getSize(buttons.at(entry.$1)))) {
        expect(size.width, greaterThanOrEqualTo(MixtapeMetrics.minTarget));
        expect(size.height, greaterThanOrEqualTo(MixtapeMetrics.minTarget));
      }

      expect(
        tester.getSemantics(find.byType(GlassButton).first),
        matchesSemantics(
          label: 'Search',
          isButton: true,
          hasTapAction: true,
          hasEnabledState: true,
          isEnabled: true,
        ),
      );

      await tester.tap(find.byType(GlassButton).last);
      await tester.pump();
      expect(plays, 1);

      // The board's pill: one frosted surface holding both buttons.
      expect(find.byType(FrostedSurface), findsOneWidget);
      handle.dispose();
    });

    testWidgets('paints a 20 pt glyph in the title ink', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: MixtapeTheme.light(),
          home: Center(
            child: GlassCluster(
              children: [
                GlassButton(icon: CupertinoIcons.ellipsis, label: 'More'),
              ],
            ),
          ),
        ),
      );

      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.size, 20);
      expect(icon.color, MixtapeTokens.light.text);
    });
  });
}
