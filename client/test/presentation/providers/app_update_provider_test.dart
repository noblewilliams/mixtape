// Over-the-air updates (decision 2026-11-20, board
// docs/mockups/approved/2026-11-20-ota-update-states.md): a patch downloads
// quietly and is offered as "Update available"; the tap closes the app; the
// start that boots the patch the app recorded plays Updating, then Updated.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/updates/app_updater.dart';
import 'package:mixtape/presentation/providers/app_update_provider.dart';

class FakeAppUpdater implements AppUpdater {
  FakeAppUpdater({this.isAvailable = true, this.running, this.waiting});

  @override
  bool isAvailable;
  int? running;
  int? waiting;
  int downloads = 0;
  int closes = 0;

  @override
  Future<int?> currentPatch() async => running;
  @override
  Future<int?> downloadNewPatch() async {
    downloads++;
    return waiting;
  }

  @override
  Future<void> close() async => closes++;
}

ProviderContainer _make(
  FakeAppUpdater updater,
  InMemoryPendingPatchStore store,
) => ProviderContainer(
  overrides: [
    appUpdaterProvider.overrideWithValue(updater),
    pendingPatchStoreProvider.overrideWithValue(store),
  ],
);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('no updater in the build: current, and never downloads', () async {
    final updater = FakeAppUpdater(isAvailable: false, waiting: 3);
    final container = _make(updater, InMemoryPendingPatchStore());
    addTearDown(container.dispose);
    expect(container.read(appUpdateProvider).phase, AppUpdatePhase.current);
    await container.read(appUpdateProvider.notifier).check();
    expect(updater.downloads, 0);
  });

  test(
    'an ordinary launch is launching until the read, then current',
    () async {
      final container = _make(FakeAppUpdater(), InMemoryPendingPatchStore());
      addTearDown(container.dispose);
      expect(container.read(appUpdateProvider).phase, AppUpdatePhase.launching);
      await _settle();
      expect(container.read(appUpdateProvider).phase, AppUpdatePhase.current);
    },
  );

  testWidgets(
    'the start that boots the recorded patch plays Updating, then Updated, '
    'then is current',
    (tester) async {
      final store = InMemoryPendingPatchStore()..value = 4;
      final container = _make(FakeAppUpdater(running: 4), store);
      addTearDown(container.dispose);
      container.read(appUpdateProvider);
      await tester.pump();
      await tester.pump();
      var state = container.read(appUpdateProvider);
      expect(state.phase, AppUpdatePhase.applied);
      expect(state.patch, 4);
      expect(store.value, isNull);

      await tester.pump(updateAppliedFor);
      expect(container.read(appUpdateProvider).phase, AppUpdatePhase.updated);
      await tester.pump(updateUpdatedFor);
      state = container.read(appUpdateProvider);
      expect(state.phase, AppUpdatePhase.current);
    },
  );

  test(
    'a recorded patch that did not boot (rolled back) shows nothing',
    () async {
      final store = InMemoryPendingPatchStore()..value = 4;
      final container = _make(FakeAppUpdater(running: 3), store);
      addTearDown(container.dispose);
      container.read(appUpdateProvider);
      await _settle();
      await _settle();
      expect(container.read(appUpdateProvider).phase, AppUpdatePhase.current);
      expect(store.value, isNull);
    },
  );

  test('a downloaded patch is recorded and ready', () async {
    final store = InMemoryPendingPatchStore();
    final updater = FakeAppUpdater(waiting: 5);
    final container = _make(updater, store);
    addTearDown(container.dispose);
    container.read(appUpdateProvider);
    await _settle();
    await container.read(appUpdateProvider.notifier).check();
    final state = container.read(appUpdateProvider);
    expect(state.phase, AppUpdatePhase.ready);
    expect(state.patch, 5);
    expect(store.value, 5);
    // Once one is waiting, no more checks until the next start.
    await container.read(appUpdateProvider.notifier).check();
    expect(updater.downloads, 1);
  });

  test('nothing new stays current', () async {
    final store = InMemoryPendingPatchStore();
    final container = _make(FakeAppUpdater(), store);
    addTearDown(container.dispose);
    container.read(appUpdateProvider);
    await _settle();
    await container.read(appUpdateProvider.notifier).check();
    expect(container.read(appUpdateProvider).phase, AppUpdatePhase.current);
    expect(store.value, isNull);
  });

  test('Restart shows closing, then closes the app', () async {
    final updater = FakeAppUpdater(waiting: 5);
    final container = _make(updater, InMemoryPendingPatchStore());
    addTearDown(container.dispose);
    container.read(appUpdateProvider);
    await _settle();
    await container.read(appUpdateProvider.notifier).check();
    final restart = container.read(appUpdateProvider.notifier).restart();
    expect(container.read(appUpdateProvider).phase, AppUpdatePhase.closing);
    expect(updater.closes, 0);
    await restart;
    expect(updater.closes, 1);
  });

  test('Restart does nothing unless an update is ready', () async {
    final updater = FakeAppUpdater();
    final container = _make(updater, InMemoryPendingPatchStore());
    addTearDown(container.dispose);
    container.read(appUpdateProvider);
    await _settle();
    await container.read(appUpdateProvider.notifier).restart();
    expect(updater.closes, 0);
    expect(container.read(appUpdateProvider).phase, AppUpdatePhase.current);
  });

  test('the monitor checks once the launch settles', () async {
    final updater = FakeAppUpdater(waiting: 2);
    final container = _make(updater, InMemoryPendingPatchStore());
    addTearDown(container.dispose);
    container.listen(appUpdateMonitorProvider, (_, _) {});
    await _settle();
    await _settle();
    expect(updater.downloads, 1);
    expect(container.read(appUpdateProvider).phase, AppUpdatePhase.ready);
  });
}
