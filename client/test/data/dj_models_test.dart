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

  group('SessionKind', () {
    test('parses album, and anything else (absent, unknown) as mix', () {
      expect(SessionKind.fromWire('album'), SessionKind.album);
      expect(SessionKind.fromWire('mix'), SessionKind.mix);
      expect(SessionKind.fromWire(null), SessionKind.mix);
      expect(SessionKind.fromWire('radio'), SessionKind.mix);
    });
  });

  group('DjSession kind and pick', () {
    test('an older server row with no kind reads as a mix with no pick', () {
      final session = DjSession.fromJson(_session());
      expect(session.kind, SessionKind.mix);
      expect(session.pick, isNull);
    });

    test('an album row parses kind and the current pick summary', () {
      final session = DjSession.fromJson({
        ..._session(),
        'kind': 'album',
        'pick': {
          'title': 'Blue',
          'artist': 'Joni Mitchell',
          'artwork': {'url': 'https://a/{w}x{h}.jpg', 'width': 1400, 'height': 1400, 'bgColor': '0a0b0c'},
        },
      });
      expect(session.kind, SessionKind.album);
      expect(session.pick!.title, 'Blue');
      expect(session.pick!.artist, 'Joni Mitchell');
      expect(session.pick!.artwork!.url, 'https://a/{w}x{h}.jpg');
      expect(session.pick!.artwork!.width, 1400);
      expect(session.pick!.artwork!.bgColor, '0a0b0c');
    });

    test('an album row before its first pick has a null pick and null artwork is tolerated', () {
      expect(DjSession.fromJson({..._session(), 'kind': 'album', 'pick': null}).pick, isNull);
      final noArt = DjSession.fromJson({
        ..._session(),
        'kind': 'album',
        'pick': {'title': 'T', 'artist': 'A', 'artwork': null},
      });
      expect(noArt.pick!.artwork, isNull);
    });

    test('copyWith carries every field it is not told to change', () {
      final session = DjSession.fromJson({
        ..._session(notPersonal: true),
        'caseColor': 'plum',
        'kind': 'album',
        'pick': {'title': 'T', 'artist': 'A', 'artwork': null},
      });
      final next = session.copyWith(queueVersion: 7);
      expect(next.queueVersion, 7);
      expect(next.id, session.id);
      expect(next.title, session.title);
      expect(next.status, session.status);
      expect(next.updatedAt, session.updatedAt);
      expect(next.notPersonal, isTrue);
      expect(next.caseColor, 'plum');
      expect(next.kind, SessionKind.album);
      expect(next.pick, same(session.pick));
      expect(session.copyWith(title: 'x', status: 'archived', notPersonal: false).title, 'x');
    });
  });

  group('AlbumPick', () {
    test('parses the AlbumView shape', () {
      final pick = AlbumPick.fromJson(_album(type: 'ep', saved: true, version: 3));
      expect(pick.id, 'al-1');
      expect(pick.upc, '0001');
      expect(pick.appleId, '1440');
      expect(pick.title, 'Album al-1');
      expect(pick.artist, 'Artist');
      expect(pick.releaseYear, 1971);
      expect(pick.type, 'ep');
      expect(pick.trackCount, 10);
      expect(pick.durationMs, 2400000);
      expect(pick.artwork!.url, 'https://a/{w}x{h}.jpg');
      expect(pick.newToThem, isTrue);
      expect(pick.reason, 'the why');
      expect(pick.savedForLater, isTrue);
      expect(pick.version, 3);
    });

    test('nullable fields parse as null', () {
      final pick = AlbumPick.fromJson({
        ..._album(),
        'upc': null,
        'appleId': null,
        'releaseYear': null,
        'trackCount': null,
        'durationMs': null,
        'artwork': null,
      });
      expect(pick.upc, isNull);
      expect(pick.appleId, isNull);
      expect(pick.releaseYear, isNull);
      expect(pick.trackCount, isNull);
      expect(pick.durationMs, isNull);
      expect(pick.artwork, isNull);
    });

    test('typeLabel names every known type and capitalises an unknown one as given', () {
      String label(String type) => AlbumPick.fromJson(_album(type: type)).typeLabel;
      expect(label('album'), 'Album');
      expect(label('ep'), 'EP');
      expect(label('single'), 'Single');
      expect(label('live'), 'Live');
      expect(label('compilation'), 'Compilation');
      expect(label('soundtrack'), 'Soundtrack');
      expect(label('mixtape'), 'Mixtape');
      expect(label('remix album'), 'Remix album');
    });
  });

  group('AlbumPickState', () {
    test('parses pick, runners-up, passed and the version', () {
      final state = AlbumPickState.fromJson({
        'pick': _album(id: 'a'),
        'runnersUp': [_album(id: 'b'), _album(id: 'c')],
        'passed': [_album(id: 'z', version: 1)],
        'version': 2,
      });
      expect(state.version, 2);
      expect(state.pick!.id, 'a');
      expect(state.runnersUp.map((a) => a.id), ['b', 'c']);
      expect(state.passed.single.id, 'z');
    });

    test('tolerates absent keys: no pick, empty lists', () {
      final state = AlbumPickState.fromJson({'version': 0});
      expect(state.pick, isNull);
      expect(state.runnersUp, isEmpty);
      expect(state.passed, isEmpty);
      expect(AlbumPickState.fromJson({'version': 1, 'pick': null}).pick, isNull);
    });
  });

  group('album SessionDetail', () {
    test('an album session read parses with no queue key', () {
      final detail = SessionDetail.fromJson({
        'session': {..._session(), 'kind': 'album', 'queueVersion': 2},
        'messages': <Map<String, dynamic>>[],
        'pick': _album(id: 'a', version: 2),
        'runnersUp': [_album(id: 'b', version: 2)],
        'passed': <Map<String, dynamic>>[],
        'version': 2,
      });
      expect(detail.kind, SessionKind.album);
      expect(detail.queue, isEmpty);
      expect(detail.pickState!.version, 2);
      expect(detail.pickState!.pick!.id, 'a');
      expect(detail.pickState!.runnersUp.single.id, 'b');
      expect(detail.suggestions, isNull);
    });

    test('a create response carries suggestions', () {
      final detail = SessionDetail.fromJson({
        'session': {..._session(), 'kind': 'album'},
        'messages': <Map<String, dynamic>>[],
        'pick': null,
        'runnersUp': <Map<String, dynamic>>[],
        'passed': <Map<String, dynamic>>[],
        'version': 0,
        'suggestions': ['Something older', 'Less famous'],
      });
      expect(detail.pickState!.pick, isNull);
      expect(detail.suggestions, ['Something older', 'Less famous']);
    });

    test('a mix session has no pick state', () {
      final detail = SessionDetail.fromJson(_detail());
      expect(detail.kind, SessionKind.mix);
      expect(detail.pickState, isNull);
      expect(detail.queue, hasLength(1));
    });
  });

  group('album TurnResult', () {
    Map<String, dynamic> djMessage(int? v) => {
          'id': 'm',
          'role': 'dj',
          'content': 'try this',
          'queueVersion': v,
          'createdAt': '2026-10-20T12:00:00.000Z',
        };

    test('reads version as the queue version, with no queue', () {
      final result = TurnResult.fromJson({
        'djMessage': djMessage(3),
        'pick': _album(id: 'a', version: 3),
        'runnersUp': [_album(id: 'b', version: 3)],
        'passed': [_album(id: 'z', version: 2)],
        'version': 3,
        'sessionTitle': 'Sunday records',
      });
      expect(result.queue, isEmpty);
      expect(result.queueVersion, 3);
      expect(result.pickState!.version, 3);
      expect(result.pickState!.pick!.id, 'a');
      expect(result.pickState!.passed.single.id, 'z');
      expect(result.sessionTitle, 'Sunday records');
      expect(result.suggestions, isNull);
    });

    test('a failed album turn carries its refinement pills', () {
      final result = TurnResult.fromJson({
        'djMessage': djMessage(null),
        'pick': null,
        'runnersUp': <Map<String, dynamic>>[],
        'passed': <Map<String, dynamic>>[],
        'version': 0,
        'suggestions': ['Newer'],
      });
      expect(result.suggestions, ['Newer']);
      expect(result.pickState!.pick, isNull);
    });

    test('a mix turn is unchanged and has no pick state', () {
      final result = TurnResult.fromJson({
        'djMessage': djMessage(4),
        'queue': [_track()],
        'queueVersion': 4,
      });
      expect(result.queueVersion, 4);
      expect(result.queue, hasLength(1));
      expect(result.pickState, isNull);
      expect(result.suggestions, isNull);
    });
  });

  group('ListenLaterEntry', () {
    test('parses an entry; listened follows listenedAt', () {
      final entry = ListenLaterEntry.fromJson(_entry(listenedAt: '2026-10-21T09:00:00.000Z'));
      expect(entry.id, 'al-1');
      expect(entry.title, 'Blue');
      expect(entry.artist, 'Joni Mitchell');
      expect(entry.type, 'album');
      expect(entry.typeLabel, 'Album');
      expect(entry.releaseYear, 1971);
      expect(entry.artwork!.url, 'https://a/{w}x{h}.jpg');
      expect(entry.sessionId, 's1');
      expect(entry.savedAt, DateTime.parse('2026-10-20T12:00:00.000Z'));
      expect(entry.listenedAt, DateTime.parse('2026-10-21T09:00:00.000Z'));
      expect(entry.reason, 'the why');
      expect(entry.listened, isTrue);
    });

    test('nullable fields: no session, no reason, not listened', () {
      final entry = ListenLaterEntry.fromJson({..._entry(), 'sessionId': null, 'reason': null, 'artwork': null});
      expect(entry.sessionId, isNull);
      expect(entry.reason, isNull);
      expect(entry.artwork, isNull);
      expect(entry.listened, isFalse);
    });
  });
}

Map<String, dynamic> _album({
  String id = 'al-1',
  String type = 'album',
  bool saved = false,
  int version = 1,
}) => {
      'id': id,
      'upc': '0001',
      'appleId': '1440',
      'title': 'Album $id',
      'artist': 'Artist',
      'releaseYear': 1971,
      'type': type,
      'trackCount': 10,
      'durationMs': 2400000,
      'artwork': {'url': 'https://a/{w}x{h}.jpg', 'width': 1400, 'height': 1400, 'bgColor': null},
      'newToThem': true,
      'reason': 'the why',
      'savedForLater': saved,
      'version': version,
    };

Map<String, dynamic> _entry({String? listenedAt}) => {
      'id': 'al-1',
      'upc': '0001',
      'appleId': '1440',
      'title': 'Blue',
      'artist': 'Joni Mitchell',
      'releaseYear': 1971,
      'type': 'album',
      'trackCount': 10,
      'durationMs': 2200000,
      'artwork': {'url': 'https://a/{w}x{h}.jpg', 'width': 1400, 'height': 1400, 'bgColor': 'ffffff'},
      'sessionId': 's1',
      'savedAt': '2026-10-20T12:00:00.000Z',
      'listenedAt': listenedAt,
      'reason': 'the why',
    };
