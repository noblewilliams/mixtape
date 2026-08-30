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
}
