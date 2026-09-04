import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/dj/dj_models.dart';

Map<String, dynamic> _track({Object? spotifyId = 'x'}) => {
      'position': 0,
      'trackId': 't1',
      'appleId': null,
      'title': 'T',
      'artist': 'A',
      if (spotifyId != 'x') 'spotifyId': spotifyId,
    };

Map<String, dynamic> _session({Object? notPersonal = 'x'}) => {
      'id': 's1',
      'title': 'tape',
      'status': 'active',
      'queueVersion': 1,
      'updatedAt': '2026-08-29T12:00:00.000Z',
      if (notPersonal != 'x') 'notPersonal': notPersonal,
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
}
