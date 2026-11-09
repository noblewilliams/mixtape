// Ask once, on app open (decision 2 of
// `docs/superpowers/specs/2026-11-09-one-platform-play-design.md`; the
// approval record `docs/mockups/approved/2026-11-09-one-platform-play.md`
// → Ask once): the "Where do you listen?" sheet, and the prompt that puts it
// over the shell only when nothing tells us the platform.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/presentation/providers/ai_consent_provider.dart';
import 'package:mixtape/presentation/providers/music_platform_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_sheet.dart';
import 'package:mixtape/presentation/widgets/foundation/service_marks.dart';
import 'package:mixtape/presentation/widgets/listen_on_prompt.dart';
import 'package:mixtape/presentation/widgets/spotify_handoff_sheets.dart';

OnboardingState _onboarding({String? service}) => OnboardingState(
  userId: 'u1',
  sources: const [],
  hasLibrary: true,
  chosenService: service,
  markedRequestedAt: null,
  interviewCompletedAt: null,
  importCompletedAt: null,
);

class _Onboarding extends OnboardingNotifier {
  _Onboarding(this.answer);
  final Future<OnboardingState> answer;

  @override
  Future<OnboardingState> build() => answer;
}

/// Whether the AI-consent sheet wants the screen, for the test to flip.
class _ConsentNeeded extends Notifier<bool> {
  _ConsentNeeded(this.initial);
  final bool initial;

  @override
  bool build() => initial;

  void set(bool value) => state = value;
}

late NotifierProvider<_ConsentNeeded, bool> _consentNeeded;
late NotifierProvider<_ConsentNeeded, bool> _consentSettled;

ProviderContainer _container({
  MusicPlatformStore? store,
  Future<OnboardingState>? onboarding,
  bool consentNeeded = false,
  bool consentSettled = true,
}) {
  _consentNeeded = NotifierProvider<_ConsentNeeded, bool>(
    () => _ConsentNeeded(consentNeeded),
  );
  _consentSettled = NotifierProvider<_ConsentNeeded, bool>(
    () => _ConsentNeeded(consentSettled),
  );
  final container = ProviderContainer(
    overrides: [
      aiConsentNeededProvider.overrideWith((ref) => ref.watch(_consentNeeded)),
      aiConsentSettledProvider.overrideWith(
        (ref) => ref.watch(_consentSettled),
      ),
      musicPlatformStoreProvider.overrideWithValue(
        store ?? InMemoryMusicPlatformStore(),
      ),
      onboardingProvider.overrideWith(
        () => _Onboarding(
          onboarding ?? Future.value(_onboarding(service: 'skipped')),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// The prompt over a stand-in shell, the way the shell wraps its tabs.
Future<void> _pumpPrompt(
  WidgetTester tester,
  ProviderContainer container, {
  Key key = const Key('shell'),
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        key: key,
        theme: brightness == Brightness.dark
            ? MixtapeTheme.dark()
            : MixtapeTheme.light(),
        home: ListenOnPrompt(
          child: const Scaffold(body: Center(child: Text('Home'))),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('the sheet', () {
    testWidgets(
      'Apple Music first, two equal pills with their marks, the new line',
      (tester) async {
        await _pumpPrompt(tester, _container());

        expect(find.text(WhereYouListenSheet.headline), findsOneWidget);
        expect(
          find.text(
            'Your mixes play or save there. You can change it any time in You.',
          ),
          findsOneWidget,
        );
        final apple = tester.getRect(find.byKey(WhereYouListenSheet.appleKey));
        final spotify = tester.getRect(
          find.byKey(WhereYouListenSheet.spotifyKey),
        );
        expect(apple.top, lessThan(spotify.top), reason: 'Apple Music first');
        expect(apple.size, spotify.size, reason: 'equal weight');
        expect(
          find.descendant(
            of: find.byKey(WhereYouListenSheet.appleKey),
            matching: find.byType(AppleMusicMark),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(WhereYouListenSheet.spotifyKey),
            matching: find.byType(SpotifyMark),
          ),
          findsOneWidget,
        );
        expect(find.byKey(MixtapeSheet.handleKey), findsNothing);
      },
    );

    testWidgets('neither the scrim nor a drag closes it', (tester) async {
      await _pumpPrompt(tester, _container());

      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(find.text(WhereYouListenSheet.headline), findsOneWidget);

      await tester.drag(
        find.text(WhereYouListenSheet.headline),
        const Offset(0, 500),
      );
      await tester.pumpAndSettle();
      expect(find.text(WhereYouListenSheet.headline), findsOneWidget);
    });

    testWidgets('dark mode draws the same sheet', (tester) async {
      await _pumpPrompt(tester, _container(), brightness: Brightness.dark);
      expect(find.text(WhereYouListenSheet.headline), findsOneWidget);
      expect(find.byKey(WhereYouListenSheet.appleKey), findsOneWidget);
    });

    testWidgets('VoiceOver reads the headline, then the two answers', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pumpPrompt(tester, _container());
      expect(find.bySemanticsLabel('Apple Music'), findsOneWidget);
      expect(find.bySemanticsLabel('Spotify'), findsOneWidget);
      handle.dispose();
    });
  });

  group('the prompt', () {
    testWidgets('an answer is the platform, and the sheet goes', (
      tester,
    ) async {
      final store = InMemoryMusicPlatformStore();
      final container = _container(store: store);
      await _pumpPrompt(tester, container);

      await tester.tap(find.byKey(WhereYouListenSheet.spotifyKey));
      await tester.pumpAndSettle();
      expect(find.text(WhereYouListenSheet.headline), findsNothing);
      expect(container.read(musicPlatformProvider), MusicPlatform.spotify);
      expect(await store.read(), MusicPlatform.spotify);
    });

    testWidgets('answering Apple Music stores Apple Music', (tester) async {
      final store = InMemoryMusicPlatformStore();
      await _pumpPrompt(tester, _container(store: store));
      await tester.tap(find.byKey(WhereYouListenSheet.appleKey));
      await tester.pumpAndSettle();
      expect(await store.read(), MusicPlatform.apple);
    });

    testWidgets('a stored platform never asks', (tester) async {
      await _pumpPrompt(
        tester,
        _container(store: InMemoryMusicPlatformStore(MusicPlatform.apple)),
      );
      expect(find.text(WhereYouListenSheet.headline), findsNothing);
    });

    for (final service in ['apple', 'spotify']) {
      testWidgets('a service chosen at sign-up ($service) never asks', (
        tester,
      ) async {
        await _pumpPrompt(
          tester,
          _container(onboarding: Future.value(_onboarding(service: service))),
        );
        expect(find.text(WhereYouListenSheet.headline), findsNothing);
      });
    }

    testWidgets('waits for onboarding, and a late service never asks', (
      tester,
    ) async {
      final onboarding = Completer<OnboardingState>();
      await _pumpPrompt(tester, _container(onboarding: onboarding.future));
      expect(find.text(WhereYouListenSheet.headline), findsNothing);

      onboarding.complete(_onboarding(service: 'spotify'));
      await tester.pumpAndSettle();
      expect(find.text(WhereYouListenSheet.headline), findsNothing);
    });

    testWidgets('waits for onboarding, then asks when it knows nothing', (
      tester,
    ) async {
      final onboarding = Completer<OnboardingState>();
      await _pumpPrompt(tester, _container(onboarding: onboarding.future));
      expect(find.text(WhereYouListenSheet.headline), findsNothing);

      onboarding.complete(_onboarding(service: 'skipped'));
      await tester.pumpAndSettle();
      expect(find.text(WhereYouListenSheet.headline), findsOneWidget);
    });

    testWidgets('an onboarding failure does not ask', (tester) async {
      await _pumpPrompt(
        tester,
        _container(
          onboarding: Future<OnboardingState>.error(Exception('offline'))
            ..ignore(),
        ),
      );
      expect(find.text(WhereYouListenSheet.headline), findsNothing);
    });

    testWidgets('waits while the AI-consent sheet has the screen', (
      tester,
    ) async {
      final container = _container(consentNeeded: true);
      await _pumpPrompt(tester, container);
      expect(find.text(WhereYouListenSheet.headline), findsNothing);

      container.read(_consentNeeded.notifier).set(false);
      await tester.pumpAndSettle();
      expect(find.text(WhereYouListenSheet.headline), findsOneWidget);
    });

    testWidgets('waits until the AI-consent need is known, not merely false', (
      tester,
    ) async {
      final container = _container(consentSettled: false);
      await _pumpPrompt(tester, container);
      expect(find.text(WhereYouListenSheet.headline), findsNothing);

      container.read(_consentSettled.notifier).set(true);
      await tester.pumpAndSettle();
      expect(find.text(WhereYouListenSheet.headline), findsOneWidget);
    });

    testWidgets('a sheet closed without an answer is not counted as asked', (
      tester,
    ) async {
      await _pumpPrompt(tester, _container());
      expect(find.text(WhereYouListenSheet.headline), findsOneWidget);

      // Something outside the sheet pops it (Navigator.pop ignores PopScope).
      Navigator.of(
        tester.element(find.text(WhereYouListenSheet.headline)),
      ).pop();
      await tester.pumpAndSettle();
      expect(
        find.text(WhereYouListenSheet.headline),
        findsOneWidget,
        reason: 'asked again: nothing was answered',
      );
    });

    testWidgets('the sheet goes on the root navigator, over nested ones', (
      tester,
    ) async {
      final container = _container();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: MixtapeTheme.light(),
            home: ListenOnPrompt(
              child: Navigator(
                key: const Key('tab-navigator'),
                onGenerateRoute: (_) => MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('Home')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final sheetNavigator = Navigator.of(
        tester.element(find.text(WhereYouListenSheet.headline)),
      );
      expect(sheetNavigator.widget.key, isNot(const Key('tab-navigator')));
      expect(
        sheetNavigator,
        Navigator.of(
          tester.element(find.text(WhereYouListenSheet.headline)),
          rootNavigator: true,
        ),
      );
    });

    testWidgets('tells the host while the sheet is up', (tester) async {
      final showing = <bool>[];
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: _container(),
          child: MaterialApp(
            theme: MixtapeTheme.light(),
            home: ListenOnPrompt(
              onShowingChanged: showing.add,
              child: const Scaffold(body: Text('Home')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(showing, [true]);
      await tester.tap(find.byKey(WhereYouListenSheet.appleKey));
      await tester.pumpAndSettle();
      expect(showing, [true, false]);
    });

    testWidgets('once per launch: a remounted shell does not ask again', (
      tester,
    ) async {
      final container = _container();
      await _pumpPrompt(tester, container);
      expect(find.text(WhereYouListenSheet.headline), findsOneWidget);

      // The shell is replaced (an anonymous session linking, say) with the
      // sheet still unanswered.
      await _pumpPrompt(tester, container, key: const Key('shell-again'));
      expect(find.text(WhereYouListenSheet.headline), findsNothing);
    });
  });
}
