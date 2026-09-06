import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/musickit/musickit_bridge.dart';
import 'package:mixtape/data/musickit/playlist_apply_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mixtape/musickit');
  const fingerprint =
      '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
  const otherFingerprint =
      'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
  const operationId = 'bbf4edfd-85c1-4f2e-97eb-d332a1d6f6fc';

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'fetches the live source fingerprint by opaque Apple library ID',
    () async {
      MethodCall? captured;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            captured = call;
            return fingerprint;
          });

      final result = await PlaylistApplyBridge().fetchPlaylistFingerprint(
        'p.source_1',
      );

      expect(captured?.method, 'fetchPlaylistFingerprint');
      expect(captured?.arguments, {'appleLibraryId': 'p.source_1'});
      expect(result, fingerprint);
    },
  );

  test(
    'creates one revised copy and decodes an exact success receipt',
    () async {
      MethodCall? captured;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            captured = call;
            return {
              'operationId': operationId,
              'outcome': 'success',
              'appleLibraryId': 'p.revised_1',
              'added': 3,
              'failed': 0,
              'resultingFingerprint': fingerprint,
            };
          });

      final receipt = await PlaylistApplyBridge().createRevisedPlaylist(
        operationId: operationId,
        name: 'Night Bus Notes (mixtape revision)',
        description: 'revised with mixtape',
        appleCatalogIds: const ['1', '2', '2'],
        desiredFingerprint: fingerprint,
      );

      expect(captured?.method, 'createRevisedPlaylist');
      expect(captured?.arguments, {
        'operationId': operationId,
        'name': 'Night Bus Notes (mixtape revision)',
        'description': 'revised with mixtape',
        'appleCatalogIds': ['1', '2', '2'],
        'desiredFingerprint': fingerprint,
      });
      expect(receipt.outcome, PlaylistApplyOutcome.success);
      expect(receipt.appleLibraryId, 'p.revised_1');
      expect(receipt.added, 3);
      expect(receipt.failed, 0);
      expect(receipt.resultingFingerprint, fingerprint);
    },
  );

  test('preserves a known partial result for reconciliation', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => {
            'operationId': operationId,
            'outcome': 'partial',
            'appleLibraryId': 'p.revised_1',
            'added': 2,
            'failed': 1,
            'resultingFingerprint': otherFingerprint,
          },
        );

    final receipt = await PlaylistApplyBridge().createRevisedPlaylist(
      operationId: operationId,
      name: 'Revision',
      description: 'revised with mixtape',
      appleCatalogIds: const ['1', '2', '3'],
      desiredFingerprint: fingerprint,
    );

    expect(receipt.outcome, PlaylistApplyOutcome.partial);
    expect(receipt.appleLibraryId, 'p.revised_1');
    expect(receipt.resultingFingerprint, otherFingerprint);
  });

  test('preserves an unknown result without retrying the mutation', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => {
            'operationId': operationId,
            'outcome': 'unknown',
            'appleLibraryId': null,
            'added': 0,
            'failed': 0,
            'resultingFingerprint': null,
          },
        );

    final receipt = await PlaylistApplyBridge().createRevisedPlaylist(
      operationId: operationId,
      name: 'Revision',
      description: 'revised with mixtape',
      appleCatalogIds: const ['1'],
      desiredFingerprint: fingerprint,
    );

    expect(receipt.outcome, PlaylistApplyOutcome.unknown);
    expect(receipt.appleLibraryId, isNull);
    expect(receipt.resultingFingerprint, isNull);
  });

  test('rejects unsafe arguments before invoking native code', () async {
    var invoked = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          invoked = true;
          return null;
        });

    await expectLater(
      PlaylistApplyBridge().fetchPlaylistFingerprint('bad/id'),
      throwsA(isA<MusicKitException>()),
    );
    await expectLater(
      PlaylistApplyBridge().createRevisedPlaylist(
        operationId: 'not-a-uuid',
        name: 'Revision',
        description: 'revised with mixtape',
        appleCatalogIds: const ['1'],
        desiredFingerprint: fingerprint,
      ),
      throwsA(isA<MusicKitException>()),
    );
    await expectLater(
      PlaylistApplyBridge().createRevisedPlaylist(
        operationId: operationId.toUpperCase(),
        name: 'Revision',
        description: 'revised with mixtape',
        appleCatalogIds: const ['1'],
        desiredFingerprint: fingerprint,
      ),
      throwsA(isA<MusicKitException>()),
    );
    await expectLater(
      PlaylistApplyBridge().createRevisedPlaylist(
        operationId: operationId,
        name: 'Revision',
        description: 'revised with mixtape',
        appleCatalogIds: const ['bad/id'],
        desiredFingerprint: fingerprint,
      ),
      throwsA(isA<MusicKitException>()),
    );
    expect(invoked, isFalse);
  });

  test('rejects malformed or mismatched native receipts', () async {
    for (final payload in [
      null,
      <String, dynamic>{},
      {
        'operationId': '4ed34f1c-b809-44a8-8324-2fcb1db08712',
        'outcome': 'success',
        'appleLibraryId': 'p.revised_1',
        'added': 1,
        'failed': 0,
        'resultingFingerprint': fingerprint,
      },
      {
        'operationId': operationId,
        'outcome': 'success',
        'appleLibraryId': 'p.revised_1',
        'added': 1,
        'failed': 0,
        'resultingFingerprint': otherFingerprint,
      },
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => payload);
      await expectLater(
        PlaylistApplyBridge().createRevisedPlaylist(
          operationId: operationId,
          name: 'Revision',
          description: 'revised with mixtape',
          appleCatalogIds: const ['1'],
          desiredFingerprint: fingerprint,
        ),
        throwsA(isA<MusicKitException>()),
      );
    }
  });

  test('fixed errors wrap platform failures and timeouts', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          throw PlatformException(code: 'provider_body', details: 'private');
        });
    await expectLater(
      PlaylistApplyBridge().fetchPlaylistFingerprint('p.source'),
      throwsA(
        isA<MusicKitException>().having(
          (error) => error.message,
          'message',
          'playlist apply failed',
        ),
      ),
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) => Completer<dynamic>().future);
    await expectLater(
      PlaylistApplyBridge(
        callTimeout: const Duration(milliseconds: 20),
      ).fetchPlaylistFingerprint('p.source'),
      throwsA(isA<MusicKitException>()),
    );
  });
}
