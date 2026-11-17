import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/empty_state.dart';

void main() {
  // The closed iPhone Duo in landscape (founder, 2026-11-17): 466 pt tall,
  // a title row and a button above the block, and the block's Try again
  // overflowed by 4 px instead of scrolling.
  testWidgets('on a short screen the block scrolls instead of overflowing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(594, 466);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(padding: const EdgeInsets.only(top: 24, bottom: 34)),
          child: child!,
        ),
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              const SliverToBoxAdapter(child: SizedBox(height: 200)),
              EmptyStateSliver(
                child: EmptyState(
                  title: 'Couldn’t load your music',
                  body:
                      'Mixtape isn’t responding right now. Try again in a '
                      'moment.',
                  action: SizedBox(
                    key: const Key('try-again'),
                    height: 44,
                    child: TextButton(
                      onPressed: () {},
                      child: const Text('Try again'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    // All of it can be reached: scrolled to the end, the action is on screen.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await tester.pumpAndSettle();
    final action = tester.getRect(find.byKey(const Key('try-again')));
    expect(action.bottom, lessThanOrEqualTo(466));
  });
}
