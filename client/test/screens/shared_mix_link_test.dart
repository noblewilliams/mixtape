// C2: a share link opens SharedMixScreen over whatever root is up: the shell
// (after first run) or the first-run flow (a fresh install). The presenter is
// faked here; it opens the screen on the root navigator once per arrival and
// the pending token is consumed.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/share/share_link.dart';
import 'package:mixtape/main.dart';
import 'package:mixtape/presentation/providers/incoming_link_provider.dart';
import 'package:mixtape/presentation/screens/first_run/artists_screen.dart';
import 'package:mixtape/presentation/screens/first_run/welcome_screen.dart';

import '../helpers/fake_incoming_links.dart';
import 'first_run/first_run_harness.dart';
import 'shell_screen_test.dart' show pumpShell, shellContainer;

const token = 'AbCdEfGhIjKlMnOpQrStUv';

Uri shareLink(String t) => Uri.parse(shareUrlFor(t));

NavigatorState rootNavigator(WidgetTester tester) =>
    tester.state<NavigatorState>(find.byType(Navigator).first);

void main() {
  group('shell', () {
    testWidgets('a cold-start link opens once on the root navigator', (
      tester,
    ) async {
      final source = FakeIncomingLinkSource(initial: shareLink(token));
      final presenter = RecordingSharedMixPresenter();
      final container = shellContainer(
        extra: [
          incomingLinkSourceProvider.overrideWithValue(source),
          sharedMixPresenterProvider.overrideWithValue(presenter.call),
        ],
      );
      await pumpShell(tester, container);

      expect(presenter.tokens, [token]);
      expect(presenter.rootNavigators.single, rootNavigator(tester));
      expect(container.read(pendingSharedMixProvider), isNull);

      // Nothing else arrives: no second push on later frames.
      await tester.pumpAndSettle();
      expect(presenter.tokens, [token]);
    });

    testWidgets('a link tapped while running opens, and the same link tapped '
        'again later opens again', (tester) async {
      final source = FakeIncomingLinkSource();
      final presenter = RecordingSharedMixPresenter();
      final container = shellContainer(
        extra: [
          incomingLinkSourceProvider.overrideWithValue(source),
          sharedMixPresenterProvider.overrideWithValue(presenter.call),
        ],
      );
      await pumpShell(tester, container);
      expect(presenter.tokens, isEmpty);

      source.tap(shareLink(token));
      await tester.pumpAndSettle();
      expect(presenter.tokens, [token]);
      expect(container.read(pendingSharedMixProvider), isNull);

      source.tap(shareLink(token));
      await tester.pumpAndSettle();
      expect(presenter.tokens, [token, token]);
    });
  });

  group('first run', () {
    reduceMotion();

    Future<ProviderContainer> pumpFirstRun(
      WidgetTester tester,
      FakeIncomingLinkSource source,
      RecordingSharedMixPresenter presenter,
    ) async {
      phone(tester);
      final h = FirstRunHarness();
      final container = ProviderContainer(
        overrides: [
          ...h.overrides,
          incomingLinkSourceProvider.overrideWithValue(source),
          sharedMixPresenterProvider.overrideWithValue(presenter.call),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MixtapeApp(),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('a cold-start link on a fresh install opens once', (
      tester,
    ) async {
      final source = FakeIncomingLinkSource(initial: shareLink(token));
      final presenter = RecordingSharedMixPresenter();
      final container = await pumpFirstRun(tester, source, presenter);

      expect(find.byType(WelcomeScreen), findsOneWidget);
      expect(presenter.tokens, [token]);
      expect(presenter.rootNavigators.single, rootNavigator(tester));
      expect(container.read(pendingSharedMixProvider), isNull);
    });

    testWidgets('a link tapped mid-flow opens once', (tester) async {
      final source = FakeIncomingLinkSource();
      final presenter = RecordingSharedMixPresenter();
      final container = await pumpFirstRun(tester, source, presenter);

      await tester.enterText(find.byKey(const Key('prompt-field')), 'rainy');
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();
      expect(find.byType(ArtistsScreen), findsOneWidget);

      source.tap(shareLink(token));
      await tester.pumpAndSettle();

      expect(presenter.tokens, [token]);
      expect(presenter.rootNavigators.single, rootNavigator(tester));
      expect(container.read(pendingSharedMixProvider), isNull);
    });
  });
}
