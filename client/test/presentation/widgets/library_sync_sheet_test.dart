// The shared library-sync sheet (plan `docs/superpowers/plans/2026-09-17-
// native-design-implementation.md` task 8.1): one sheet on the shared sheet
// with a handle, opened from the Library tab and from Your music. The states
// and copy are the ones the P1 sheet shipped; the keys are the
// `library-sync-` ones the tab already published.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/library/library_sync_service.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_sheet.dart';
import 'package:mixtape/presentation/widgets/foundation/tape_button.dart';
import 'package:mixtape/presentation/widgets/library_sync_sheet.dart';

/// A sync pinned at one state, so every state can be asserted without ever
/// touching the MusicKit bridge.
class _PinnedSync extends LibrarySyncNotifier {
  _PinnedSync(this._state);
  final SyncState _state;

  /// Records the syncs the sheet asked for.
  int syncs = 0;

  @override
  SyncState build() => _state;

  @override
  Future<void> sync() async {
    syncs++;
  }
}

ProviderContainer _container(_PinnedSync sync) {
  final container = ProviderContainer(
    overrides: [librarySyncProvider.overrideWith(() => sync)],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container, {
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
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: Scaffold(
              body: Center(
                child: TextButton(
                  key: const Key('open'),
                  onPressed: () => LibrarySyncSheet.show(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open')));
  // An indeterminate progress bar never settles, so the running-at-zero case
  // pumps a fixed number of frames instead.
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
}

void main() {
  testWidgets('idle offers the tape button on the shared sheet with a handle', (
    tester,
  ) async {
    final sync = _PinnedSync(const SyncIdle());
    await _pump(tester, _container(sync));

    expect(find.byKey(MixtapeSheet.surfaceKey), findsOneWidget);
    expect(find.byKey(LibrarySyncSheet.handleKey), findsOneWidget);
    expect(find.byKey(LibrarySyncSheet.startKey), findsOneWidget);
    expect(find.byType(TapeButton), findsOneWidget);

    await tester.tap(find.byKey(LibrarySyncSheet.startKey));
    await tester.pumpAndSettle();
    expect(sync.syncs, 1);
  });

  testWidgets('running shows the progress line with its percentage', (
    tester,
  ) async {
    await _pump(tester, _container(_PinnedSync(const SyncRunning(0.4))));

    expect(find.text('Syncing… 40%'), findsOneWidget);
    expect(find.byKey(LibrarySyncSheet.progressKey), findsOneWidget);
    expect(find.byKey(LibrarySyncSheet.startKey), findsNothing);
  });

  testWidgets('a run that has not reported yet says only that it is syncing', (
    tester,
  ) async {
    await _pump(
      tester,
      _container(_PinnedSync(const SyncRunning(0))),
      settle: false,
    );

    expect(find.text('Syncing…'), findsOneWidget);
  });

  testWidgets('done counts what landed and offers another run', (tester) async {
    final sync = _PinnedSync(
      const SyncDone(
        LibrarySyncSummary(
          songs: 2,
          playlists: 1,
          entries: 10,
          resolvedEntries: 7,
          unresolvedEntries: 3,
        ),
      ),
    );
    await _pump(tester, _container(sync));

    expect(
      find.textContaining('Synced 2 songs and 1 playlist.'),
      findsOneWidget,
    );
    expect(
      find.text('3 playlist entries are still unmatched.'),
      findsOneWidget,
    );

    await tester.tap(find.byKey(LibrarySyncSheet.againKey));
    await tester.pumpAndSettle();
    expect(sync.syncs, 1);
  });

  testWidgets('failure says why and retries', (tester) async {
    final sync = _PinnedSync(const SyncFailed('Sync failed. Try again.'));
    await _pump(tester, _container(sync));

    expect(find.text('Sync failed. Try again.'), findsOneWidget);

    await tester.tap(find.byKey(LibrarySyncSheet.retryKey));
    await tester.pumpAndSettle();
    expect(sync.syncs, 1);
  });

  testWidgets('holds at 200% text on a 320 pt phone, in dark', (tester) async {
    await _pump(
      tester,
      _container(
        _PinnedSync(
          const SyncDone(
            LibrarySyncSummary(
              songs: 4312,
              playlists: 27,
              entries: 900,
              resolvedEntries: 899,
              unresolvedEntries: 1,
            ),
          ),
        ),
      ),
      brightness: Brightness.dark,
      size: const Size(320, 844),
      textScale: 2,
    );

    expect(find.byKey(LibrarySyncSheet.againKey), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
