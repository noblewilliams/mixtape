// The DJ paused kill switch: one source of truth for whether the app may
// send anything that needs the model. `GET /health`'s `djPaused` decides,
// read at start, on resume and on a timer; a send refused with `503
// dj_paused` pauses at once; a failed read never pauses.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/config/config_api.dart';
import 'package:mixtape/presentation/providers/dj_status_provider.dart';
import 'package:mixtape/presentation/providers/first_run_flags_provider.dart';

/// `/health` as the test says: true, false, or null (a failed read).
class _FakeConfigApi implements ConfigApi {
  bool? answer = false;
  int reads = 0;

  @override
  Future<bool?> djPaused() async {
    reads++;
    return answer;
  }

  @override
  Future<FirstRunFlags> flags() async => FirstRunFlags.off;
}

ProviderContainer _make(_FakeConfigApi api) =>
    ProviderContainer(overrides: [configApiProvider.overrideWithValue(api)]);

void main() {
  group('djStatusProvider', () {
    test('opens by default, with nothing read', () {
      final api = _FakeConfigApi();
      final container = _make(api);
      addTearDown(container.dispose);
      expect(container.read(djStatusProvider), DjStatus.open);
      expect(api.reads, 0);
    });

    test('a send refused with dj_paused pauses at once', () {
      final container = _make(_FakeConfigApi());
      addTearDown(container.dispose);
      container.read(djStatusProvider.notifier).markPaused();
      expect(container.read(djStatusProvider), DjStatus.paused);
      expect(container.read(djPausedProvider), isTrue);
    });

    test('refresh follows /health both ways', () async {
      final api = _FakeConfigApi()..answer = true;
      final container = _make(api);
      addTearDown(container.dispose);
      final notifier = container.read(djStatusProvider.notifier);

      await notifier.refresh();
      expect(container.read(djStatusProvider), DjStatus.paused);

      api.answer = false;
      await notifier.refresh();
      expect(container.read(djStatusProvider), DjStatus.open);
    });

    test('a failed read never pauses, and keeps what was known', () async {
      final api = _FakeConfigApi()..answer = null;
      final container = _make(api);
      addTearDown(container.dispose);
      final notifier = container.read(djStatusProvider.notifier);

      await notifier.refresh();
      expect(container.read(djStatusProvider), DjStatus.open);

      notifier.markPaused();
      await notifier.refresh();
      expect(container.read(djStatusProvider), DjStatus.paused);
    });
  });

  group('djStatusMonitorProvider', () {
    testWidgets('reads at start, then every 5 minutes while open', (
      tester,
    ) async {
      final api = _FakeConfigApi();
      final container = _make(api);
      container.listen(djStatusMonitorProvider, (_, _) {});
      await tester.pump();
      expect(api.reads, 1);

      await tester.pump(const Duration(minutes: 4));
      expect(api.reads, 1);
      await tester.pump(const Duration(minutes: 1, seconds: 1));
      expect(api.reads, 2);

      container.dispose();
    });

    testWidgets('re-reads every minute while paused, and reopens itself', (
      tester,
    ) async {
      final api = _FakeConfigApi()..answer = true;
      final container = _make(api);
      container.listen(djStatusMonitorProvider, (_, _) {});
      await tester.pump();
      expect(container.read(djStatusProvider), DjStatus.paused);

      await tester.pump(const Duration(seconds: 61));
      expect(api.reads, 2);
      expect(container.read(djStatusProvider), DjStatus.paused);

      // The operator flips the flag back.
      api.answer = false;
      await tester.pump(const Duration(seconds: 61));
      expect(api.reads, 3);
      expect(container.read(djStatusProvider), DjStatus.open);

      // Open again: back to the slow read.
      await tester.pump(const Duration(seconds: 61));
      expect(api.reads, 3);

      container.dispose();
    });

    testWidgets('a refused send moves to the paused cadence at once', (
      tester,
    ) async {
      final api = _FakeConfigApi()..answer = null;
      final container = _make(api);
      container.listen(djStatusMonitorProvider, (_, _) {});
      await tester.pump();
      expect(api.reads, 1);

      container.read(djStatusProvider.notifier).markPaused();
      await tester.pump(const Duration(seconds: 61));
      expect(api.reads, 2);
      // A failed read on the way keeps it paused.
      expect(container.read(djStatusProvider), DjStatus.paused);

      container.dispose();
    });

    testWidgets('re-reads when the app comes back to the foreground', (
      tester,
    ) async {
      final api = _FakeConfigApi();
      final container = _make(api);
      container.listen(djStatusMonitorProvider, (_, _) {});
      await tester.pump();
      expect(api.reads, 1);

      api.answer = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(api.reads, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(api.reads, 2);
      expect(container.read(djStatusProvider), DjStatus.paused);

      container.dispose();
    });

    testWidgets('disposing cancels the timer', (tester) async {
      final api = _FakeConfigApi();
      final container = _make(api);
      container.listen(djStatusMonitorProvider, (_, _) {});
      await tester.pump();
      container.dispose();
      await tester.pump(const Duration(minutes: 10));
      expect(api.reads, 1);
    });
  });
}
