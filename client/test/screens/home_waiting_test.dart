import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/onboarding/service_preference_store.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/presentation/screens/home_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/screens/import_sheet.dart';
import 'package:mixtape/presentation/screens/interview_screen.dart';
import 'package:mixtape/presentation/screens/spotify_request_screen.dart';
import 'package:mixtape/presentation/widgets/foundation/flush_row.dart';
import 'package:mixtape/presentation/widgets/foundation/label_chip.dart';
import 'package:mixtape/presentation/widgets/foundation/status_word.dart';

import '../helpers/fake_import_service.dart';
import '../helpers/fake_listening_api.dart';
import '../helpers/onboarding_harness.dart';

/// Home under the native theme, on a surface tall enough that the whole
/// waiting block clears the bottom panel. The width is the test default, so
/// the sheets these tests open keep the room they were written against.
Future<void> pumpHome(
  WidgetTester tester,
  ProviderContainer container, {
  Brightness brightness = Brightness.light,
  Size size = const Size(800, 1000),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: brightness == Brightness.dark
            ? MixtapeTheme.dark()
            : MixtapeTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const HomeScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// House rule on the native controls: every one carries a Key and a 44 pt
/// target. The waiting block's controls are the flush rows that open the
/// existing screens and the chip that opens the import flow.
void expectNativeControls(WidgetTester tester, Finder root) {
  final controls = find.descendant(
    of: root,
    matching: find.byWidgetPredicate((w) => w is FlushRow || w is LabelChip),
  );
  expect(controls, findsWidgets);
  for (final element in controls.evaluate()) {
    expect(
      element.widget.key,
      isNotNull,
      reason: '${element.widget.runtimeType} without a Key',
    );
    expect(
      tester.getSize(find.byWidget(element.widget)).height,
      greaterThanOrEqualTo(44),
      reason: '${element.widget.key} under 44 pt',
    );
  }
}

void main() {
  testWidgets('an Apple listener sees no waiting rows', (tester) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(chosenService: 'apple'),
    );
    await pumpHome(tester, onboardingContainer(listening: listening));

    expect(find.byKey(const Key('waiting-card')), findsNothing);
    expect(find.byKey(const Key('prompt-field')), findsOneWidget);
  });

  testWidgets(
    'a Spotify choice the server never heard (dropped post) still shows the waiting '
    'rows on the next launch, through the flag kept on the device',
    (tester) async {
      final prefs = InMemoryServicePreferenceStore();
      await prefs.write('user-1', 'spotify');
      final listening = FakeListeningApi(
        onboarding: onboardingState(userId: 'user-1'),
      );
      await pumpHome(
        tester,
        onboardingContainer(listening: listening, prefs: prefs),
      );

      expect(find.byKey(const Key('waiting-card')), findsOneWidget);
      expect(find.text('Ready to import'), findsOneWidget);
    },
  );

  testWidgets('a Spotify listener with both packages in sees no waiting rows', (
    tester,
  ) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(
        chosenService: 'spotify',
        markedRequestedAt: DateTime(2026, 8, 1),
        interviewCompletedAt: DateTime(2026, 8, 2),
        importCompletedAt: DateTime(2026, 8, 20),
        sources: [
          musicSource(
            packages: ['spotify_account', 'spotify_extended'],
            lastImportedAt: DateTime(2026, 8, 20),
          ),
        ],
      ),
    );
    await pumpHome(tester, onboardingContainer(listening: listening));

    expect(find.byKey(const Key('waiting-card')), findsNothing);
  });

  testWidgets(
    'one package in: the row keeps the elapsed wait and carries the nudge for the '
    'other package, without the "Not personal yet" note',
    (tester) async {
      final listening = FakeListeningApi(
        onboarding: onboardingState(
          chosenService: 'spotify',
          markedRequestedAt: DateTime(2026, 8, 1),
          importCompletedAt: DateTime(2026, 8, 20),
          sources: [
            musicSource(
              packages: ['spotify_extended'],
              lastImportedAt: DateTime(2026, 8, 20),
            ),
          ],
        ),
      );
      await pumpHome(tester, onboardingContainer(listening: listening));

      expect(find.byKey(const Key('waiting-card')), findsOneWidget);
      expect(find.byKey(const Key('waiting-requested')), findsOneWidget);
      expect(
        find.textContaining('Still waiting for the account data'),
        findsOneWidget,
      );
      expect(find.textContaining('waiting on Spotify'), findsNothing);
      expect(find.textContaining('Not personal yet'), findsNothing);
      expectNativeControls(tester, find.byKey(const Key('waiting-card')));

      listening.onboarding = onboardingState(
        chosenService: 'spotify',
        sources: [
          musicSource(
            packages: ['spotify_account'],
            lastImportedAt: DateTime(2026, 8, 20),
          ),
        ],
      );

      // Home refreshes onboarding on the way back from a pushed screen; the
      // interview the rows offer is a path it still owns.
      await tester.tap(find.byKey(const Key('open-interview')));
      await tester.pumpAndSettle();
      expect(find.byType(InterviewScreen), findsOneWidget);
      Navigator.of(tester.element(find.byType(InterviewScreen))).pop();
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Still waiting for the extended history'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Still waiting for the account data'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'the status word reads Ready to import, then the elapsed wait, and is a warning '
    'either way',
    (tester) async {
      final listening = FakeListeningApi(
        onboarding: onboardingState(chosenService: 'spotify'),
      );
      await pumpHome(tester, onboardingContainer(listening: listening));
      expect(find.byKey(const Key('waiting-not-requested')), findsOneWidget);
      expect(find.text('Ready to import'), findsOneWidget);
      expect(find.textContaining('waiting on Spotify'), findsOneWidget);
      expect(
        tester
            .widget<StatusWord>(find.byKey(const Key('waiting-not-requested')))
            .kind,
        StatusKind.warn,
      );

      listening.onboarding = onboardingState(
        chosenService: 'spotify',
        markedRequestedAt: DateTime.now().subtract(const Duration(days: 1)),
      );
      await tester.tap(find.byKey(const Key('open-request')));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(SpotifyRequestScreen))).pop();
      await tester.pumpAndSettle();
      expect(find.text('Requested 1 day ago'), findsOneWidget);
      expect(find.text('Ready to import'), findsNothing);
    },
  );

  testWidgets('Choose files opens the import sheet and picks', (tester) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(chosenService: 'spotify'),
    );
    final picker = FakeArchivePicker(extendedArchive);
    await pumpHome(
      tester,
      onboardingContainer(listening: listening, picker: picker),
    );

    await tester.tap(find.byKey(const Key('waiting-choose-zip')));
    await tester.pumpAndSettle();

    expect(find.byType(ImportSheet), findsOneWidget);
    expect(picker.picks, 1);
    expect(find.text('Upload'), findsOneWidget);
  });

  testWidgets(
    'Choose files while an upload is in flight shows where it got to, in a sheet that '
    'cannot be swiped away, and cancels nothing',
    (tester) async {
      final listening = FakeListeningApi(
        onboarding: onboardingState(chosenService: 'spotify'),
      );
      final picker = FakeArchivePicker(extendedArchive);
      final service = FakeImportService();
      await pumpHome(
        tester,
        onboardingContainer(
          listening: listening,
          picker: picker,
          importService: service,
        ),
      );
      await tester.tap(find.byKey(const Key('waiting-choose-zip')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('import-upload')));
      await tester.pump();
      expect(find.byKey(const Key('import-progress')), findsOneWidget);
      Navigator.of(tester.element(find.byType(ImportSheet))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(ImportSheet), findsNothing);
      // reset() before the first pick counted one cancel; re-entry adds none.
      final cancelsBefore = service.cancels;

      await tester.tap(find.byKey(const Key('waiting-choose-zip')));
      await tester.pumpAndSettle();

      expect(service.cancels, cancelsBefore);
      expect(service.running, isTrue);
      expect(picker.picks, 1);
      expect(find.byKey(const Key('import-progress')), findsOneWidget);
      final route =
          ModalRoute.of(tester.element(find.byType(ImportSheet)))!
              as ModalBottomSheetRoute<void>;
      expect(route.isDismissible, isFalse);
      expect(route.enableDrag, isFalse);
    },
  );

  testWidgets(
    'the interview row is replaced by a done line with what it produced',
    (tester) async {
      final listening = FakeListeningApi(
        onboarding: onboardingState(
          chosenService: 'spotify',
          interviewCompletedAt: DateTime(2026, 8, 2),
          interview: const InterviewCounts(artists: 6, notes: 5),
        ),
      );
      await pumpHome(tester, onboardingContainer(listening: listening));

      expect(find.byKey(const Key('interview-done')), findsOneWidget);
      expect(find.text('Interview done · 5 notes, 6 artists'), findsOneWidget);
      expect(find.byKey(const Key('open-interview')), findsNothing);
    },
  );

  testWidgets(
    'not requested yet: the row says so and opens the request screen (pushed, '
    'without the gate\'s Done button)',
    (tester) async {
      final listening = FakeListeningApi(
        onboarding: onboardingState(chosenService: 'spotify'),
      );
      await pumpHome(tester, onboardingContainer(listening: listening));

      expect(find.byKey(const Key('waiting-card')), findsOneWidget);
      expect(find.text('Bring your Spotify music'), findsOneWidget);
      expect(find.text('Ready to import'), findsOneWidget);
      expect(
        find.text('Mixes before the import are labelled "Not personal yet".'),
        findsOneWidget,
      );
      expectNativeControls(tester, find.byKey(const Key('waiting-card')));

      await tester.tap(find.byKey(const Key('open-request')));
      await tester.pumpAndSettle();

      expect(find.byType(SpotifyRequestScreen), findsOneWidget);
      expect(find.byKey(const Key('request-done')), findsNothing);
      await tester.tap(find.byKey(const Key('go-deeper')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('mark-requested')), findsOneWidget);
    },
  );

  testWidgets('requested: the row shows the elapsed wait', (tester) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(
        chosenService: 'spotify',
        markedRequestedAt: DateTime.now().subtract(
          const Duration(days: 2, hours: 1),
        ),
      ),
    );
    await pumpHome(tester, onboardingContainer(listening: listening));

    expect(find.text('Requested 2 days ago'), findsOneWidget);
    expect(find.text('Ready to import'), findsNothing);
    expect(find.byKey(const Key('open-request')), findsOneWidget);
  });

  testWidgets('the interview row opens the interview until it is done', (
    tester,
  ) async {
    final listening = FakeListeningApi(
      onboarding: onboardingState(chosenService: 'spotify'),
    );
    await pumpHome(tester, onboardingContainer(listening: listening));

    expect(find.text('Tell the DJ about your taste'), findsOneWidget);
    expect(
      find.text('Five quick questions for the first mixes'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('interview-done')), findsNothing);

    await tester.tap(find.byKey(const Key('open-interview')));
    await tester.pumpAndSettle();
    expect(find.byType(InterviewScreen), findsOneWidget);

    listening.onboarding = onboardingState(
      chosenService: 'spotify',
      interviewCompletedAt: DateTime.now(),
    );
    Navigator.of(tester.element(find.byType(InterviewScreen))).pop();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('interview-done')), findsOneWidget);
    expect(find.text('Interview done'), findsOneWidget);
    expect(find.byKey(const Key('open-interview')), findsNothing);
  });

  for (final brightness in Brightness.values) {
    testWidgets('the rows draw at 320 and 200% text in ${brightness.name}', (
      tester,
    ) async {
      final listening = FakeListeningApi(
        onboarding: onboardingState(
          chosenService: 'spotify',
          markedRequestedAt: DateTime.now().subtract(const Duration(days: 6)),
        ),
      );
      await pumpHome(
        tester,
        onboardingContainer(listening: listening),
        brightness: brightness,
        size: const Size(320, 900),
        textScale: 2,
      );

      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('waiting-card')), findsOneWidget);
      expect(find.text('Requested 6 days ago'), findsOneWidget);
      final rows = tester.getRect(find.byKey(const Key('waiting-card')));
      expect(rows.left, greaterThanOrEqualTo(0));
      expect(rows.right, lessThanOrEqualTo(320));
    });
  }
}
