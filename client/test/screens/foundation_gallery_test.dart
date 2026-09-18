import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/main.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/screens/debug/foundation_gallery_screen.dart';
import 'package:mixtape/presentation/screens/sign_in_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/large_title_scaffold.dart';

/// Pumps the debug gallery at [size] in [brightness].
///
/// Animations are disabled: the gallery deliberately holds a spinning cassette,
/// which would otherwise keep `pumpAndSettle` scheduling frames forever.
Future<void> _pumpGallery(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  Size size = const Size(390, 844),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      theme: MixtapeTheme.light(),
      darkTheme: MixtapeTheme.dark(),
      themeMode: brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: const FoundationGalleryScreen(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The scale the gallery is currently imposing on its body.
double _scale(WidgetTester tester) =>
    tester
        .widget<MediaQuery>(
          find.byKey(FoundationGalleryScreen.textScaleScopeKey),
        )
        .data
        .textScaler
        .scale(100) /
    100;

/// Scrolls the whole gallery top to bottom and back, failing on the first
/// layout exception — an overflow anywhere in it.
Future<void> _scrollThrough(WidgetTester tester) async {
  final scrollable = find.byType(Scrollable).first;
  for (final word in FoundationGalleryScreen.sectionWords) {
    await tester.scrollUntilVisible(
      find.text(word),
      200,
      scrollable: scrollable,
    );
    expect(tester.takeException(), isNull, reason: 'section "$word" threw');
  }
  // Back to the very top, so the trailing cluster is on screen and tappable
  // again rather than sitting in the sliver cache above the viewport.
  await tester.drag(scrollable, const Offset(0, 20000));
  await tester.pumpAndSettle();
}

/// Disposes the tree so the composer's example timer does not outlive the test.
Future<void> _teardown(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
}

void main() {
  // Sign-in's cassette turns for as long as the screen is on show, so a
  // settle would never finish; reduced motion holds its hubs still.
  setUp(
    () =>
        TestWidgetsFlutterBinding.ensureInitialized()
            .platformDispatcher
            .accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
          disableAnimations: true,
        ),
  );
  tearDown(
    () => TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .clearAccessibilityFeaturesTestValue(),
  );

  for (final brightness in Brightness.values) {
    testWidgets('the gallery renders every section in ${brightness.name}', (
      tester,
    ) async {
      await _pumpGallery(tester, brightness: brightness);

      expect(tester.takeException(), isNull);
      expect(find.byType(FoundationGalleryScreen), findsOneWidget);

      // The body is a lazy sliver list, so each section is scrolled to in
      // turn — which also proves the gallery is tall enough to collapse the
      // large title.
      for (final word in FoundationGalleryScreen.sectionWords) {
        await tester.scrollUntilVisible(
          find.text(word),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(
          find.text(word),
          findsOneWidget,
          reason: 'section "$word" is missing from the gallery',
        );
        expect(tester.takeException(), isNull);
      }
      expect(find.byKey(LargeTitleScaffold.smallBarKey), findsOneWidget);

      await _teardown(tester);
    });
  }

  testWidgets('the text-scale button cycles 1.0 → 1.5 → 2.0 → 1.0 without '
      'overflowing on a small screen', (tester) async {
    await _pumpGallery(tester, size: const Size(320, 568));
    expect(_scale(tester), 1.0);

    for (final expected in [1.5, 2.0, 1.0]) {
      await tester.tap(find.byKey(FoundationGalleryScreen.textScaleButtonKey));
      await tester.pumpAndSettle();
      expect(_scale(tester), expected);
      expect(
        tester.takeException(),
        isNull,
        reason: 'the gallery overflowed at ${expected}x text',
      );
      // The body is lazy: only a scroll through the whole thing proves the
      // sections below the fold survive this scale.
      await _scrollThrough(tester);
    }

    await _teardown(tester);
  });

  testWidgets('the theme button overrides the ambient brightness', (
    tester,
  ) async {
    await _pumpGallery(tester);
    final body = find.byKey(FoundationGalleryScreen.bodyKey);
    expect(Theme.of(tester.element(body)).brightness, Brightness.light);

    await tester.tap(find.byKey(FoundationGalleryScreen.themeButtonKey));
    await tester.pumpAndSettle();

    expect(Theme.of(tester.element(body)).brightness, Brightness.dark);
    expect(tester.takeException(), isNull);

    await _teardown(tester);
  });

  testWidgets('without the define the app still gates on auth', (tester) async {
    expect(showFoundationGallery, isFalse);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [tokenStoreProvider.overrideWithValue(InMemoryTokenStore())],
        child: const MixtapeApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SignInScreen), findsOneWidget);
    expect(find.byType(FoundationGalleryScreen), findsNothing);
  });
}
