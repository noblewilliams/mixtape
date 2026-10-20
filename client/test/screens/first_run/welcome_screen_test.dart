// Welcome and the prompt page (board frames A1, A2, B8).
import 'package:flutter/cupertino.dart' show CupertinoPageTransition;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/first_run_provider.dart';
import 'package:mixtape/presentation/screens/first_run/artists_screen.dart';
import 'package:mixtape/presentation/screens/first_run/choose_service_screen.dart';
import 'package:mixtape/presentation/screens/first_run/step_scaffold.dart';
import 'package:mixtape/presentation/screens/first_run/welcome_screen.dart';
import 'package:mixtape/presentation/screens/sign_in_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/cassette_tile.dart';

import 'first_run_harness.dart';

void main() {
  group('with reduced motion', () {
    reduceMotion();

    testWidgets('Welcome: wordmark, cassette, headline, composer, or, one pill '
        'and the sign-in foot link; no back and no counter', (tester) async {
      final h = FirstRunHarness();
      await h.pump(tester, const WelcomeScreen());

      expect(find.text('mixtape'), findsOneWidget);
      expect(find.byKey(WelcomeScreen.cassetteKey), findsOneWidget);
      expect(find.text('What do you want to hear?'), findsOneWidget);
      expect(find.byKey(const Key('prompt-field')), findsOneWidget);
      expect(find.text('OR'), findsOneWidget);
      expect(find.text('Add my music first'), findsOneWidget);
      expect(
        find.textContaining('Already have an account?', findRichText: true),
        findsOneWidget,
      );
      expect(find.byKey(TapeBackButton.defaultKey), findsNothing);
      expect(find.byKey(StepScaffold.counterKey), findsNothing);
      expect(find.byKey(StepScaffold.progressKey), findsNothing);
      // The mic is not part of this composer.
      expect(find.byKey(const Key('voice-input')), findsNothing);
    });

    testWidgets('the field opens on the first of the three spec examples', (
      tester,
    ) async {
      final h = FirstRunHarness();
      await h.pump(tester, const WelcomeScreen());

      final field = tester.widget<TextField>(
        find.byKey(const Key('prompt-field')),
      );
      expect(field.decoration!.hintText, 'something for a rainy commute');
      expect(WelcomeScreen.examples, [
        'something for a rainy commute',
        '90s R&B, no ballads',
        'warm up for a long run',
      ]);
    });

    testWidgets('send goes to Who do you love? with the prompt, and touches '
        'no server', (tester) async {
      final h = FirstRunHarness();
      await h.pump(tester, const WelcomeScreen());

      await tester.enterText(
        find.byKey(const Key('prompt-field')),
        'something for a rainy commute, no talking',
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();

      final artists = tester.widget<ArtistsScreen>(find.byType(ArtistsScreen));
      expect(artists.prompt, 'something for a rainy commute, no talking');
      expect(h.auth.anonymousSignIns, 0);
      expect(h.dj.prompts, isEmpty);
    });

    testWidgets('Add my music first opens Step 1', (tester) async {
      final h = FirstRunHarness();
      await h.pump(tester, const WelcomeScreen());

      await tester.tap(find.byKey(WelcomeScreen.addMusicKey));
      await tester.pumpAndSettle();

      expect(find.byType(ChooseServiceScreen), findsOneWidget);
      expect(find.text('STEP 1 OF 3'), findsOneWidget);
    });

    testWidgets('the foot link opens the sign-in page with its usual headline, '
        'and back returns', (tester) async {
      final h = FirstRunHarness();
      await h.pump(tester, const WelcomeScreen());

      await tester.tap(find.byKey(WelcomeScreen.signInKey));
      await tester.pumpAndSettle();

      expect(find.byType(SignInScreen), findsOneWidget);
      expect(
        tester.widget<SignInScreen>(find.byType(SignInScreen)).headline,
        SignInScreen.defaultHeadline,
      );
      await tester.tap(find.byKey(TapeBackButton.defaultKey));
      await tester.pumpAndSettle();
      expect(find.byType(SignInScreen), findsNothing);
      expect(find.byType(WelcomeScreen), findsOneWidget);
    });

    testWidgets('the sign-in foot link and Back are actionable by '
        'VoiceOver', (tester) async {
      final h = FirstRunHarness();
      final handle = tester.ensureSemantics();
      await h.pump(tester, const WelcomeScreen());

      final signIn = tester.getSemantics(
        find.bySemanticsLabel('Already have an account? Sign in.'),
      );
      expect(
        signIn.getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue,
        reason: 'a node with no tap action cannot be activated by VoiceOver',
      );
      expect(signIn.getSemanticsData().flagsCollection.isButton, isTrue);

      // Activating it through semantics opens the sign-in page, whose Back
      // is just as reachable.
      tester.semantics.tap(
        find.semantics.byLabel('Already have an account? Sign in.'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SignInScreen), findsOneWidget);
      final back = tester.getSemantics(find.bySemanticsLabel('Back'));
      expect(back.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      expect(back.getSemanticsData().flagsCollection.isButton, isTrue);
      tester.semantics.tap(find.semantics.byLabel('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(SignInScreen), findsNothing);
      handle.dispose();
    });

    testWidgets('the prompt page: no pill, a back button, the real count, and '
        'send goes straight to the mix', (tester) async {
      final h = FirstRunHarness(status: AuthStatus.session, anonymous: true);
      h.container.read(firstRunActiveProvider.notifier);
      await h.pump(tester, const WelcomeScreen.prompt(songsIn: 1284));

      expect(find.byKey(WelcomeScreen.addMusicKey), findsNothing);
      expect(find.text('OR'), findsNothing);
      expect(find.byKey(TapeBackButton.defaultKey), findsOneWidget);
      expect(find.text('1,284 songs in. Ask for anything.'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('prompt-field')), 'late');
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();

      expect(h.dj.prompts, ['late']);
      expect(find.byType(ArtistsScreen), findsNothing);
      expect(h.container.read(firstRunActiveProvider), isFalse);
      expect(
        h.container.read(pendingConversationProvider)?.sessionId,
        'session-new',
      );
    });

    testWidgets('a start that fails shows why and stays on the page', (
      tester,
    ) async {
      final h = FirstRunHarness(status: AuthStatus.session, anonymous: true);
      h.dj.failWith = Exception('boom');
      await h.pump(tester, const WelcomeScreen.prompt(songsIn: 3));

      await tester.enterText(find.byKey(const Key('prompt-field')), 'late');
      await tester.pump();
      await tester.tap(find.byKey(const Key('start-session')));
      await tester.pumpAndSettle();

      expect(find.byKey(WelcomeScreen.errorKey), findsOneWidget);
      expect(
        find.text('Something went wrong on our end. Try again.'),
        findsOneWidget,
      );
      expect(h.container.read(pendingConversationProvider), isNull);
    });

    testWidgets('reduced motion: the hubs stand still (a settle finishes) '
        'and pushes cross-fade', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final h = FirstRunHarness();
      await h.pump(tester, const WelcomeScreen());
      expect(tester.hasRunningAnimations, isFalse);

      await tester.tap(find.byKey(WelcomeScreen.addMusicKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.ancestor(
          of: find.byType(ChooseServiceScreen),
          matching: find.byType(CupertinoPageTransition),
        ),
        findsNothing,
      );
      expect(
        find.ancestor(
          of: find.byType(ChooseServiceScreen),
          matching: find.byType(FadeTransition),
        ),
        findsWidgets,
      );
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('200% text: the page scrolls and the foot link stays after '
        'the content', (tester) async {
      final h = FirstRunHarness();
      phone(tester);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await h.pump(tester, const WelcomeScreen());

      expect(tester.takeException(), isNull);
      // The page's own scroll view, not the field's.
      final scrollable = find
          .descendant(
            of: find.byType(SingleChildScrollView).first,
            matching: find.byType(Scrollable),
          )
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(
        position.maxScrollExtent,
        greaterThan(0),
        reason: 'at 200% the content is taller than the screen',
      );
      await tester.scrollUntilVisible(
        find.byKey(WelcomeScreen.signInKey),
        200,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      final pill = tester.getRect(find.byKey(WelcomeScreen.addMusicKey));
      final foot = tester.getRect(find.byKey(WelcomeScreen.signInKey));
      expect(foot.top, greaterThanOrEqualTo(pill.bottom));
      final viewport = tester.getRect(scrollable);
      expect(foot.top, greaterThanOrEqualTo(viewport.top));
      expect(foot.bottom, lessThanOrEqualTo(viewport.bottom));
    });
  });

  testWidgets('with motion allowed the cassette hubs turn', (tester) async {
    final h = FirstRunHarness();
    phone(tester);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: h.container,
        child: MaterialApp(
          theme: MixtapeTheme.light(),
          home: const WelcomeScreen(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester
          .widget<CassetteTile>(find.byKey(WelcomeScreen.cassetteKey))
          .spinning,
      isTrue,
    );
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
