import 'package:flutter/cupertino.dart' show CupertinoDialogAction;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/history/mix_history_api.dart';
import 'package:mixtape/presentation/screens/mix_history_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/cassette_tile.dart';
import 'package:mixtape/presentation/widgets/foundation/status_word.dart';
import 'package:mixtape/presentation/widgets/foundation/tape_button.dart';

import '../helpers/auth_ui_snapshot.dart';

class FakeHistory implements MixHistoryApi {
  final List<Map<String, dynamic>> requests = [];
  int listCalls = 0;
  bool loseResponse = false, conflict = false, listFails = false;

  @override
  ApiClient get client => throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> list(String id, {int? before}) async {
    listCalls++;
    if (listFails && listCalls == 1) throw Exception('offline');
    return {
      'currentVersion': 3,
      'versions': [
        {
          'version': 3,
          'trackCount': 3,
          'restoredFrom': null,
          'createdAt': DateTime.now()
              .subtract(const Duration(minutes: 4))
              .toIso8601String(),
        },
        {
          'version': 2,
          'trackCount': 2,
          'restoredFrom': 1,
          'createdAt': DateTime.now()
              .subtract(const Duration(hours: 3))
              .toIso8601String(),
        },
        {
          'version': 1,
          'trackCount': 1,
          'restoredFrom': null,
          'createdAt': DateTime.now()
              .subtract(const Duration(days: 2))
              .toIso8601String(),
        },
      ],
      'nextBefore': null,
    };
  }

  /// A version holds as many songs as its number, so a preview says which
  /// version it is showing.
  @override
  Future<Map<String, dynamic>> read(String id, int version) async => {
    'version': version,
    'currentVersion': 3,
    'entries': [
      for (var i = 0; i < version; i++)
        {
          'position': i,
          'trackId': 't$i',
          'title': i == 0 ? 'Song' : 'Song ${i + 1}',
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

Widget _app(FakeHistory api, {Brightness brightness = Brightness.light}) =>
    ProviderScope(
      overrides: [mixHistoryApiProvider.overrideWithValue(api)],
      child: MaterialApp(
        theme: brightness == Brightness.dark
            ? MixtapeTheme.dark()
            : MixtapeTheme.light(),
        home: const MixHistoryScreen(sessionId: 's'),
      ),
    );

/// Opens the screen and previews version 1 — the version that is not current,
/// so "Use this version" is offered.
Future<void> open(WidgetTester tester, FakeHistory api) async {
  await tester.pumpWidget(_app(api));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Version 1'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the version list carries the shell: cassette rows, a Current '
      'word and a meta line', (tester) async {
    final api = FakeHistory();
    await tester.pumpWidget(_app(api, brightness: Brightness.dark));
    await tester.pumpAndSettle();

    expect(find.text('Version history'), findsOneWidget);
    expect(find.byKey(const Key('mix-history-back')), findsOneWidget);
    expect(find.byType(CassetteTile), findsNWidgets(3));
    final current = tester.widget<StatusWord>(find.byType(StatusWord));
    expect(current.label, 'Current');
    expect(current.kind, StatusKind.ok);
    expect(find.textContaining('1 song ·'), findsOneWidget);
    expect(find.text('2 songs · 3h ago · restored from version 1'), findsOneWidget);
    // Nothing in the payload says a version was generated or edited, so the
    // meta line stops after the age rather than guessing.
    expect(find.text('3 songs · 4m ago'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the current version lists its songs and offers no restore', (
    tester,
  ) async {
    final api = FakeHistory();
    await tester.pumpWidget(_app(api, brightness: Brightness.dark));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Version 3'));
    await tester.pumpAndSettle();

    expect(find.text('Song'), findsOneWidget);
    expect(find.text('Song 3'), findsOneWidget);
    expect(find.text('Use this version'), findsNothing);
    expect(find.text('Back to versions'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'native history stays reachable on a short phone with large text',
    (tester) async {
      await loadAuthSnapshotFonts(tester);
      tester.view.physicalSize = const Size(390, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = FakeHistory();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [mixHistoryApiProvider.overrideWithValue(api)],
          child: RepaintBoundary(
            key: authSnapshotKey,
            child: MaterialApp(
              theme: MixtapeTheme.dark(),
              home: const MixHistoryScreen(sessionId: 's'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Version 1'));
      await tester.pumpAndSettle();
      await captureAuthSnapshot(tester, 'mix-history-native-dark');

      tester.view.physicalSize = const Size(320, 568);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [mixHistoryApiProvider.overrideWithValue(api)],
          child: MaterialApp(
            theme: MixtapeTheme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const MixHistoryScreen(sessionId: 's'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Version 1'), 100);
      await tester.ensureVisible(find.text('Version 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Version 1'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Use this version'), 100);
      await tester.ensureVisible(find.text('Use this version'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use this version'));
      await tester.pumpAndSettle();

      // The confirm is a dialog on a 320 × 568 screen at 200% text: both its
      // answers have to sit inside the viewport, Cancel included.
      expect(find.text('Cancel'), findsOneWidget);
      expect(
        tester
            .widget<CupertinoDialogAction>(find.ancestor(
              of: find.text('Cancel'),
              matching: find.byType(CupertinoDialogAction),
            ))
            .onPressed,
        isNotNull,
      );
      final cancel = tester.getRect(find.text('Cancel'));
      expect(cancel.top, greaterThanOrEqualTo(0));
      expect(cancel.bottom, lessThanOrEqualTo(568));
      expect(find.text('Use version 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('previews then confirms and safely retries the same restore', (
    tester,
  ) async {
    final api = FakeHistory()..loseResponse = true;
    await open(tester, api);
    expect(find.text('Song'), findsOneWidget);
    expect(api.requests, isEmpty);
    await tester.tap(find.text('Use this version'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('This creates a new version'),
      findsOneWidget,
    );
    await tester.tap(find.text('Use version 1'));
    await tester.pumpAndSettle();
    expect(find.textContaining('We couldn’t confirm the restore'), findsWidgets);
    // The way out stays open while the answer is unknown.
    expect(
      tester
          .widget<CupertinoDialogAction>(find.ancestor(
            of: find.text('Close'),
            matching: find.byType(CupertinoDialogAction),
          ))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.text('Retry restore'));
    await tester.pumpAndSettle();
    expect(api.requests.length, 2);
    expect(api.requests[0], api.requests[1]);
    expect(find.textContaining('Version 3 is ready'), findsOneWidget);
    expect(
      tester.widget<TapeButton>(find.byType(TapeButton)).label,
      'Back to mix',
    );
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

  testWidgets('leaving an unconfirmed restore for another version starts a '
      'fresh request', (tester) async {
    final api = FakeHistory()..loseResponse = true;
    await open(tester, api);
    await tester.tap(find.text('Use this version'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use version 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Back to versions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Version 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use this version'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use version 2'));
    await tester.pumpAndSettle();

    expect(api.requests.length, 2);
    expect(api.requests[0]['version'], 1);
    expect(api.requests[1]['version'], 2);
    expect(api.requests[1]['requestId'], isNot(api.requests[0]['requestId']));
  });

  testWidgets('a failed load says so and retries from a tape button', (
    tester,
  ) async {
    final api = FakeHistory()..listFails = true;
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();

    expect(find.textContaining('Couldn’t load versions'), findsOneWidget);
    await tester.tap(find.text('Review latest'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Couldn’t load versions'), findsNothing);
    expect(find.text('Version 1'), findsOneWidget);
  });
}
