import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/gradient_background.dart';
import 'package:mixtape/presentation/widgets/foundation/page_insets.dart';

/// The unfolded iPhone Duo in landscape, as the simulator reports it: the
/// status column stands on the right edge as an 84 pt inset, and the top,
/// with no status bar across it, has no inset at all.
const _duoOpenLandscape = MediaQueryData(
  size: Size(951, 669),
  padding: EdgeInsets.only(right: 84, bottom: 34),
  viewPadding: EdgeInsets.only(right: 84, bottom: 34),
);

void _sizeView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('a page stands clear of a side-edge bar', (tester) async {
    _sizeView(tester, _duoOpenLandscape.size);
    late MediaQueryData inner;
    late double bleedLeft, bleedRight;
    await tester.pumpWidget(
      MediaQuery(
        data: _duoOpenLandscape,
        child: PageInsets(
          child: Builder(
            builder: (context) {
              inner = MediaQuery.of(context);
              bleedLeft = GradientBleed.leftOf(context);
              bleedRight = GradientBleed.rightOf(context);
              return const SizedBox.expand(key: Key('page'));
            },
          ),
        ),
      ),
    );

    final page = tester.getRect(find.byKey(const Key('page')));
    expect(page.left, 0);
    expect(page.right, 951 - 84);
    // Consumed here, so nothing inside counts the bar twice.
    expect(inner.padding.right, 0);
    expect(inner.viewPadding.right, 0);
    expect(inner.padding.bottom, 34);
    // A screen painting its own gradient still reaches under the bar.
    expect(bleedLeft, 0);
    expect(bleedRight, 84);
  });

  testWidgets('a top with no status bar still gets room above the header', (
    tester,
  ) async {
    _sizeView(tester, _duoOpenLandscape.size);
    late MediaQueryData inner;
    await tester.pumpWidget(
      MediaQuery(
        data: _duoOpenLandscape,
        child: PageInsets(
          child: Builder(
            builder: (context) {
              inner = MediaQuery.of(context);
              return const SizedBox.expand(key: Key('page'));
            },
          ),
        ),
      ),
    );
    // The page itself still starts at the top, so its background does too;
    // only what it lays out against the top inset moves down.
    expect(tester.getRect(find.byKey(const Key('page'))).top, 0);
    expect(inner.padding.top, MixtapeMetrics.minTopInset);
    expect(inner.viewPadding.top, MixtapeMetrics.minTopInset);
  });

  testWidgets('a status bar taller than the floor is kept as it is', (
    tester,
  ) async {
    _sizeView(tester, const Size(402, 874));
    late MediaQueryData inner;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(402, 874),
          padding: EdgeInsets.only(top: 62, bottom: 34),
          viewPadding: EdgeInsets.only(top: 62, bottom: 34),
        ),
        child: PageInsets(
          child: Builder(
            builder: (context) {
              inner = MediaQuery.of(context);
              return const SizedBox.expand(key: Key('page'));
            },
          ),
        ),
      ),
    );
    expect(inner.padding.top, 62);
    expect(
      tester.getRect(find.byKey(const Key('page'))),
      const Rect.fromLTWH(0, 0, 402, 874),
    );
  });

  testWidgets('a sheet keeps its own top', (tester) async {
    _sizeView(tester, _duoOpenLandscape.size);
    late MediaQueryData inner;
    await tester.pumpWidget(
      MediaQuery(
        data: _duoOpenLandscape,
        child: PageInsets(
          top: false,
          child: Builder(
            builder: (context) {
              inner = MediaQuery.of(context);
              return const SizedBox.expand(key: Key('sheet'));
            },
          ),
        ),
      ),
    );
    expect(inner.padding.top, 0);
    expect(tester.getRect(find.byKey(const Key('sheet'))).right, 951 - 84);
  });

  testWidgets('nested pages inset only once', (tester) async {
    _sizeView(tester, _duoOpenLandscape.size);
    late MediaQueryData inner;
    await tester.pumpWidget(
      MediaQuery(
        data: _duoOpenLandscape,
        child: PageInsets(
          child: PageInsets(
            child: Builder(
              builder: (context) {
                inner = MediaQuery.of(context);
                return const SizedBox.expand(key: Key('page'));
              },
            ),
          ),
        ),
      ),
    );
    expect(tester.getRect(find.byKey(const Key('page'))).right, 951 - 84);
    expect(inner.padding.top, MixtapeMetrics.minTopInset);
  });

  testWidgets('every pushed page is inset by the theme', (tester) async {
    _sizeView(tester, _duoOpenLandscape.size);
    tester.view.padding = const FakeViewPadding(right: 84, bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(right: 84, bottom: 34);

    final navigator = GlobalKey<NavigatorState>();
    late double homeTop;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: MixtapeTheme.light(),
        home: Builder(
          builder: (context) {
            homeTop = MediaQuery.paddingOf(context).top;
            return const SizedBox.expand(key: Key('home'));
          },
        ),
      ),
    );
    expect(tester.getRect(find.byKey(const Key('home'))).right, 951 - 84);
    expect(homeTop, MixtapeMetrics.minTopInset);

    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const SizedBox.expand(key: Key('pushed')),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(const Key('pushed'))).right, 951 - 84);
  });
}
