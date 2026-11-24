// Over-the-air updates (decision 2026-11-20, board
// docs/mockups/approved/2026-11-20-ota-update-states.md): a patch downloads
// quietly and is offered as "Update"; the start that boots the patch the app
// recorded plays Updating, then Updated. Since 2026-11-24 (approval
// docs/mockups/approved/2026-11-24-ota-restart-countdown.md) the tap starts a
// 5-second countdown the listener can cancel or skip, the close schedules a
// "tap to reopen" notice, and leaving the app applies the patch quietly.
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

class FakeReopenNotice implements UpdateReopenNotice {
  final List<Duration> scheduled = [];
  int cancels = 0;
  @override
  Future<void> schedule({required Duration after}) async =>
      scheduled.add(after);
  @override
  Future<void> cancel() async => cancels++;
}

ProviderContainer _make(
  FakeAppUpdater updater,
  InMemoryPendingPatchStore store, {
  UpdateReopenNotice? notice,
  bool Function()? blocked,
  DateTime Function()? clock,
}) => ProviderContainer(
  overrides: [
    appUpdaterProvider.overrideWithValue(updater),
    pendingPatchStoreProvider.overrideWithValue(store),
    updateReopenNoticeProvider.overrideWithValue(notice ?? FakeReopenNotice()),
    updateQuietBlockedProvider.overrideWithValue(blocked ?? () => false),
    if (clock != null) updateClockProvider.overrideWithValue(clock),
  ],
);

/// A container with a patch downloaded and waiting.
Future<ProviderContainer> _ready(
  WidgetTester tester,
  FakeAppUpdater updater, {
  FakeReopenNotice? notice,
  bool Function()? blocked,
  DateTime Function()? clock,
}) async {
  final container = _make(
    updater,
    InMemoryPendingPatchStore(),
    notice: notice,
    blocked: blocked,
    clock: clock,
  );
  container.read(appUpdateProvider);
  await tester.pump();
  await container.read(appUpdateProvider.notifier).check();
  return container;
}

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

  testWidgets('the tap counts down from 5, then closes with a reopen notice', (
    tester,
  ) async {
    final updater = FakeAppUpdater(waiting: 5);
    final notice = FakeReopenNotice();
    final container = await _ready(tester, updater, notice: notice);
    addTearDown(container.dispose);
    final notifier = container.read(appUpdateProvider.notifier);

    notifier.startCountdown();
    var state = container.read(appUpdateProvider);
    expect(state.phase, AppUpdatePhase.countdown);
    expect(state.secondsLeft, updateCountdownSeconds);
    expect(state.holding, isFalse);

    for (var left = 4; left >= 1; left--) {
      await tester.pump(updateCountdownStep);
      expect(container.read(appUpdateProvider).secondsLeft, left);
    }
    expect(updater.closes, 0);
    await tester.pump(updateCountdownStep);
    state = container.read(appUpdateProvider);
    expect(state.phase, AppUpdatePhase.closing);
    expect(notice.scheduled, [updateReopenAfter]);
    expect(updater.closes, 0);
    await tester.pump(updateCloseDelay);
    expect(updater.closes, 1);
  });

  testWidgets('Cancel stops the countdown and puts the note back', (
    tester,
  ) async {
    final updater = FakeAppUpdater(waiting: 5);
    final container = await _ready(tester, updater);
    addTearDown(container.dispose);
    final notifier = container.read(appUpdateProvider.notifier);
    notifier.startCountdown();
    await tester.pump(updateCountdownStep * 2);
    notifier.cancelCountdown();
    final state = container.read(appUpdateProvider);
    expect(state.phase, AppUpdatePhase.ready);
    expect(state.patch, 5);
    await tester.pump(updateCountdownStep * 10);
    expect(updater.closes, 0);
    // And it can be started again from the top.
    notifier.startCountdown();
    expect(container.read(appUpdateProvider).secondsLeft, 5);
    notifier.cancelCountdown();
  });

  testWidgets('Now skips the rest of the countdown', (tester) async {
    final updater = FakeAppUpdater(waiting: 5);
    final notice = FakeReopenNotice();
    final container = await _ready(tester, updater, notice: notice);
    addTearDown(container.dispose);
    final notifier = container.read(appUpdateProvider.notifier);
    notifier.startCountdown();
    await tester.pump(updateCountdownStep);
    notifier.restartNow();
    expect(container.read(appUpdateProvider).phase, AppUpdatePhase.closing);
    await tester.pump(updateCloseDelay);
    expect(updater.closes, 1);
    expect(notice.scheduled, hasLength(1));
    // The stopped countdown never fires a second close.
    await tester.pump(updateCountdownStep * 6);
    expect(updater.closes, 1);
  });

  testWidgets('with VoiceOver the countdown holds for a tap', (tester) async {
    final updater = FakeAppUpdater(waiting: 5);
    final container = await _ready(tester, updater);
    addTearDown(container.dispose);
    final notifier = container.read(appUpdateProvider.notifier);
    notifier.startCountdown(hold: true);
    final state = container.read(appUpdateProvider);
    expect(state.phase, AppUpdatePhase.countdown);
    expect(state.holding, isTrue);
    await tester.pump(updateCountdownStep * 10);
    expect(container.read(appUpdateProvider).secondsLeft, 5);
    expect(updater.closes, 0);
    notifier.restartNow();
    await tester.pump(updateCloseDelay);
    expect(updater.closes, 1);
  });

  testWidgets('a failing reopen notice still closes', (tester) async {
    final updater = FakeAppUpdater(waiting: 5);
    final container = _make(
      updater,
      InMemoryPendingPatchStore(),
      notice: _ThrowingNotice(),
    );
    addTearDown(container.dispose);
    container.read(appUpdateProvider);
    await tester.pump();
    final notifier = container.read(appUpdateProvider.notifier);
    await notifier.check();
    notifier.startCountdown();
    notifier.restartNow();
    await tester.pump(updateCloseDelay);
    expect(updater.closes, 1);
  });

  testWidgets('countdown and Now do nothing unless an update is ready', (
    tester,
  ) async {
    final updater = FakeAppUpdater();
    final container = _make(updater, InMemoryPendingPatchStore());
    addTearDown(container.dispose);
    container.read(appUpdateProvider);
    await tester.pump();
    final notifier = container.read(appUpdateProvider.notifier);
    notifier.startCountdown();
    notifier.restartNow();
    await tester.pump(updateCountdownStep * 6);
    expect(updater.closes, 0);
    expect(container.read(appUpdateProvider).phase, AppUpdatePhase.current);
  });

  testWidgets('a launch clears any reopen notice still waiting', (
    tester,
  ) async {
    final notice = FakeReopenNotice();
    final container = _make(
      FakeAppUpdater(),
      InMemoryPendingPatchStore(),
      notice: notice,
    );
    addTearDown(container.dispose);
    container.read(appUpdateProvider);
    await tester.pump();
    expect(notice.cancels, 1);
  });

  group('quiet update on leaving the app', () {
    testWidgets('closes 3 s after leaving, with no notice', (tester) async {
      final updater = FakeAppUpdater(waiting: 5);
      final notice = FakeReopenNotice();
      final container = await _ready(tester, updater, notice: notice);
      addTearDown(container.dispose);
      final notifier = container.read(appUpdateProvider.notifier);
      notifier.onBackground();
      await tester.pump(updateQuietDelay - const Duration(milliseconds: 1));
      expect(updater.closes, 0);
      await tester.pump(const Duration(milliseconds: 1));
      expect(updater.closes, 1);
      expect(notice.scheduled, isEmpty);
    });

    testWidgets('coming back first keeps the app open', (tester) async {
      final updater = FakeAppUpdater(waiting: 5);
      final container = await _ready(tester, updater);
      addTearDown(container.dispose);
      final notifier = container.read(appUpdateProvider.notifier);
      notifier.onBackground();
      await tester.pump(const Duration(seconds: 1));
      notifier.onForeground();
      await tester.pump(updateQuietDelay * 2);
      expect(updater.closes, 0);
      expect(container.read(appUpdateProvider).phase, AppUpdatePhase.ready);
    });

    testWidgets('holds off while something is busy', (tester) async {
      final updater = FakeAppUpdater(waiting: 5);
      var busy = true;
      final container = await _ready(tester, updater, blocked: () => busy);
      addTearDown(container.dispose);
      final notifier = container.read(appUpdateProvider.notifier);
      notifier.onBackground();
      await tester.pump(updateQuietDelay * 2);
      expect(updater.closes, 0);
      // The next trip to the background tries again.
      notifier.onForeground();
      busy = false;
      notifier.onBackground();
      await tester.pump(updateQuietDelay);
      expect(updater.closes, 1);
    });

    testWidgets('a timer that fires late (the app was suspended) does not '
        'close', (tester) async {
      final updater = FakeAppUpdater(waiting: 5);
      var now = DateTime(2026, 11, 24, 12);
      final container = await _ready(tester, updater, clock: () => now);
      addTearDown(container.dispose);
      final notifier = container.read(appUpdateProvider.notifier);
      notifier.onBackground();
      now = now.add(const Duration(minutes: 10));
      await tester.pump(updateQuietDelay);
      expect(updater.closes, 0);
    });

    testWidgets('does nothing without a waiting patch', (tester) async {
      final updater = FakeAppUpdater();
      final container = _make(updater, InMemoryPendingPatchStore());
      addTearDown(container.dispose);
      container.read(appUpdateProvider);
      await tester.pump();
      container.read(appUpdateProvider.notifier).onBackground();
      await tester.pump(updateQuietDelay * 2);
      expect(updater.closes, 0);
    });

    testWidgets('leaving during the countdown cancels it, then applies '
        'quietly', (tester) async {
      final updater = FakeAppUpdater(waiting: 5);
      final notice = FakeReopenNotice();
      final container = await _ready(tester, updater, notice: notice);
      addTearDown(container.dispose);
      final notifier = container.read(appUpdateProvider.notifier);
      notifier.startCountdown();
      await tester.pump(updateCountdownStep);
      notifier.onBackground();
      expect(container.read(appUpdateProvider).phase, AppUpdatePhase.ready);
      await tester.pump(updateQuietDelay);
      expect(updater.closes, 1);
      expect(notice.scheduled, isEmpty);
    });
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

class _ThrowingNotice implements UpdateReopenNotice {
  @override
  Future<void> schedule({required Duration after}) async =>
      throw Exception('no notifications');
  @override
  Future<void> cancel() async => throw Exception('no notifications');
}
