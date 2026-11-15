// The shared load-failure state: a tap on Try again must show it is working
// (founder smoke, 2026-11-15: the button gave no response and then the screen
// suddenly loaded), and an offline failure must say it is offline.
import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/empty_state.dart';

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    theme: MixtapeTheme.light(),
    home: Scaffold(body: Center(child: child)),
  ),
);

const _retryKey = Key('retry');

void main() {
  group('retry feedback', () {
    testWidgets('shows a loader while the retry runs, then returns', (
      tester,
    ) async {
      final pending = Completer<void>();
      var calls = 0;
      await _pump(
        tester,
        LoadErrorState(
          title: 'Couldn’t load your music',
          retryKey: _retryKey,
          onRetry: () {
            calls++;
            return pending.future;
          },
        ),
      );
      expect(find.byType(CupertinoActivityIndicator), findsNothing);

      await tester.tap(find.byKey(_retryKey));
      await tester.pump();

      expect(calls, 1);
      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      expect(find.text(LoadErrorState.busyLabel), findsOneWidget);

      // A second tap while busy does not fire another retry.
      await tester.tap(find.byKey(_retryKey));
      await tester.pump();
      expect(calls, 1);

      pending.complete();
      await tester.pump(LoadErrorState.minBusy);
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('an instant failure still shows the loader for a beat', (
      tester,
    ) async {
      await _pump(
        tester,
        LoadErrorState(
          title: 'Couldn’t load your music',
          retryKey: _retryKey,
          onRetry: () async => throw NetworkException(
            const SocketException('Failed host lookup'),
          ),
        ),
      );

      await tester.tap(find.byKey(_retryKey));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);

      await tester.pump(LoadErrorState.minBusy);
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
    });
  });

  group('offline copy', () {
    testWidgets('a lost connection says so', (tester) async {
      await _pump(
        tester,
        LoadErrorState(
          title: 'Couldn’t load your music',
          error: NetworkException(
            http.ClientException("Failed host lookup: 'api.example.com'"),
          ),
          onRetry: () {},
        ),
      );
      expect(find.text(LoadErrorState.offlineBody), findsOneWidget);
      expect(find.text(LoadErrorState.defaultBody), findsNothing);
    });

    testWidgets('a server that does not answer says so', (tester) async {
      await _pump(
        tester,
        LoadErrorState(
          title: 'Couldn’t load your music',
          error: NetworkException(TimeoutException('slow')),
          onRetry: () {},
        ),
      );
      expect(find.text(LoadErrorState.unreachableBody), findsOneWidget);
    });

    testWidgets('any other failure says something went wrong', (tester) async {
      await _pump(
        tester,
        LoadErrorState(
          title: 'Couldn’t load your music',
          error: ApiException(500, 'boom'),
          onRetry: () {},
        ),
      );
      expect(find.text(LoadErrorState.defaultBody), findsOneWidget);
    });

    testWidgets('a screen line stands in for the generic one only', (
      tester,
    ) async {
      Future<void> pumpWith(Object error) => _pump(
        tester,
        LoadErrorState(
          title: 'Couldn’t load this tape',
          body: 'The mix itself is safe.',
          error: error,
          onRetry: () {},
        ),
      );

      await pumpWith(ApiException(500, 'boom'));
      expect(find.text('The mix itself is safe.'), findsOneWidget);

      await pumpWith(
        NetworkException(http.ClientException('Network is unreachable')),
      );
      expect(find.text(LoadErrorState.offlineBody), findsOneWidget);
      expect(find.text('The mix itself is safe.'), findsNothing);
    });
  });

  group('isOfflineError', () {
    test('reads the unreachable-network failures as offline', () {
      expect(
        isOfflineError(
          NetworkException(const SocketException('Failed host lookup: x')),
        ),
        isTrue,
      );
      expect(
        isOfflineError(
          NetworkException(
            const SocketException(
              'Connection failed',
              osError: OSError('Network is unreachable', 51),
            ),
          ),
        ),
        isTrue,
      );
    });

    test('a slow server or a server error is not offline', () {
      expect(
        isOfflineError(NetworkException(TimeoutException('slow'))),
        isFalse,
      );
      expect(isOfflineError(ApiException(503, '')), isFalse);
      expect(isOfflineError(null), isFalse);
    });
  });
}
