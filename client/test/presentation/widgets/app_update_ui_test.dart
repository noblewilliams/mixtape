// The update note (approval docs/mockups/approved/2026-11-20-ota-update-states.md,
// revised 2026-11-21 by board 2026-11-21-ota-restart-orb-r3.html): "Update" with
// "(restart required)" under it and a flat green dot once a patch is downloaded;
// the start that boots the patch plays the bars, then the tick with "Updated".
// The tap (approval docs/mockups/approved/2026-11-24-ota-restart-countdown.md)
// opens a glass capsule, "Restarting in 5 | Cancel  Now", over a shortening
// prism stripe, and closes the app when it runs out.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/updates/app_updater.dart';
import 'package:mixtape/presentation/providers/app_update_provider.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/large_title_scaffold.dart';
import 'package:mixtape/presentation/widgets/update_status_note.dart';

import 'package:mixtape/presentation/widgets/foundation/haptics.dart';

import '../../helpers/haptic_recorder.dart';
import '../providers/app_update_provider_test.dart'
    show FakeAppUpdater, FakeReopenNotice;

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required FakeAppUpdater updater,
  InMemoryPendingPatchStore? store,
  Size size = const Size(390, 844),
  double textScale = 1,
  bool musicPlaying = false,
  bool voiceOver = false,
}) async {
  tester.view.physicalSize = size * tester.view.devicePixelRatio;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      appUpdaterProvider.overrideWithValue(updater),
      pendingPatchStoreProvider.overrideWithValue(
        store ?? InMemoryPendingPatchStore(),
      ),
      updateReopenNoticeProvider.overrideWithValue(FakeReopenNotice()),
      updateMusicPlayingProvider.overrideWithValue(() => musicPlaying),
      updateQuietBlockedProvider.overrideWithValue(() => false),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: MixtapeTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            accessibleNavigation: voiceOver,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: LargeTitleScaffold(
            title: 'Home',
            titleNote: UpdateStatusNote.inTitle,
            titleNoteWidth: UpdateStatusNote.widestWidth,
            slivers: const [SliverToBoxAdapter(child: Text('body'))],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return container;
}

Future<void> _ready(WidgetTester tester, ProviderContainer container) async {
  await container.read(appUpdateProvider.notifier).check();
  await tester.pump();
}

/// Records the haptics the note asks the platform for.
List<String> _recordHaptics(WidgetTester tester) {
  final haptics = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add(call.arguments as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return haptics;
}

void main() {
  testWidgets('nothing shows while the app is current', (tester) async {
    await _pump(tester, updater: FakeAppUpdater());
    expect(find.text(UpdateStatusNote.availableLabel), findsNothing);
    expect(find.text(UpdateStatusNote.restartLabel), findsNothing);
    expect(find.byKey(UpdateStatusNote.noteKey), findsNothing);
  });

  testWidgets(
    'a downloaded patch shows Update beside the title, (restart required) '
    'under it, its dot and a named 44 pt target',
    (tester) async {
      final handle = tester.ensureSemantics();
      final container = await _pump(
        tester,
        updater: FakeAppUpdater(waiting: 7),
      );
      await _ready(tester, container);

      expect(find.text(UpdateStatusNote.availableLabel), findsOneWidget);
      expect(find.text(UpdateStatusNote.restartLabel), findsOneWidget);
      expect(find.byKey(UpdateStatusNote.dotKey), findsOneWidget);
      // The small line hangs under the word and is 7 pt italic.
      final word = tester.getRect(find.text(UpdateStatusNote.availableLabel));
      final small = tester.getRect(find.text(UpdateStatusNote.restartLabel));
      expect(small.top, greaterThanOrEqualTo(word.bottom - 1));
      final smallStyle = tester
          .widget<Text>(find.text(UpdateStatusNote.restartLabel))
          .style!;
      expect(smallStyle.fontSize, UpdateStatusNote.restartFontSize);
      expect(smallStyle.fontStyle, FontStyle.italic);
      final title = tester.getRect(find.text('Home'));
      final note = tester.getRect(find.byKey(UpdateStatusNote.noteKey));
      // Same line as the title, at the right margin.
      expect(note.left, greaterThan(title.right));
      expect(note.right, closeTo(390 - 20, 0.5));
      expect(note.height, greaterThanOrEqualTo(44));
      final label = tester.getRect(find.text(UpdateStatusNote.availableLabel));
      expect(label.center.dy, closeTo(title.center.dy, 2));
      expect(
        tester.getSemantics(find.byKey(UpdateStatusNote.noteKey)),
        matchesSemantics(
          label: UpdateStatusNote.availableSemantics,
          isButton: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    },
  );

  // The test font draws every glyph a full em wide, so the capsule (about
  // 250 pt in SF) needs a wide screen to fit beside the title here.
  testWidgets('the tap opens the countdown capsule on the title line, which '
      'counts down and closes the app', (tester) async {
    final updater = FakeAppUpdater(waiting: 7);
    final container = await _pump(
      tester,
      updater: updater,
      size: const Size(900, 900),
    );
    await _ready(tester, container);
    final handle = tester.ensureSemantics();
    final noteRect = tester.getRect(find.byKey(UpdateStatusNote.noteKey));

    await tester.tap(find.byKey(UpdateStatusNote.noteKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(container.read(appUpdateProvider).phase, AppUpdatePhase.countdown);
    expect(find.text(UpdateStatusNote.countdownLabel(5)), findsOneWidget);
    expect(find.text(UpdateStatusNote.cancelLabel), findsOneWidget);
    expect(find.text(UpdateStatusNote.nowLabel), findsOneWidget);
    expect(find.byKey(UpdateStatusNote.musicKey), findsNothing);

    // Anchored where the note sat: right edges together, centred on the
    // title's line.
    final capsule = tester.getRect(find.byKey(UpdateStatusNote.capsuleKey));
    final title = tester.getRect(find.text('Home'));
    expect(capsule.right, closeTo(noteRect.right, 0.5));
    expect(capsule.center.dy, closeTo(title.center.dy, 2));
    // Each word taps like a 44 pt button.
    expect(
      tester.getSize(find.byKey(UpdateStatusNote.cancelKey)).height,
      greaterThanOrEqualTo(44),
    );
    expect(
      tester.getSemantics(find.byKey(UpdateStatusNote.capsuleKey)),
      matchesSemantics(
        label: UpdateStatusNote.countdownSemantics,
        isLiveRegion: true,
        children: [
          matchesSemantics(
            label: UpdateStatusNote.cancelLabel,
            isButton: true,
            isEnabled: true,
            hasEnabledState: true,
            hasTapAction: true,
          ),
          matchesSemantics(
            label: UpdateStatusNote.nowSemantics,
            isButton: true,
            isEnabled: true,
            hasEnabledState: true,
            hasTapAction: true,
          ),
        ],
      ),
    );
    handle.dispose();

    await tester.pump(updateCountdownStep);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(UpdateStatusNote.countdownLabel(4)), findsOneWidget);
    // 1.7 s in: the fifth second ends at 5 s, then "Restarting" holds.
    await tester.pump(const Duration(milliseconds: 3300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(container.read(appUpdateProvider).phase, AppUpdatePhase.closing);
    expect(find.text(UpdateStatusNote.closingLabel), findsOneWidget);
    expect(updater.closes, 0);
    await tester.pump(updateCloseDelay);
    expect(updater.closes, 1);
  });

  testWidgets('the prism stripe shortens from the right as the seconds go', (
    tester,
  ) async {
    final container = await _pump(tester, updater: FakeAppUpdater(waiting: 7));
    await _ready(tester, container);
    await tester.tap(find.byKey(UpdateStatusNote.noteKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final full = tester.getRect(find.byKey(UpdateStatusNote.stripeKey));
    await tester.pump(
      updateCountdownStep * 2 - const Duration(milliseconds: 400),
    );
    final later = tester.getRect(find.byKey(UpdateStatusNote.stripeKey));
    // The stripe's box stays put.
    expect(later.left, full.left);
    // What is drawn is cut from the right: 3 s left of 5.
    final fill = tester.getRect(find.byKey(UpdateStatusNote.stripeFillKey));
    expect(fill.left, closeTo(later.left, 0.5));
    expect(fill.width / later.width, closeTo(0.6, 0.05));
    expect(full.width, later.width);
    container.read(appUpdateProvider.notifier).cancelCountdown();
    // The note's dot breathes forever, so settle by time, not by quiet.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('Cancel puts the note back', (tester) async {
    final updater = FakeAppUpdater(waiting: 7);
    final container = await _pump(tester, updater: updater);
    await _ready(tester, container);
    await tester.tap(find.byKey(UpdateStatusNote.noteKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(UpdateStatusNote.cancelKey));
    await tester.pump();
    expect(container.read(appUpdateProvider).phase, AppUpdatePhase.ready);
    expect(find.byKey(UpdateStatusNote.capsuleKey), findsNothing);
    expect(find.text(UpdateStatusNote.availableLabel), findsOneWidget);
    await tester.pump(updateCountdownStep * 8);
    expect(updater.closes, 0);
  });

  testWidgets('Now closes straight away', (tester) async {
    final updater = FakeAppUpdater(waiting: 7);
    final container = await _pump(tester, updater: updater);
    await _ready(tester, container);
    await tester.tap(find.byKey(UpdateStatusNote.noteKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(UpdateStatusNote.nowKey));
    await tester.pump();
    expect(container.read(appUpdateProvider).phase, AppUpdatePhase.closing);
    await tester.pump(updateCloseDelay);
    expect(updater.closes, 1);
  });

  testWidgets('music playing adds "Music will stop" under the capsule', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      updater: FakeAppUpdater(waiting: 7),
      musicPlaying: true,
    );
    await _ready(tester, container);
    await tester.tap(find.byKey(UpdateStatusNote.noteKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text(UpdateStatusNote.musicLabel), findsOneWidget);
    final tag = tester.getRect(find.byKey(UpdateStatusNote.musicKey));
    final cancel = tester.getRect(find.byKey(UpdateStatusNote.cancelKey));
    expect(tag.top, greaterThanOrEqualTo(cancel.bottom - 0.5));
    container.read(appUpdateProvider.notifier).cancelCountdown();
    // The note's dot breathes forever, so settle by time, not by quiet.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('with VoiceOver the capsule waits for Now or Cancel', (
    tester,
  ) async {
    final updater = FakeAppUpdater(waiting: 7);
    final container = await _pump(tester, updater: updater, voiceOver: true);
    await _ready(tester, container);
    await tester.tap(find.byKey(UpdateStatusNote.noteKey));
    await tester.pump();
    await tester.pump(updateCountdownStep * 10);
    expect(container.read(appUpdateProvider).holding, isTrue);
    expect(find.text(UpdateStatusNote.countdownLabel(5)), findsOneWidget);
    expect(updater.closes, 0);
    final handle = tester.ensureSemantics();
    expect(
      tester.getSemantics(find.byKey(UpdateStatusNote.capsuleKey)).label,
      UpdateStatusNote.holdingSemantics,
    );
    handle.dispose();
    container.read(appUpdateProvider.notifier).cancelCountdown();
    // The note's dot breathes forever, so settle by time, not by quiet.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('when the title leaves too little room the capsule sits just '
      'under the note, right-aligned', (tester) async {
    final container = await _pump(
      tester,
      updater: FakeAppUpdater(waiting: 7),
      size: const Size(320, 640),
    );
    await _ready(tester, container);
    final note = tester.getRect(find.byKey(UpdateStatusNote.noteKey));
    await tester.tap(find.byKey(UpdateStatusNote.noteKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final capsule = tester.getRect(find.byKey(UpdateStatusNote.capsuleKey));
    final title = tester.getRect(find.text('Home'));
    expect(capsule.top, greaterThanOrEqualTo(title.bottom - 0.5));
    expect(capsule.right, closeTo(note.right, 0.5));
    expect(capsule.left, greaterThanOrEqualTo(20 - 0.5));
    expect(tester.takeException(), isNull);
    container.read(appUpdateProvider.notifier).cancelCountdown();
    // The note's dot breathes forever, so settle by time, not by quiet.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the start after an update plays the bars, the tick with '
      'Updated, then goes', (tester) async {
    final store = InMemoryPendingPatchStore()..value = 4;
    final container = await _pump(
      tester,
      updater: FakeAppUpdater(running: 4),
      store: store,
    );
    await tester.pump(UpdateStatusNote.swapFor);
    expect(find.byKey(UpdateStatusNote.barsKey), findsOneWidget);
    expect(find.text(UpdateStatusNote.updatedLabel), findsNothing);

    await tester.pump(updateAppliedFor);
    await tester.pump(UpdateStatusNote.swapFor);
    expect(find.text(UpdateStatusNote.updatedLabel), findsOneWidget);
    expect(find.byKey(UpdateStatusNote.checkKey), findsOneWidget);

    await tester.pump(updateUpdatedFor);
    expect(container.read(appUpdateProvider).phase, AppUpdatePhase.current);
    // Still drawn while it fades.
    await tester.pump();
    expect(find.text(UpdateStatusNote.updatedLabel), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text(UpdateStatusNote.updatedLabel), findsNothing);
    expect(find.byKey(UpdateStatusNote.noteKey), findsNothing);
  });

  // The test font draws every glyph a full em wide, so "beside" at 200% is
  // checked on a wider screen; on a phone's real font it fits at 390 pt.
  testWidgets('200% text keeps the note on the title line when both fit', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      updater: FakeAppUpdater(waiting: 7),
      size: const Size(700, 900),
      textScale: 2,
    );
    await _ready(tester, container);
    final title = tester.getRect(find.text('Home'));
    final note = tester.getRect(find.byKey(UpdateStatusNote.noteKey));
    expect(note.left, greaterThan(title.right));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    '200% text at 320 pt drops the note under the title, right-aligned',
    (tester) async {
      final container = await _pump(
        tester,
        updater: FakeAppUpdater(waiting: 7),
        size: const Size(320, 640),
        textScale: 2,
      );
      await _ready(tester, container);
      final title = tester.getRect(find.text('Home'));
      final note = tester.getRect(find.byKey(UpdateStatusNote.noteKey));
      expect(note.top, greaterThanOrEqualTo(title.bottom - 0.5));
      expect(note.right, closeTo(320 - 20, 0.5));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion holds the bars still', (tester) async {
    final updater = FakeAppUpdater(waiting: 7);
    final container = await _pump(tester, updater: updater);
    await _ready(tester, container);
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pump();
    await tester.tap(find.byKey(UpdateStatusNote.noteKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // Nothing keeps scheduling frames while the bars and stripe hold still.
    expect(tester.binding.hasScheduledFrame, isFalse);
    // The stripe steps down once a second instead.
    await tester.pump(updateCountdownStep);
    await tester.pump();
    final stripe = tester.getRect(find.byKey(UpdateStatusNote.stripeKey));
    final fill = tester.getRect(find.byKey(UpdateStatusNote.stripeFillKey));
    expect(fill.width / stripe.width, closeTo(0.8, 0.001));
    container.read(appUpdateProvider.notifier).cancelCountdown();
    await tester.pump();
  });

  testWidgets('the tap gives one soft click as the capsule opens, and none '
      'per second', (tester) async {
    final updater = FakeAppUpdater(waiting: 7);
    final container = await _pump(tester, updater: updater);
    await _ready(tester, container);
    final haptics = _recordHaptics(tester);
    final kinds = recordHaptics(tester);
    await tester.tap(find.byKey(UpdateStatusNote.noteKey));
    await tester.pump();
    await tester.pump(updateCountdownStep * 3);
    expect(haptics, ['HapticFeedbackType.selectionClick']);
    expect(kinds, isEmpty);
    // Cancel plays the app's dismiss feel.
    await tester.tap(find.byKey(UpdateStatusNote.cancelKey));
    await tester.pump();
    expect(kinds, [HapticKind.dismiss]);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('Now plays the call-to-action feel', (tester) async {
    final updater = FakeAppUpdater(waiting: 7);
    final container = await _pump(tester, updater: updater);
    await _ready(tester, container);
    final haptics = _recordHaptics(tester);
    final kinds = recordHaptics(tester);
    await tester.tap(find.byKey(UpdateStatusNote.noteKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(UpdateStatusNote.nowKey));
    await tester.pump();
    expect(haptics, ['HapticFeedbackType.selectionClick']);
    expect(kinds, [HapticKind.primary]);
    await tester.pump(updateCloseDelay);
  });

  testWidgets('the check finishing gives one soft click on the next start', (
    tester,
  ) async {
    final store = InMemoryPendingPatchStore()..value = 4;
    final haptics = _recordHaptics(tester);
    await _pump(tester, updater: FakeAppUpdater(running: 4), store: store);
    await tester.pump(updateAppliedFor);
    expect(haptics, isEmpty);
    // The tick starts a frame after the phase turns, then draws in full.
    await tester.pump();
    await tester.pump(UpdateStatusNote.tickFor * 2);
    expect(haptics, ['HapticFeedbackType.selectionClick']);
    await tester.pumpAndSettle();
  });
}
