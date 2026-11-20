// The update note (board docs/mockups/approved/2026-11-20-ota-update-states.md):
// a tiny line at the end of the Home and You title rows. "Update available"
// once a patch is downloaded; the tap shows "Updating" and closes the app;
// the start that boots the patch plays "Updating", then "Updated", then goes.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/updates/app_updater.dart';
import 'package:mixtape/presentation/providers/app_update_provider.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/large_title_scaffold.dart';
import 'package:mixtape/presentation/widgets/update_status_note.dart';

import '../providers/app_update_provider_test.dart' show FakeAppUpdater;

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required FakeAppUpdater updater,
  InMemoryPendingPatchStore? store,
  Size size = const Size(390, 844),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size * tester.view.devicePixelRatio;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      appUpdaterProvider.overrideWithValue(updater),
      pendingPatchStoreProvider.overrideWithValue(
        store ?? InMemoryPendingPatchStore(),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: MixtapeTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
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

void main() {
  testWidgets('nothing shows while the app is current', (tester) async {
    await _pump(tester, updater: FakeAppUpdater());
    expect(find.text(UpdateStatusNote.availableLabel), findsNothing);
    expect(find.text(UpdateStatusNote.updatingLabel), findsNothing);
    expect(find.byKey(UpdateStatusNote.noteKey), findsNothing);
  });

  testWidgets(
    'a downloaded patch shows Update available beside the title, with its '
    'dot and a named 44 pt target',
    (tester) async {
      final handle = tester.ensureSemantics();
      final container = await _pump(
        tester,
        updater: FakeAppUpdater(waiting: 7),
      );
      await _ready(tester, container);

      expect(find.text(UpdateStatusNote.availableLabel), findsOneWidget);
      expect(find.byKey(UpdateStatusNote.dotKey), findsOneWidget);
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

  testWidgets('the tap shows Updating with the bars, then closes the app', (
    tester,
  ) async {
    final updater = FakeAppUpdater(waiting: 7);
    final container = await _pump(tester, updater: updater);
    await _ready(tester, container);

    await tester.tap(find.byKey(UpdateStatusNote.noteKey));
    await tester.pump(UpdateStatusNote.swapFor);
    expect(container.read(appUpdateProvider).phase, AppUpdatePhase.closing);
    expect(find.text(UpdateStatusNote.updatingLabel), findsOneWidget);
    expect(find.byKey(UpdateStatusNote.barsKey), findsOneWidget);
    expect(updater.closes, 0);
    await tester.pump(updateCloseDelay);
    expect(updater.closes, 1);
  });

  testWidgets('the start after an update plays Updating, Updated, then goes', (
    tester,
  ) async {
    final store = InMemoryPendingPatchStore()..value = 4;
    final container = await _pump(
      tester,
      updater: FakeAppUpdater(running: 4),
      store: store,
    );
    await tester.pump(UpdateStatusNote.swapFor);
    expect(find.text(UpdateStatusNote.updatingLabel), findsOneWidget);
    expect(find.byKey(UpdateStatusNote.barsKey), findsOneWidget);

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
    // Nothing keeps scheduling frames while the bars hold still.
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pump(updateCloseDelay);
  });
}
