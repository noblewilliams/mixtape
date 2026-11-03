import 'package:flutter/cupertino.dart' show CupertinoDialogAction;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/history/mix_history_api.dart';
import 'package:mixtape/presentation/screens/mix_history_screen.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/cassette_tile.dart';
import 'package:mixtape/presentation/widgets/foundation/tape_button.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/screens/queue_screen.dart';
import 'package:mixtape/presentation/widgets/tape_header.dart';

import '../helpers/auth_ui_snapshot.dart';
import 'queue_screen_test.dart' show FakeDjApi;

DjMessage _msg(String id, String role, String content, {int? version}) =>
    DjMessage(
      id: id,
      role: role,
      content: content,
      queueVersion: version,
      createdAt: DateTime(2026, 1, 1),
    );

/// The conversation the versions read their "made from" lines out of, and
/// the saved tape colour (Denim).
FakeDjApi _transcriptApi() {
  final session = DjSession(
    id: 's',
    title: 'Lagos',
    status: 'active',
    queueVersion: 3,
    updatedAt: DateTime(2026, 1, 1),
    caseColor: '#617f9c',
  );
  return FakeDjApi()
    ..onListSessions = (() async => [session])
    ..onGetSession = (_) async => SessionDetail(
      session: session,
      messages: [
        _msg('m1', 'user', 'Driving to Lekki with Tolu'),
        _msg('m2', 'dj', 'A smooth drive.', version: 1),
        _msg('m3', 'user', 'Make the end wind down'),
        _msg('m4', 'dj', 'Done.', version: 3),
      ],
      queue: [
        QueueTrack(
          position: 0,
          trackId: 't0',
          appleId: 'a0',
          title: 'Song',
          artist: 'Artist',
          durationMs: 46 * 60000,
        ),
      ],
    );
}

List<Override> _overrides(FakeHistory api) => [
  mixHistoryApiProvider.overrideWithValue(api),
  djApiProvider.overrideWithValue(_transcriptApi()),
];

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
      overrides: _overrides(api),
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
  testWidgets('Versions: Now and Earlier, readable times, made-from lines', (
    tester,
  ) async {
    final api = FakeHistory();
    await tester.pumpWidget(_app(api, brightness: Brightness.dark));
    await tester.pumpAndSettle();

    expect(find.text('Versions'), findsOneWidget);
    expect(find.byKey(const Key('mix-history-back')), findsOneWidget);
    expect(find.text('NOW'), findsOneWidget);
    expect(find.text('EARLIER'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Version 3')).dy,
      lessThan(tester.getTopLeft(find.text('EARLIER')).dy),
    );
    // Every cassette is 64 pt and wears the saved colour.
    final tiles = tester.widgetList<CassetteTile>(find.byType(CassetteTile));
    expect(tiles.length, 3);
    expect(tiles.map((t) => t.width).toSet(), {64});
    expect(tiles.map((t) => t.caseColor).toSet(), {const Color(0xFF617F9C)});
    // No Current badge, no footnote; times read like a person would say them.
    expect(find.text('Current'), findsNothing);
    expect(find.textContaining('may not have been saved'), findsNothing);
    expect(find.textContaining(RegExp(r'^Today, \d\d:\d\d · 3 songs · 46 min$')), findsOneWidget);
    expect(find.textContaining('· 1 song'), findsOneWidget);
    // The message that made each version, from the transcript.
    expect(find.text('“Make the end wind down”'), findsOneWidget);
    expect(find.text('“Driving to Lekki with Tolu”'), findsOneWidget);
    expect(find.text('Restored from version 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping Now opens the tape', (tester) async {
    final api = FakeHistory();
    await tester.pumpWidget(_app(api, brightness: Brightness.dark));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Version 3'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(QueueScreen), findsOneWidget);
  });

  testWidgets('opened from the tape, Now goes back to that tape', (
    tester,
  ) async {
    final api = FakeHistory();
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(api),
        child: MaterialApp(
          theme: MixtapeTheme.light(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      const MixHistoryScreen(sessionId: 's', fromTape: true),
                ),
              ),
              child: const Text('the tape'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('the tape'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Version 3'));
    await tester.pumpAndSettle();
    expect(find.byType(MixHistoryScreen), findsNothing);
    expect(find.byType(QueueScreen), findsNothing);
    expect(find.text('the tape'), findsOneWidget);
  });

  testWidgets('an earlier version previews with its header, made-from and a '
      'sticky Use this version; Back returns to the list', (tester) async {
    final api = FakeHistory();
    await open(tester, api);

    expect(find.byKey(TapeHeader.cassetteKey), findsOneWidget);
    expect(find.byKey(const Key('mix-history-made-from')), findsOneWidget);
    expect(find.text('“Driving to Lekki with Tolu”'), findsOneWidget);
    expect(find.text('Song'), findsOneWidget);
    expect(find.byKey(TapeBar.barKey), findsOneWidget);
    expect(find.text('Use this version'), findsOneWidget);
    expect(find.text('Back to versions'), findsNothing);

    await tester.tap(find.byKey(const Key('mix-history-back')));
    await tester.pumpAndSettle();
    expect(find.text('Versions'), findsOneWidget);
    expect(find.text('Use this version'), findsNothing);
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
          overrides: _overrides(api),
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
          overrides: _overrides(api),
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

    await tester.tap(find.byKey(const Key('mix-history-back')));
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
