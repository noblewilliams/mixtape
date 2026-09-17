import 'package:mixtape/data/playlists/playlist_context_models.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
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
  @override
  Future<void> recordPlaylistCreation(
    String sessionId,
    String appleLibraryId,
  ) async {}

  Future<List<DjMemory>> Function()? onListMemories;
  Future<void> Function(String id)? onDeleteMemory;

  final List<String> deleteCalls = [];

  @override
  Duration get timeout => const Duration(seconds: 120);

  @override
  Future<SessionDetail> createSession(
    String prompt, {
    InitialPlaylistSeed? playlistSeed,
  }) => throw UnimplementedError();

  @override
  Future<List<DjSession>> listSessions() => throw UnimplementedError();

  @override
  Future<SessionDetail> getSession(String id) => throw UnimplementedError();

  @override
  Future<TurnResult> sendMessage(String id, String text) =>
      throw UnimplementedError();

  @override
  Future<QueueOpsResult> applyQueueOps(
    String id,
    List<QueueOp> ops,
    int? expectedVersion,
  ) => throw UnimplementedError();

  @override
  Future<DjSession> setStatus(String id, String status) =>
      throw UnimplementedError();

  @override
  Future<DjSession> renameSession(String id, String title) =>
      throw UnimplementedError();

  @override
  Future<void> postSessionEvent(String sessionId, String type) =>
      throw UnimplementedError();

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

  @override
  Future<void> signOut() async => state = AuthStatus.signedOut;
}

DjMemory _memory({
  String id = 'm1',
  String note = 'a note',
  DateTime? createdAt,
}) => DjMemory(id: id, note: note, createdAt: createdAt ?? DateTime.now());

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
  testWidgets(
    'Forget opens confirmation; backdrop, Keep note and Escape never delete',
    (tester) async {
      final api = FakeDjApi()
        ..onListMemories = () async => [_memory(note: 'Gentle mornings')];
      await _pump(tester, _makeContainer(api));
      await tester.tap(find.byKey(const Key('forget-memory-m1')));
      await tester.pumpAndSettle();
      expect(find.text('Forget this preference?'), findsOneWidget);
      expect(find.text('You can’t undo this.'), findsOneWidget);
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.byKey(const Key('forget-memory-m1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep note'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('forget-memory-m1')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(api.deleteCalls, isEmpty);
      expect(find.byType(Dismissible), findsNothing);
    },
  );

  testWidgets('confirmation reconciles the list and offers no Undo', (
    tester,
  ) async {
    final api = FakeDjApi();
    api.onListMemories = () async =>
        api.deleteCalls.isEmpty ? [_memory(note: 'Gentle mornings')] : [];
    await _pump(tester, _makeContainer(api));
    await tester.tap(find.byKey(const Key('forget-memory-m1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forget note'));
    await tester.pumpAndSettle();
    expect(api.deleteCalls, ['m1']);
    expect(find.text('Gentle mornings'), findsNothing);
    expect(find.text('Undo'), findsNothing);
    expect(find.textContaining('Nothing remembered yet.'), findsOneWidget);
  });

  testWidgets(
    'duplicate confirmations are disabled; closing does not cancel a sent delete',
    (tester) async {
      final api = FakeDjApi();
      final pending = Completer<void>();
      api.onListMemories = () async =>
          api.deleteCalls.isEmpty ? [_memory()] : [];
      api.onDeleteMemory = (_) => pending.future;
      await _pump(tester, _makeContainer(api));
      await tester.tap(find.byKey(const Key('forget-memory-m1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forget note'));
      await tester.pump();
      await tester.tap(find.text('Forgetting…'));
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
      pending.complete();
      await tester.pumpAndSettle();
      expect(api.deleteCalls, ['m1']);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('lost DELETE response with canonical absence still succeeds', (
    tester,
  ) async {
    final api = FakeDjApi();
    api.onListMemories = () async => api.deleteCalls.isEmpty ? [_memory()] : [];
    api.onDeleteMemory = (_) async => throw NetworkException('offline');
    await _pump(tester, _makeContainer(api));
    await tester.tap(find.byKey(const Key('forget-memory-m1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forget note'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('Nothing remembered yet.'), findsOneWidget);
  });

  testWidgets(
    'unknown deletion closes modal, hides notes and offers canonical reload',
    (tester) async {
      final api = FakeDjApi();
      api.onListMemories = () async {
        if (api.deleteCalls.isNotEmpty) throw NetworkException('offline');
        return [_memory(note: 'Gentle mornings')];
      };
      await _pump(tester, _makeContainer(api));
      await tester.tap(find.byKey(const Key('forget-memory-m1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forget note'));
      await tester.pumpAndSettle();
      expect(find.text('Gentle mornings'), findsNothing);
      expect(
        find.text(
          'Couldn’t confirm the result. Reload your notes before trying again.',
        ),
        findsOneWidget,
      );
      expect(find.byType(AlertDialog), findsNothing);
      api.onListMemories = () async => [_memory(note: 'Still remembered')];
      await tester.tap(find.text('Reload notes'));
      await tester.pumpAndSettle();
      expect(find.text('Still remembered'), findsOneWidget);
      expect(api.deleteCalls, ['m1']);
    },
  );

  testWidgets('canonical presence retains modal with retry', (tester) async {
    final api = FakeDjApi()
      ..onListMemories = () async => [_memory(note: 'Gentle mornings')];
    await _pump(tester, _makeContainer(api));
    await tester.tap(find.byKey(const Key('forget-memory-m1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forget note'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Couldn’t forget this note. Try again.'), findsOneWidget);
    api.onListMemories = () async => [];
    await tester.tap(find.text('Forget note'));
    await tester.pumpAndSettle();
    expect(api.deleteCalls, ['m1', 'm1']);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('notes and modal fit narrow screen at 200 percent text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = FakeDjApi()
      ..onListMemories = () async => [
        _memory(
          note: 'For dinner, keep vocals in the background and start gently.',
        ),
      ];
    final container = _makeContainer(api);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: const MemoryScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('forget-memory-m1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('forget-memory-m1')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Keep note'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep note'));
    await tester.pumpAndSettle();
    expect(api.deleteCalls, isEmpty);
  });
  testWidgets('Back dismisses confirmation and restores focus to Forget', (
    tester,
  ) async {
    final api = FakeDjApi()..onListMemories = () async => [_memory()];
    await _pump(tester, _makeContainer(api));
    await tester.tap(find.byKey(const Key('forget-memory-m1')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(api.deleteCalls, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('forget-memory-m1')))
          .focusNode!
          .hasFocus,
      isTrue,
    );
  });

  testWidgets(
    'popping screen during confirmed delete never touches disposed UI',
    (tester) async {
      final api = FakeDjApi();
      final pending = Completer<void>();
      api.onListMemories = () async =>
          api.deleteCalls.isEmpty ? [_memory()] : [];
      api.onDeleteMemory = (_) => pending.future;
      final container = _makeContainer(api);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: navigator,
            home: const Scaffold(body: Text('Home')),
          ),
        ),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const MemoryScreen()),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('forget-memory-m1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forget note'));
      await tester.pump();
      navigator.currentState!.pop();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      pending.complete();
      await tester.pumpAndSettle();
      expect(api.deleteCalls, ['m1']);
      expect(find.text('Home'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('expired session clears protected notes and confirmation', (
    tester,
  ) async {
    final api = FakeDjApi()
      ..onListMemories = () async => [_memory(note: 'Private note')];
    api.onDeleteMemory = (_) async => throw ApiException(401, 'unauthorized');
    final container = _makeContainer(api);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, _) {
            final auth = ref.watch(authProvider);
            return MaterialApp(
              key: ValueKey(auth),
              home: auth == AuthStatus.signedIn
                  ? const MemoryScreen()
                  : const Scaffold(body: Text('Sign in')),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('forget-memory-m1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forget note'));
    await tester.pumpAndSettle();
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Private note'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('renders approved memory controls in ${brightness.name}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const output = String.fromEnvironment('NATIVE_MEMORY_SNAPSHOT_DIR');
      if (output.isNotEmpty) {
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await tester.runAsync(icons.load);
        const fontPath = String.fromEnvironment('NATIVE_MEMORY_SNAPSHOT_FONT');
        if (fontPath.isNotEmpty) {
          final loader = FontLoader('NativeSnapshot')
            ..addFont(
              Future.value(
                ByteData.sublistView(File(fontPath).readAsBytesSync()),
              ),
            );
          await tester.runAsync(loader.load);
        }
      }
      final api = FakeDjApi()
        ..onListMemories = () async => [
          _memory(id: 'm1', note: 'Prefer a gentle start to morning mixes.'),
          _memory(id: 'm2', note: 'For dinner, keep vocals in the background.'),
        ];
      const boundaryKey = Key('native-memory-snapshot');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: _makeContainer(api),
          child: RepaintBoundary(
            key: boundaryKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: ThemeData(
                colorSchemeSeed: const Color(0xFF544451),
                useMaterial3: true,
                brightness: brightness,
                fontFamily: output.isEmpty ? null : 'NativeSnapshot',
              ),
              home: const MemoryScreen(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> capture(String name) async {
        if (output.isEmpty) return;
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(boundaryKey),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '$output/native-memory-${brightness.name}-$name.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await capture('list');
      await tester.tap(find.byKey(const Key('forget-memory-m1')));
      await tester.pumpAndSettle();
      await capture('confirmation');
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('preserves canonical note order and refreshes when opened', (
    tester,
  ) async {
    final api = FakeDjApi();
    var reads = 0;
    api.onListMemories = () async {
      reads++;
      return [
        _memory(id: 'new', note: 'Newest note'),
        _memory(id: 'old', note: 'Older note'),
      ];
    };
    await _pump(tester, _makeContainer(api));
    expect(reads, 2);
    expect(
      tester.getTopLeft(find.text('Newest note')).dy,
      lessThan(tester.getTopLeft(find.text('Older note')).dy),
    );
    expect(find.text('just now'), findsNWidgets(2));
    await tester.drag(
      find.byKey(const Key('memories-list')),
      const Offset(0, 300),
    );
    await tester.pumpAndSettle();
    expect(reads, 3);
  });

  testWidgets('initial read error offers reload and keeps route navigation', (
    tester,
  ) async {
    final api = FakeDjApi()
      ..onListMemories = () async => throw ApiException(500, 'offline');
    final container = _makeContainer(api);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const MemoryScreen()),
    );
    await tester.pumpAndSettle();
    expect(find.text('Couldn’t load your notes.'), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
    api.onListMemories = () async => [];
    await tester.tap(find.text('Reload notes'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Nothing remembered yet.'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
  });
}
