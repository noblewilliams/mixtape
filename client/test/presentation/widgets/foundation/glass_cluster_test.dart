import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/shell/shell_channel.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/frosted_surface.dart';
import 'package:mixtape/presentation/widgets/foundation/glass_cluster.dart';
import 'package:mixtape/presentation/widgets/foundation/liquid_glass_surface.dart';

Widget _app(Widget child, {bool reduceTransparency = false}) => MaterialApp(
  theme: MixtapeTheme.light(),
  home: FrostedSurfaceMode(
    reduceTransparency: reduceTransparency,
    child: Center(child: child),
  ),
);

final _pair = GlassCluster(
  children: [
    GlassButton(icon: CupertinoIcons.back, label: 'Back', onPressed: () {}),
    GlassButton(icon: CupertinoIcons.ellipsis, label: 'More', onPressed: () {}),
  ],
);

void main() {
  tearDown(LiquidGlassSurface.resetAvailabilityForTests);

  testWidgets('each button is its own 34 pt glass circle, 4 pt apart', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_pair));

    final buttons = find.byType(GlassButton);
    expect(buttons, findsNWidgets(2));
    for (var i = 0; i < 2; i++) {
      expect(tester.getSize(buttons.at(i)), const Size(44, 44));
      final glass = find.descendant(
        of: buttons.at(i),
        matching: find.byType(LiquidGlassSurface),
      );
      expect(glass, findsOneWidget);
      expect(tester.getSize(glass), const Size(34, 34));
      expect(
        tester.getCenter(glass),
        tester.getCenter(buttons.at(i)),
        reason: 'the circle is centred in its 44 pt target',
      );
      final surface = tester.widget<LiquidGlassSurface>(glass);
      expect(surface.circle, isTrue);
      expect(surface.borderRadius, BorderRadius.circular(17));
    }
    expect(
      tester.getTopLeft(buttons.at(1)).dx -
          tester.getTopRight(buttons.at(0)).dx,
      GlassCluster.gap,
    );
    expect(GlassCluster.gap, 4);
    expect(tester.widget<Icon>(find.byType(Icon).first).size, 17);
  });

  testWidgets('the cluster draws no capsule of its own', (tester) async {
    await tester.pumpWidget(_app(_pair));
    // Two surfaces, one per button: nothing wraps the pair.
    expect(find.byType(FrostedSurface), findsNWidgets(2));
    expect(
      find.ancestor(
        of: find.byType(GlassButton).first,
        matching: find.byType(FrostedSurface),
      ),
      findsNothing,
    );
  });

  testWidgets(
    'falls back to frosted glass, opaque under reduced transparency',
    (tester) async {
      await tester.pumpWidget(_app(_pair, reduceTransparency: true));
      final fill =
          tester
                  .widget<DecoratedBox>(
                    find
                        .descendant(
                          of: find.byType(FrostedSurface).first,
                          matching: find.byType(DecoratedBox),
                        )
                        .at(1),
                  )
                  .decoration
              as BoxDecoration;
      expect(fill.color, MixtapeTokens.light.scrimBase);
      expect(find.byType(BackdropFilter), findsNothing);
    },
  );

  group('on iOS with native glass', () {
    late ShellChannel channel;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      const method = MethodChannel('test/glass');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(method, (_) async => true);
      channel = ShellChannel.forTesting(channel: method);
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    Future<void> primeNative(WidgetTester tester) async {
      await tester.pumpWidget(
        _app(LiquidGlassSurface(channel: channel, child: const SizedBox())),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('hosts the native view as a circle', (tester) async {
      await primeNative(tester);
      await tester.pumpWidget(_app(_pair));
      final views = tester.widgetList<UiKitView>(find.byType(UiKitView));
      expect(views, hasLength(2));
      for (final view in views) {
        final params = view.creationParams! as Map<String, Object?>;
        expect(params['circle'], isTrue);
        expect(params['cornerRadius'], 17.0);
      }
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('reduced transparency skips the native glass', (tester) async {
      await primeNative(tester);
      await tester.pumpWidget(_app(_pair, reduceTransparency: true));
      expect(find.byType(UiKitView), findsNothing);
      expect(find.byType(FrostedSurface), findsNWidgets(2));
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a button under a sheet steps down to the fallback', (
      tester,
    ) async {
      await primeNative(tester);
      await tester.pumpWidget(_app(_pair));
      expect(find.byType(UiKitView), findsNWidgets(2));
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.push(
        PageRouteBuilder<void>(
          opaque: false,
          pageBuilder: (_, _, _) => const SizedBox.expand(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(UiKitView), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  testWidgets('a labelled button wears its own 34 pt capsule', (tester) async {
    await tester.pumpWidget(
      _app(
        GlassCluster(
          children: [
            GlassLabelButton(
              icon: CupertinoIcons.music_albums,
              label: 'Your music',
              onPressed: () {},
            ),
          ],
        ),
      ),
    );
    final glass = find.byType(LiquidGlassSurface);
    expect(glass, findsOneWidget);
    expect(tester.getSize(glass).height, 34);
    expect(tester.getSize(find.byType(GlassLabelButton)).height, 44);
  });
}
