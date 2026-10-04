import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/dj/dj_models.dart';

Map<String, dynamic> _track({Object? spotifyId = 'x', Object? newToYou = 'x'}) => {
      'position': 0,
      'trackId': 't1',
      'appleId': null,
      'title': 'T',
      'artist': 'A',
      if (spotifyId != 'x') 'spotifyId': spotifyId,
      if (newToYou != 'x') 'newToYou': newToYou,
    };

Map<String, dynamic> _session({Object? notPersonal = 'x'}) => {
      'id': 's1',
      'title': 'tape',
      'status': 'active',
      'queueVersion': 1,
      'updatedAt': '2026-08-29T12:00:00.000Z',
      if (notPersonal != 'x') 'notPersonal': notPersonal,
    };

Map<String, dynamic> _detail({Object? supportsInsert = 'x'}) => {
      'session': _session(),
      'messages': <Map<String, dynamic>>[],
      'queue': [_track()],
      if (supportsInsert != 'x') 'supportsInsert': supportsInsert,
    };

void main() {
  group('QueueTrack.spotifyId', () {
    test('parses a Spotify id as a peer of appleId', () {
      final track = QueueTrack.fromJson(_track(spotifyId: '4uLU6hMCjMI75M1A2tKUQC'));
      expect(track.spotifyId, '4uLU6hMCjMI75M1A2tKUQC');
      expect(track.appleId, isNull);
    });

    test('is null when absent or null on the wire', () {
      expect(QueueTrack.fromJson(_track()).spotifyId, isNull);
      expect(QueueTrack.fromJson(_track(spotifyId: null)).spotifyId, isNull);
    });
  });

  group('QueueTrack.newToYou', () {
    test('parses true from the wire', () {
      expect(QueueTrack.fromJson(_track(newToYou: true)).newToYou, isTrue);
    });

    test('defaults to false when absent or null, on the wire and in the constructor', () {
      expect(QueueTrack.fromJson(_track()).newToYou, isFalse);
      expect(QueueTrack.fromJson(_track(newToYou: null)).newToYou, isFalse);
      expect(QueueTrack.fromJson(_track(newToYou: false)).newToYou, isFalse);
      const track = QueueTrack(position: 0, trackId: 't', appleId: null, title: 'T', artist: 'A');
      expect(track.newToYou, isFalse);
    });
  });

  group('DjSession.notPersonal', () {
    test('parses true from the summary shape', () {
      expect(DjSession.fromJson(_session(notPersonal: true)).notPersonal, isTrue);
    });

    test('defaults to false when absent, on the wire and in the constructor', () {
      expect(DjSession.fromJson(_session()).notPersonal, isFalse);
      expect(DjSession.fromJson(_session(notPersonal: false)).notPersonal, isFalse);
      final session = DjSession(
        id: 's',
        title: 't',
        status: 'active',
        queueVersion: 0,
        updatedAt: DateTime.utc(2026),
      );
      expect(session.notPersonal, isFalse);
    });
  });

  group('QueueOp.insert', () {
    test('serialises the op, the 0-based position and the track id', () {
      expect(const QueueOp.insert(3, 'a2f0c9d4-0000-4000-8000-000000000001').toJson(), {
        'op': 'insert',
        'position': 3,
        'trackId': 'a2f0c9d4-0000-4000-8000-000000000001',
      });
    });

    test('position 0 rides the wire as 0, not as an omitted field', () {
      expect(const QueueOp.insert(0, 't').toJson(), {
        'op': 'insert',
        'position': 0,
        'trackId': 't',
      });
    });

    test('remove and move are untouched', () {
      expect(const QueueOp.remove(2).toJson(), {'op': 'remove', 'position': 2});
      expect(const QueueOp.move(1, 4).toJson(), {'op': 'move', 'from': 1, 'to': 4});
    });
  });

  group('SessionDetail.supportsInsert', () {
    test('parses the server capability flag', () {
      expect(SessionDetail.fromJson(_detail(supportsInsert: true)).supportsInsert, isTrue);
    });

    test('defaults to false when absent (an older deploy) or false on the wire', () {
      expect(SessionDetail.fromJson(_detail()).supportsInsert, isFalse);
      expect(SessionDetail.fromJson(_detail(supportsInsert: false)).supportsInsert, isFalse);
    });

    test('defaults to false in the constructor', () {
      final detail = SessionDetail(
        session: DjSession.fromJson(_session()),
        messages: const [],
        queue: const [],
      );
      expect(detail.supportsInsert, isFalse);
    });
  });
}
