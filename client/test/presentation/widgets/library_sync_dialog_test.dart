// The library-sync alert (approval `docs/mockups/approved/2026-11-03-library-
// sources.md`): a centred alert, not a sheet, that knows a re-sync from a
// first sync and keeps the run's states inside itself.
import 'package:flutter/cupertino.dart' show CupertinoAlertDialog;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/library/library_sync_service.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/library_sync_dialog.dart';

/// A sync pinned at one state; [sync] moves it to [next] so the alert can be
/// watched following the run it started.
class _PinnedSync extends LibrarySyncNotifier {
  _PinnedSync(this._state, {this.next});
  final SyncState _state;
  final SyncState? next;

  int syncs = 0;

  @override
  SyncState build() => _state;

  @override
  Future<void> sync() async {
    syncs++;
    if (next != null) state = next!;
  }
}

const _summary = LibrarySyncSummary(
  songs: 1284,
  playlists: 23,
  entries: 10,
  resolvedEntries: 7,
  unresolvedEntries: 3,
);

final List<Uri> _opened = [];

ProviderContainer _container(_PinnedSync sync) {
  _opened.clear();
  final container = ProviderContainer(
    overrides: [
      librarySyncProvider.overrideWith(() => sync),
      linkOpenerProvider.overrideWithValue((uri) async {
        _opened.add(uri);
        return true;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
  DateTime? lastSynced,
  Brightness brightness = Brightness.light,
  Size size = const Size(390, 844),
  double textScale = 1,
  bool settle = true,
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
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const Key('open'),
                onPressed: () =>
                    LibrarySyncDialog.show(context, lastSynced: lastSynced),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open')));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
}

void main() {
  testWidgets('after an earlier sync it asks to sync again, with the date', (
    tester,
  ) async {
    final sync = _PinnedSync(const SyncIdle());
    await _pump(
      tester,
      _container(sync),
      lastSynced: DateTime(DateTime.now().year, 11, 2),
    );

    expect(find.byType(CupertinoAlertDialog), findsOneWidget);
    expect(find.text(LibrarySyncDialog.resyncTitle), findsOneWidget);
    expect(find.textContaining('Last synced 2 Nov.'), findsOneWidget);

    await tester.tap(find.byKey(LibrarySyncDialog.startKey));
    await tester.pump();
    expect(sync.syncs, 1);
  });

  testWidgets('a first sync gets its own words', (tester) async {
    await _pump(tester, _container(_PinnedSync(const SyncIdle())));

    expect(find.text(LibrarySyncDialog.firstTitle), findsOneWidget);
    expect(find.textContaining('Last synced'), findsNothing);
  });

  testWidgets('Not now closes without syncing', (tester) async {
    final sync = _PinnedSync(const SyncIdle());
    await _pump(tester, _container(sync));

    await tester.tap(find.byKey(LibrarySyncDialog.cancelKey));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoAlertDialog), findsNothing);
    expect(sync.syncs, 0);
  });

  testWidgets('a run started here shows its progress, then its counts', (
    tester,
  ) async {
    final sync = _PinnedSync(const SyncIdle(), next: const SyncRunning(0.42));
    final container = _container(sync);
    await _pump(tester, container);

    await tester.tap(find.byKey(LibrarySyncDialog.startKey));
    await tester.pump();
    expect(find.byKey(LibrarySyncDialog.progressKey), findsOneWidget);
    expect(find.textContaining('42%'), findsOneWidget);
    expect(find.byKey(LibrarySyncDialog.hideKey), findsOneWidget);

    container.read(librarySyncProvider.notifier).state = const SyncDone(
      _summary,
    );
    await tester.pumpAndSettle();
    expect(find.text(LibrarySyncDialog.doneTitle), findsOneWidget);
    expect(
      find.textContaining('1,284 songs and 23 playlists synced.'),
      findsOneWidget,
    );
    expect(find.textContaining('3 playlist entries'), findsOneWidget);

    await tester.tap(find.byKey(LibrarySyncDialog.doneKey));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoAlertDialog), findsNothing);
  });

  testWidgets('opened while a run is going, it shows that run', (tester) async {
    await _pump(
      tester,
      _container(_PinnedSync(const SyncRunning(0))),
      settle: false,
    );

    expect(find.byKey(LibrarySyncDialog.progressKey), findsOneWidget);
    expect(find.byKey(LibrarySyncDialog.startKey), findsNothing);
  });

  testWidgets('opened after an earlier run, it asks again rather than '
      'replaying the result', (tester) async {
    await _pump(
      tester,
      _container(_PinnedSync(const SyncDone(_summary))),
      lastSynced: DateTime(DateTime.now().year, 11, 2),
    );

    expect(find.text(LibrarySyncDialog.resyncTitle), findsOneWidget);
    expect(find.byKey(LibrarySyncDialog.startKey), findsOneWidget);
  });

  testWidgets('a failed run says why and retries', (tester) async {
    final sync = _PinnedSync(
      const SyncIdle(),
      next: const SyncFailed('Sync failed. Try again.'),
    );
    await _pump(tester, _container(sync));
    await tester.tap(find.byKey(LibrarySyncDialog.startKey));
    await tester.pumpAndSettle();

    expect(find.text(LibrarySyncDialog.failedTitle), findsOneWidget);
    expect(find.text('Sync failed. Try again.'), findsOneWidget);

    await tester.tap(find.byKey(LibrarySyncDialog.retryKey));
    await tester.pumpAndSettle();
    expect(sync.syncs, 2);
  });

  testWidgets('access denied sends the listener to Settings', (tester) async {
    final sync = _PinnedSync(
      const SyncIdle(),
      next: const SyncFailed('denied', accessDenied: true),
    );
    await _pump(tester, _container(sync));
    await tester.tap(find.byKey(LibrarySyncDialog.startKey));
    await tester.pumpAndSettle();

    expect(find.text(LibrarySyncDialog.deniedTitle), findsOneWidget);
    expect(find.byKey(LibrarySyncDialog.retryKey), findsNothing);

    await tester.tap(find.byKey(LibrarySyncDialog.settingsKey));
    await tester.pumpAndSettle();
    expect(_opened.single.scheme, 'app-settings');
  });

  testWidgets('holds at 200% text on a 320 pt phone, in dark', (tester) async {
    final sync = _PinnedSync(const SyncIdle(), next: const SyncDone(_summary));
    await _pump(
      tester,
      _container(sync),
      lastSynced: DateTime(2025, 11, 2),
      brightness: Brightness.dark,
      size: const Size(320, 844),
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(LibrarySyncDialog.startKey));
    await tester.pumpAndSettle();
    expect(find.byKey(LibrarySyncDialog.doneKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
