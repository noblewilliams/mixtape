import '../helpers/auth_ui_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/history/mix_history_api.dart';
import 'package:mixtape/presentation/screens/mix_history_screen.dart';

class FakeHistory implements MixHistoryApi {
  final List<Map<String, dynamic>> requests = [];
  bool loseResponse = false, conflict = false;
  @override
  ApiClient get client => throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> list(String id, {int? before}) async => {
    'currentVersion': 2,
    'versions': [
      {'version': 1, 'trackCount': 1},
    ],
    'nextBefore': null,
  };
  @override
  Future<Map<String, dynamic>> read(String id, int version) async => {
    'version': 1,
    'currentVersion': 2,
    'entries': [
      {
        'position': 0,
        'trackId': 't',
        'title': 'Song',
        'artist': 'Artist',
        'available': true,
      },
    ],
  };
  @override
  Future<Map<String, dynamic>> restore(
    String id,
    Map<String, dynamic> input,
  ) async {
    requests.add(Map.of(input));
    if (conflict) throw ApiException(409, '{"error":"conflict"}');
    if (loseResponse && requests.length == 1) throw Exception('offline');
    return {'version': 3};
  }
}

Future<void> open(WidgetTester tester, FakeHistory api) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [mixHistoryApiProvider.overrideWithValue(api)],
      child: const MaterialApp(home: MixHistoryScreen(sessionId: 's')),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('View'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('native history stays reachable on a short phone with large text', (tester) async {
    await loadAuthSnapshotFonts(tester);
    tester.view.physicalSize = const Size(390, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = FakeHistory();
    await tester.pumpWidget(ProviderScope(overrides:[mixHistoryApiProvider.overrideWithValue(api)],
      child:RepaintBoundary(key:authSnapshotKey,child:MaterialApp(theme:authSnapshotTheme(Brightness.dark),
        home:const MixHistoryScreen(sessionId:'s')))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View')); await tester.pumpAndSettle();
    await captureAuthSnapshot(tester,'mix-history-native-dark');
    tester.view.physicalSize = const Size(320,568);
    await tester.pumpWidget(ProviderScope(overrides:[mixHistoryApiProvider.overrideWithValue(api)],
      child:MaterialApp(theme:authSnapshotTheme(Brightness.light),builder:(context,child)=>MediaQuery(
        data:MediaQuery.of(context).copyWith(textScaler:const TextScaler.linear(2)),child:child!),
        home:const MixHistoryScreen(sessionId:'s'))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View'));await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Use this version'), 100);
    await tester.tap(find.text('Use this version'));await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Cancel'), 100);
    expect(find.text('Cancel'),findsOneWidget);
    expect(tester.takeException(),isNull);
  });

  testWidgets('previews then confirms and safely retries the same restore', (
    tester,
  ) async {
    final api = FakeHistory()..loseResponse = true;
    await open(tester, api);
    expect(find.text('Song'), findsOneWidget);
    expect(api.requests, isEmpty);
    await tester.tap(find.text('Use this version'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use version 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry restore'));
    await tester.pumpAndSettle();
    expect(api.requests.length, 2);
    expect(api.requests[0], api.requests[1]);
    expect(find.textContaining('Version 3 is ready'), findsOneWidget);
  });
  testWidgets('conflict preserves the mix and offers a fresh review', (
    tester,
  ) async {
    final api = FakeHistory()..conflict = true;
    await open(tester, api);
    await tester.tap(find.text('Use this version'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use version 1'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Your mix changed'), findsOneWidget);
    expect(find.text('Review latest'), findsOneWidget);
    expect(find.textContaining('Version 3 is ready'), findsNothing);
  });
}
