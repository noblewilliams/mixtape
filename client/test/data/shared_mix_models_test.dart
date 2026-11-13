import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/dj/dj_models.dart';

Map<String, dynamic> _artwork() => {
  'url': 'https://is1-ssl.mzstatic.com/image/thumb/a/{w}x{h}bb.jpg',
  'width': 3000,
  'height': 3000,
  'bgColor': '1a2b3c',
};

Map<String, dynamic> _track({
  Object? album = 'Album',
  Object? durationMs = 200000,
  Object? artwork = 'default',
  Object? appleId = '123',
  Object? isrc = 'USRC17607839',
}) => {
  'title': 'Song',
  'artist': 'Artist',
  'album': album,
  'durationMs': durationMs,
  'artwork': artwork == 'default' ? _artwork() : artwork,
  'appleId': appleId,
  'isrc': isrc,
};

Map<String, dynamic> _shared({
  bool isOwner = false,
  Object? sessionId = 'absent',
  Object? sharerName = 'Ada',
  List<Map<String, dynamic>>? tracks,
}) => {
  'token': 'AbCdEfGhIjKlMnOpQrStUv',
  'title': 'Night drive',
  'caseColor': '#335577',
  'sharerName': sharerName,
  'sharedAt': '2026-11-13T10:00:00.000Z',
  'isOwner': isOwner,
  if (sessionId != 'absent') 'sessionId': sessionId,
  'tracks': tracks ?? [_track()],
};

Map<String, dynamic> _row({Object? sharerName = 'Ada', Object? artwork}) => {
  'token': 'AbCdEfGhIjKlMnOpQrStUv',
  'title': 'Night drive',
  'caseColor': '#335577',
  'sharerName': sharerName,
  'savedAt': '2026-11-13T11:00:00.000Z',
  'trackCount': 12,
  'durationMs': 2400000,
  'artwork': artwork,
};

Map<String, dynamic> _detail({Object? shared = 'absent'}) => {
  'session': {
    'id': 's1',
    'title': 'tape',
    'status': 'active',
    'queueVersion': 1,
    'updatedAt': '2026-08-29T12:00:00.000Z',
  },
  'messages': <Map<String, dynamic>>[],
  'queue': <Map<String, dynamic>>[],
  if (shared != 'absent') 'shared': shared,
};

void main() {
  group('SharedMix.fromJson', () {
    test('parses a recipient read', () {
      final mix = SharedMix.fromJson(_shared());
      expect(mix.token, 'AbCdEfGhIjKlMnOpQrStUv');
      expect(mix.title, 'Night drive');
      expect(mix.caseColor, '#335577');
      expect(mix.sharerName, 'Ada');
      expect(mix.sharedAt, DateTime.utc(2026, 11, 13, 10));
      expect(mix.isOwner, isFalse);
      expect(mix.sessionId, isNull);
      expect(mix.tracks, hasLength(1));
      final t = mix.tracks.single;
      expect(t.title, 'Song');
      expect(t.artist, 'Artist');
      expect(t.album, 'Album');
      expect(t.durationMs, 200000);
      expect(t.appleId, '123');
      expect(t.isrc, 'USRC17607839');
      expect(t.artwork!.url, contains('{w}x{h}'));
      expect(t.artwork!.width, 3000);
      expect(t.artwork!.bgColor, '1a2b3c');
    });

    test('a null sharer name is fine (the client shows "a friend")', () {
      expect(SharedMix.fromJson(_shared(sharerName: null)).sharerName, isNull);
    });

    test('the owner read carries the session id', () {
      final mix = SharedMix.fromJson(_shared(isOwner: true, sessionId: 's9'));
      expect(mix.isOwner, isTrue);
      expect(mix.sessionId, 's9');
    });

    test('an owner read without a session id is a drift error', () {
      expect(
        () => SharedMix.fromJson(_shared(isOwner: true)),
        throwsA(anything),
      );
    });

    test('a session id never reaches a non-owner', () {
      expect(SharedMix.fromJson(_shared(sessionId: 's9')).sessionId, isNull);
    });

    test('nullable track fields accept null', () {
      final t = SharedMix.fromJson(
        _shared(
          tracks: [
            _track(
              album: null,
              durationMs: null,
              artwork: null,
              appleId: null,
              isrc: null,
            ),
          ],
        ),
      ).tracks.single;
      expect(t.album, isNull);
      expect(t.durationMs, isNull);
      expect(t.artwork, isNull);
      expect(t.appleId, isNull);
      expect(t.isrc, isNull);
    });

    test('artwork with null size and colour parses', () {
      final t = SharedMix.fromJson(
        _shared(
          tracks: [
            _track(
              artwork: {
                'url': 'https://a/{w}x{h}.jpg',
                'width': null,
                'height': null,
                'bgColor': null,
              },
            ),
          ],
        ),
      ).tracks.single;
      expect(t.artwork!.url, 'https://a/{w}x{h}.jpg');
      expect(t.artwork!.width, isNull);
    });

    for (final key in [
      'token',
      'title',
      'caseColor',
      'sharerName',
      'sharedAt',
      'isOwner',
      'tracks',
    ]) {
      test('a missing "$key" throws', () {
        final json = _shared()..remove(key);
        expect(() => SharedMix.fromJson(json), throwsA(anything));
      });
    }

    for (final key in [
      'title',
      'artist',
      'album',
      'durationMs',
      'artwork',
      'appleId',
      'isrc',
    ]) {
      test('a track missing "$key" throws', () {
        final json = _shared(tracks: [_track()..remove(key)]);
        expect(() => SharedMix.fromJson(json), throwsA(anything));
      });
    }

    test('wrong types throw', () {
      expect(
        () => SharedMix.fromJson(_shared()..['isOwner'] = 'yes'),
        throwsA(anything),
      );
      expect(
        () => SharedMix.fromJson(_shared()..['title'] = 3),
        throwsA(anything),
      );
      expect(
        () => SharedMix.fromJson(_shared(tracks: [_track(durationMs: '200')])),
        throwsA(anything),
      );
      expect(
        () => SharedMix.fromJson(_shared(tracks: [_track(artwork: 'x')])),
        throwsA(anything),
      );
    });

    test('artwork missing a key throws', () {
      final art = _artwork()..remove('bgColor');
      expect(
        () => SharedMix.fromJson(_shared(tracks: [_track(artwork: art)])),
        throwsA(anything),
      );
    });
  });

  group('SharedMixRow.fromJson', () {
    test('parses a saved row', () {
      final row = SharedMixRow.fromJson(_row(artwork: _artwork()));
      expect(row.token, 'AbCdEfGhIjKlMnOpQrStUv');
      expect(row.title, 'Night drive');
      expect(row.caseColor, '#335577');
      expect(row.sharerName, 'Ada');
      expect(row.savedAt, DateTime.utc(2026, 11, 13, 11));
      expect(row.trackCount, 12);
      expect(row.durationMs, 2400000);
      expect(row.artwork!.width, 3000);
    });

    test('null sharer name and artwork are fine', () {
      final row = SharedMixRow.fromJson(_row(sharerName: null));
      expect(row.sharerName, isNull);
      expect(row.artwork, isNull);
    });

    for (final key in [
      'token',
      'title',
      'caseColor',
      'sharerName',
      'savedAt',
      'trackCount',
      'durationMs',
      'artwork',
    ]) {
      test('a missing "$key" throws', () {
        final json = _row()..remove(key);
        expect(() => SharedMixRow.fromJson(json), throwsA(anything));
      });
    }

    test('wrong types throw', () {
      expect(
        () => SharedMixRow.fromJson(_row()..['trackCount'] = '12'),
        throwsA(anything),
      );
      expect(
        () => SharedMixRow.fromJson(_row()..['savedAt'] = 'not a date'),
        throwsA(anything),
      );
    });
  });

  group('ShareLinkResult.fromJson', () {
    test('parses token and url', () {
      final link = ShareLinkResult.fromJson({
        'token': 'AbCdEfGhIjKlMnOpQrStUv',
        'url': 'https://miixtape.netlify.app/m/AbCdEfGhIjKlMnOpQrStUv',
      });
      expect(link.token, 'AbCdEfGhIjKlMnOpQrStUv');
      expect(link.url, endsWith('/m/AbCdEfGhIjKlMnOpQrStUv'));
    });

    test('a missing url throws', () {
      expect(
        () => ShareLinkResult.fromJson({'token': 'AbCdEfGhIjKlMnOpQrStUv'}),
        throwsA(anything),
      );
    });
  });

  group('SessionDetail.shared', () {
    test('parses the flag', () {
      expect(SessionDetail.fromJson(_detail(shared: true)).shared, isTrue);
      expect(SessionDetail.fromJson(_detail(shared: false)).shared, isFalse);
    });

    test('absent (an older server) reads as false', () {
      expect(SessionDetail.fromJson(_detail()).shared, isFalse);
    });

    test('a wrong type throws', () {
      expect(
        () => SessionDetail.fromJson(_detail(shared: 'yes')),
        throwsA(anything),
      );
    });
  });
}
