import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/screens/memory_screen.dart';

/// Mirrors the other screens' FakeDjApi (see queue_screen_test.dart):
/// implements DjApi's public surface, each method delegating to a settable
/// callback that throws loudly when unset. MemoryScreen only ever touches
/// listMemories/deleteMemory, so everything else is left unwired.
class FakeDjApi implements DjApi {
  Future<List<DjMemory>> Function()? onListMemories;
  Future<void> Function(String id)? onDeleteMemory;

  final List<String> deleteCalls = [];

  @override
  Duration get timeout => const Duration(seconds: 120);

  @override
  Future<SessionDetail> createSession(String prompt) => throw UnimplementedError();

  @override
  Future<List<DjSession>> listSessions() => throw UnimplementedError();

  @override
  Future<SessionDetail> getSession(String id) => throw UnimplementedError();

  @override
  Future<TurnResult> sendMessage(String id, String text) => throw UnimplementedError();

  @override
  Future<QueueOpsResult> applyQueueOps(String id, List<QueueOp> ops, int? expectedVersion) =>
      throw UnimplementedError();

  @override
  Future<DjSession> setStatus(String id, String status) => throw UnimplementedError();

  @override
  Future<DjSession> renameSession(String id, String title) => throw UnimplementedError();

  @override
  Future<void> postSessionEvent(String sessionId, String type) => throw UnimplementedError();

  @override
  Future<List<DjMemory>> listMemories() {
    final impl = onListMemories;
    if (impl == null) throw UnimplementedError('onListMemories not wired');
    return impl();
  }

  @override
  Future<void> deleteMemory(String id) {
    deleteCalls.add(id);
    final impl = onDeleteMemory;
    return impl == null ? Future.value() : impl(id);
  }

  @override
  void close() {}
}

class TestAuthNotifier extends AuthNotifier {
  TestAuthNotifier(this._initial);
  final AuthStatus _initial;

  @override
  AuthStatus build() => _initial;
}

DjMemory _memory({String id = 'm1', String note = 'a note', DateTime? createdAt}) =>
    DjMemory(id: id, note: note, createdAt: createdAt ?? DateTime.now());

ProviderContainer _makeContainer(FakeDjApi api) {
  final container = ProviderContainer(
    overrides: [
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      djApiProvider.overrideWithValue(api),
      authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.signedIn)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: MemoryScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders notes newest-first (server order), with relative time', (tester) async {
    final api = FakeDjApi();
    api.onListMemories = () async => [
          _memory(id: 'm2', note: 'always Wizkid on party tapes', createdAt: DateTime.now()),
          _memory(id: 'm1', note: 'no sad songs before noon', createdAt: DateTime.now()),
        ];
    final container = _makeContainer(api);
    await _pump(tester, container);

    final titles = tester
        .widgetList<Text>(find.descendant(of: find.byKey(const Key('memories-list')), matching: find.byType(Text)))
        .map((t) => t.data)
        .toList();

    expect(titles.indexOf('always Wizkid on party tapes'), lessThan(titles.indexOf('no sad songs before noon')));
    expect(find.textContaining('just now'), findsWidgets);
  });

  testWidgets('swiping a row hides it and shows an Undo snackbar', (tester) async {
    final api = FakeDjApi();
    api.onListMemories = () async => [_memory(id: 'm1', note: 'note one')];
    final container = _makeContainer(api);
    await _pump(tester, container);

    await tester.drag(find.byKey(const Key('dismissible-memory-m1')), const Offset(-500, 0));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(find.text('note one'), findsNothing);
    expect(find.text('Undo'), findsOneWidget);
    expect(api.deleteCalls, isEmpty);
  });

  testWidgets('tapping Undo restores the row and never calls delete', (tester) async {
    final api = FakeDjApi();
    api.onListMemories = () async => [_memory(id: 'm1', note: 'note one')];
    final container = _makeContainer(api);
    await _pump(tester, container);

    await tester.drag(find.byKey(const Key('dismissible-memory-m1')), const Offset(-500, 0));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(find.text('note one'), findsOneWidget);
    // Let any pending snackbar-closed future resolve — must NOT delete.
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();

    expect(api.deleteCalls, isEmpty);
  });

  testWidgets('letting the undo window expire commits exactly one delete call', (tester) async {
    final api = FakeDjApi();
    api.onListMemories = () async => [_memory(id: 'm1', note: 'note one'), _memory(id: 'm2', note: 'note two')];
    api.onDeleteMemory = (id) async {};
    final container = _makeContainer(api);
    await _pump(tester, container);

    await tester.drag(find.byKey(const Key('dismissible-memory-m1')), const Offset(-500, 0));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    expect(find.text('note one'), findsNothing);

    // Let the 5s snackbar duration elapse and settle.
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();

    expect(api.deleteCalls, ['m1']);
    expect(find.text('note one'), findsNothing);
    expect(find.text('note two'), findsOneWidget);
  });

  testWidgets('a delete failure on commit restores the row and shows a retry snackbar', (tester) async {
    final api = FakeDjApi();
    api.onListMemories = () async => [_memory(id: 'm1', note: 'note one')];
    api.onDeleteMemory = (id) async => throw ApiException(500, 'boom');
    final container = _makeContainer(api);
    await _pump(tester, container);

    await tester.drag(find.byKey(const Key('dismissible-memory-m1')), const Offset(-500, 0));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();

    expect(api.deleteCalls, ['m1']);
    expect(find.text('note one'), findsOneWidget);
    expect(find.text("couldn't forget that — try again"), findsOneWidget);
  });

  testWidgets('empty state shows a friendly message', (tester) async {
    final api = FakeDjApi();
    api.onListMemories = () async => [];
    final container = _makeContainer(api);
    await _pump(tester, container);

    expect(
      find.text("the DJ hasn't learned anything yet — tell it what you like in a session"),
      findsOneWidget,
    );
  });

  testWidgets('shows a spinner while loading', (tester) async {
    final completer = Completer<List<DjMemory>>();
    final api = FakeDjApi();
    api.onListMemories = () => completer.future;
    final container = _makeContainer(api);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: MemoryScreen()),
      ),
    );
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    completer.complete([]);
    await tester.pumpAndSettle();
  });

  testWidgets('a load failure shows an error state with a retry button; retry recovers', (tester) async {
    var shouldFail = true;
    final api = FakeDjApi();
    api.onListMemories = () async {
      if (shouldFail) throw ApiException(500, 'boom');
      return [_memory(id: 'm1', note: 'note one')];
    };
    final container = _makeContainer(api);
    await _pump(tester, container);

    expect(find.text("couldn't load what the DJ knows"), findsOneWidget);
    expect(find.byKey(const Key('memories-retry')), findsOneWidget);

    shouldFail = false;
    await tester.tap(find.byKey(const Key('memories-retry')));
    await tester.pumpAndSettle();

    expect(find.text('note one'), findsOneWidget);
  });

  group('fix round: pending-forget lifecycle', () {
    testWidgets(
      'popping the route while an undo window is open still fires exactly one delete, no thrown errors',
      (tester) async {
        final api = FakeDjApi();
        api.onListMemories = () async => [_memory(id: 'm1', note: 'note one')];
        api.onDeleteMemory = (id) async {};
        final container = _makeContainer(api);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      key: const Key('open-memories'),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => const MemoryScreen()),
                      ),
                      child: const Text('open'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const Key('open-memories')));
        await tester.pumpAndSettle();

        await tester.drag(find.byKey(const Key('dismissible-memory-m1')), const Offset(-500, 0));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        expect(find.text('Undo'), findsOneWidget);

        // Pop the route while the undo window is still open — the
        // ScaffoldMessenger that owns the snackbar is app-scoped (above the
        // Navigator), not route-scoped, so its `closed` future keeps running
        // past this screen's dispose().
        Navigator.of(tester.element(find.byType(MemoryScreen))).pop();
        await tester.pumpAndSettle();

        // Let the undo window elapse. If the fix regressed, this would
        // surface as an unhandled riverpod StateError — pumpAndSettle turns
        // any unhandled async error into a failing FlutterError here.
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();

        expect(api.deleteCalls, ['m1']);
      },
    );

    testWidgets(
      'two rapid swipes: the first commits immediately on the second swipe, the second keeps its own window',
      (tester) async {
        final api = FakeDjApi();
        api.onListMemories = () async => [
              _memory(id: 'm1', note: 'note one'),
              _memory(id: 'm2', note: 'note two'),
            ];
        api.onDeleteMemory = (id) async {};
        final container = _makeContainer(api);
        await _pump(tester, container);

        await tester.drag(find.byKey(const Key('dismissible-memory-m1')), const Offset(-500, 0));
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        expect(api.deleteCalls, isEmpty);

        // Second swipe, well within the first's 5s window.
        await tester.drag(find.byKey(const Key('dismissible-memory-m2')), const Offset(-500, 0));
        await tester.pumpAndSettle();

        // The first was finalized right on the second swipe — it never
        // waits out its own window.
        expect(api.deleteCalls, ['m1']);

        // The second still has its own live undo window.
        expect(find.text('Undo'), findsOneWidget);
        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();

        expect(find.text('note two'), findsOneWidget);
        expect(api.deleteCalls, ['m1']);

        // Letting time pass must not resurrect the second delete either —
        // it was undone, not deferred.
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpAndSettle();
        expect(api.deleteCalls, ['m1']);
      },
    );

    testWidgets('three rapid swipes leave no stranded hidden rows once everything settles', (tester) async {
      final api = FakeDjApi();
      api.onListMemories = () async => [
            _memory(id: 'm1', note: 'note one'),
            _memory(id: 'm2', note: 'note two'),
            _memory(id: 'm3', note: 'note three'),
            _memory(id: 'm4', note: 'note four'),
          ];
      api.onDeleteMemory = (id) async {};
      final container = _makeContainer(api);
      await _pump(tester, container);

      await tester.drag(find.byKey(const Key('dismissible-memory-m1')), const Offset(-500, 0));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      await tester.drag(find.byKey(const Key('dismissible-memory-m2')), const Offset(-500, 0));
      await tester.pumpAndSettle(const Duration(milliseconds: 50));
      await tester.drag(find.byKey(const Key('dismissible-memory-m3')), const Offset(-500, 0));
      await tester.pumpAndSettle();

      // m1 and m2 were superseded and finalized immediately; only m3 still
      // has a live undo window. The never-touched m4 stays visible
      // throughout.
      expect(api.deleteCalls, ['m1', 'm2']);
      expect(find.text('note four'), findsOneWidget);

      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();

      expect(api.deleteCalls, ['m1', 'm2', 'm3']);
      expect(find.text('note one'), findsNothing);
      expect(find.text('note two'), findsNothing);
      expect(find.text('note three'), findsNothing);
      expect(find.text('note four'), findsOneWidget);
    });
  });

  group('fix round: refetch on open', () {
    testWidgets(
      'a post-frame refresh on open picks up a note that appeared right as the screen opened',
      (tester) async {
        var calls = 0;
        final api = FakeDjApi();
        api.onListMemories = () async {
          calls++;
          if (calls == 1) return [_memory(id: 'm1', note: 'note one')];
          return [
            _memory(id: 'm2', note: 'note two', createdAt: DateTime.now()),
            _memory(id: 'm1', note: 'note one'),
          ];
        };
        final container = _makeContainer(api);
        await _pump(tester, container);

        expect(calls, 2, reason: 'build() plus the initState post-frame refresh');
        expect(find.text('note two'), findsOneWidget);
        expect(find.text('note one'), findsOneWidget);
      },
    );

    testWidgets('a failed pull-to-refresh keeps the list and says so', (tester) async {
      var calls = 0;
      final api = FakeDjApi();
      api.onListMemories = () async {
        calls++;
        if (calls > 2) throw ApiException(500, 'boom');
        return [_memory(id: 'm1', note: 'note one')];
      };
      final container = _makeContainer(api);
      await _pump(tester, container);
      expect(calls, 2, reason: 'build() plus the initState post-frame refresh');

      await tester.fling(find.byKey(const Key('memories-list')), const Offset(0, 300), 1000);
      await tester.pumpAndSettle();

      expect(calls, 3, reason: 'the pull must actually refetch');
      expect(find.text('note one'), findsOneWidget);
      expect(find.text("couldn't refresh — showing what we had"), findsOneWidget);
    });
  });
}
