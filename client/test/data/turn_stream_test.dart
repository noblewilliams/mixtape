import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/dj/turn_stream.dart';

/// Splits [bytes] into chunks at [cuts] (ascending byte offsets).
List<List<int>> _cutAt(List<int> bytes, List<int> cuts) {
  final chunks = <List<int>>[];
  var start = 0;
  for (final cut in [...cuts, bytes.length]) {
    chunks.add(bytes.sublist(start, cut));
    start = cut;
  }
  return chunks;
}

Future<List<SseEvent>> _decode(List<List<int>> chunks) =>
    decodeSse(Stream.fromIterable(chunks)).toList();

Future<List<SseEvent>> _decodeText(String text) => _decode([utf8.encode(text)]);

/// A stream of events with names that are not ASCII (two-, three- and
/// four-byte UTF-8), a keepalive and a comment, written with [nl] as the
/// line ending.
String _payload(String nl) => [
  ': keepalive$nl$nl',
  'event: session$nl',
  'data: {"session":{"id":"s1","title":"Café – 夜"}}$nl$nl',
  ': a comment between events$nl',
  'event: step$nl',
  'data: {"step":"digging","scope":"library",'
      '"artists":["Beyoncé","Sigur Rós","Tems 🎧"]}$nl$nl',
  'event: result$nl',
  'data: {"done":"✓ ok"}$nl$nl',
].join();

const _payloadEvents = [
  SseEvent('session', '{"session":{"id":"s1","title":"Café – 夜"}}'),
  SseEvent(
    'step',
    '{"step":"digging","scope":"library",'
        '"artists":["Beyoncé","Sigur Rós","Tems 🎧"]}',
  ),
  SseEvent('result', '{"done":"✓ ok"}'),
];

Future<(TurnStreamEnd, List<TurnProgress>)> _read(String text) async {
  final progress = <TurnProgress>[];
  final end = await readTurnStream(
    Stream.value(utf8.encode(text)),
    progress.add,
  );
  return (end, progress);
}

String _event(String name, Object data) =>
    'event: $name\ndata: ${jsonEncode(data)}\n\n';

void main() {
  group('decodeSse', () {
    test('reads one event', () async {
      expect(await _decodeText('event: step\ndata: {"step":"digging"}\n\n'), [
        const SseEvent('step', '{"step":"digging"}'),
      ]);
    });

    for (final (name, nl) in [('LF', '\n'), ('CRLF', '\r\n'), ('CR', '\r')]) {
      test('$name endings: the same events whatever byte the chunk splits '
          'at, including inside a multi-byte character', () async {
        final bytes = utf8.encode(_payload(nl));
        // Sanity: the payload really has multi-byte characters to split.
        expect(bytes.length, greaterThan(_payload(nl).length));
        for (var cut = 0; cut <= bytes.length; cut++) {
          expect(
            await _decode(_cutAt(bytes, [cut])),
            _payloadEvents,
            reason: 'split at byte $cut',
          );
        }
      });

      test('$name endings: the same events from one-byte chunks', () async {
        final bytes = utf8.encode(_payload(nl));
        expect(
          await _decode([
            for (final b in bytes) [b],
          ]),
          _payloadEvents,
        );
      });

      test('$name endings: the same events split at every pair of '
          'offsets', () async {
        final bytes = utf8.encode(_payload(nl));
        // Strided to stay fast: the single-cut and one-byte tests above
        // already cover every offset; this adds three-chunk splits.
        for (var a = 0; a <= bytes.length; a += 7) {
          for (var b = a; b <= bytes.length; b += 5) {
            expect(
              await _decode(_cutAt(bytes, [a, b])),
              _payloadEvents,
              reason: 'split at bytes $a and $b',
            );
          }
        }
      });
    }

    test('a CRLF split between chunks is one line ending, not two', () async {
      expect(
        await _decode([
          utf8.encode('event: step\r'),
          utf8.encode('\ndata: {"step":"pressing"}\r'),
          utf8.encode('\n\r'),
          utf8.encode('\n'),
        ]),
        [const SseEvent('step', '{"step":"pressing"}')],
      );
    });

    test('comment lines are ignored, alone or inside an event', () async {
      expect(await _decodeText(': keepalive\n\n: keepalive\n\n'), isEmpty);
      expect(
        await _decodeText('event: step\n: keepalive\ndata: {"step":"x"}\n\n'),
        [const SseEvent('step', '{"step":"x"}')],
      );
    });

    test('several data lines join with a newline', () async {
      expect(await _decodeText('event: result\ndata: {"a":\ndata: 1}\n\n'), [
        const SseEvent('result', '{"a":\n1}'),
      ]);
    });

    test('id, retry and unknown fields are ignored', () async {
      expect(
        await _decodeText(
          'id: 7\nretry: 1000\nevent: step\nfoo: bar\ndata: {}\n\n',
        ),
        [const SseEvent('step', '{}')],
      );
    });

    test('one leading space is dropped from a value, no more', () async {
      expect(await _decodeText('event:step\ndata:a\ndata:  b\n\n'), [
        const SseEvent('step', 'a\n b'),
      ]);
    });

    test('a field line without a colon has an empty value', () async {
      expect(await _decodeText('event: step\ndata\ndata: x\n\n'), [
        const SseEvent('step', '\nx'),
      ]);
    });

    test('an event without an event line is a message', () async {
      expect(await _decodeText('data: hi\n\n'), [
        const SseEvent('message', 'hi'),
      ]);
    });

    test('a blank line with no data dispatches nothing and resets the '
        'event name', () async {
      expect(await _decodeText('event: step\n\ndata: hi\n\n'), [
        const SseEvent('message', 'hi'),
      ]);
    });

    test(
      'an event cut off before its blank line is never dispatched',
      () async {
        expect(await _decodeText('event: result\ndata: {"a":1}\n'), isEmpty);
        expect(await _decodeText('event: result\ndata: {"a":1}'), isEmpty);
      },
    );

    test('stops reading once the listener cancels', () async {
      final controller = StreamController<List<int>>();
      final first = decodeSse(controller.stream).first;
      controller.add(utf8.encode('event: step\ndata: {}\n\n'));
      expect(await first, const SseEvent('step', '{}'));
      // The source was cancelled: no listener is left on it.
      await pumpEventQueue();
      expect(controller.hasListener, isFalse);
    });
  });

  group('readTurnStream', () {
    test('hands session and step events on in order, then the result '
        'body', () async {
      final (end, progress) = await _read(
        [
          ': keepalive\n\n',
          _event('session', {
            'session': {'id': 's1', 'title': 'Untitled'},
          }),
          _event('step', {'step': 'playlists', 'playlist': 'Sunday Ríos'}),
          _event('step', {
            'step': 'digging',
            'scope': 'catalogue',
            'artists': ['Tems', 'Asake'],
          }),
          _event('step', {
            'step': 'checking',
            'genres': ['afrobeats', 'alté'],
          }),
          _event('step', {'step': 'pressing', 'count': 12}),
          _event('step', {'step': 'labelling', 'title': 'Lagos “late”'}),
          'event: result\ndata: {"djMessage":{}}\n\n',
        ].join(),
      );

      expect(progress, [
        const TurnSessionStarted('s1'),
        const TurnStep('playlists', playlist: 'Sunday Ríos'),
        const TurnStep(
          'digging',
          scope: 'catalogue',
          artists: ['Tems', 'Asake'],
        ),
        const TurnStep('checking', genres: ['afrobeats', 'alté']),
        const TurnStep('pressing', count: 12),
        const TurnStep('labelling', title: 'Lagos “late”'),
      ]);
      expect(end, isA<TurnStreamResult>());
      expect((end as TurnStreamResult).body, '{"djMessage":{}}');
    });

    test('answers at the result without waiting for the stream to '
        'close', () async {
      final controller = StreamController<List<int>>();
      final end = readTurnStream(controller.stream, (_) {});
      controller.add(utf8.encode('event: result\ndata: {}\n\n'));
      expect(await end, isA<TurnStreamResult>());
      await pumpEventQueue();
      expect(controller.hasListener, isFalse);
      await controller.close();
    });

    test('unknown events are ignored; an unknown step survives as a raw '
        'string', () async {
      final (end, progress) = await _read(
        [
          _event('mystery', {'step': 'digging'}),
          _event('step', {'step': 'tuning_the_reverb', 'scope': 'moon'}),
          'event: result\ndata: {}\n\n',
        ].join(),
      );
      expect(progress, [const TurnStep('tuning_the_reverb', scope: 'moon')]);
      expect(end, isA<TurnStreamResult>());
    });

    test('mistyped fields are dropped, never thrown', () async {
      final (_, progress) = await _read(
        [
          _event('step', {
            'step': 'pressing',
            'scope': 3,
            'artists': 'Tems',
            'genres': {'a': 1},
            'playlist': false,
            'title': 5,
            'count': '12',
          }),
          _event('step', {
            'step': 'digging',
            'artists': ['Tems', 3, null, '', '  ', 'Asake'],
            'genres': [1, 2],
            'count': 12.5,
          }),
          'event: result\ndata: {}\n\n',
        ].join(),
      );
      expect(progress, [
        const TurnStep('pressing'),
        const TurnStep('digging', artists: ['Tems', 'Asake']),
      ]);
    });

    test('a step or session event that does not parse is skipped', () async {
      final (end, progress) = await _read(
        [
          'event: step\ndata: not json\n\n',
          'event: step\ndata: [1,2]\n\n',
          _event('step', {'scope': 'library'}),
          _event('step', {'step': 7}),
          _event('session', {'session': 's1'}),
          _event('session', {
            'session': {'title': 'no id'},
          }),
          _event('session', {
            'session': {'id': ''},
          }),
          'event: session\ndata: {oops\n\n',
          'event: result\ndata: {}\n\n',
        ].join(),
      );
      expect(progress, isEmpty);
      expect(end, isA<TurnStreamResult>());
    });

    test('an error event carries the status and the body as JSON '
        'text', () async {
      final body = {
        'error': 'conflict',
        'message': 'Try again — the DJ was busy.',
      };
      final (end, _) = await _read(
        _event('error', {'status': 409, 'body': body}),
      );
      expect(end, isA<TurnStreamError>());
      end as TurnStreamError;
      expect(end.status, 409);
      expect(jsonDecode(end.body), body);
    });

    test('an error body that is a string passes through as it is', () async {
      final (end, _) = await _read(
        _event('error', {'status': 500, 'body': 'plain words'}),
      );
      end as TurnStreamError;
      expect(end.status, 500);
      expect(end.body, 'plain words');
    });

    test('an error event without a status is malformed', () async {
      for (final data in [
        jsonEncode({
          'body': {'error': 'internal'},
        }),
        jsonEncode({'status': '500', 'body': {}}),
        'not json',
        '[]',
      ]) {
        final (end, _) = await _read('event: error\ndata: $data\n\n');
        expect(end, isA<TurnStreamMalformed>(), reason: data);
      }
    });

    test('a stream that ends without a result or error is a network '
        'failure', () async {
      final progress = <TurnProgress>[];
      await expectLater(
        readTurnStream(
          Stream.value(utf8.encode(_event('step', {'step': 'picking'}))),
          progress.add,
        ),
        throwsA(isA<NetworkException>()),
      );
      expect(progress, [const TurnStep('picking')]);
    });

    test('a result cut off before its blank line is a network '
        'failure', () async {
      await expectLater(
        readTurnStream(
          Stream.value(utf8.encode('event: result\ndata: {"djMess')),
          (_) {},
        ),
        throwsA(isA<NetworkException>()),
      );
    });

    test('an error from the byte stream passes through', () async {
      final controller = StreamController<List<int>>();
      final end = readTurnStream(controller.stream, (_) {});
      controller.addError(NetworkException('socket closed'));
      await expectLater(end, throwsA(isA<NetworkException>()));
      await controller.close();
    });
  });

  group('TurnProgress', () {
    test('TurnStep compares by value, lists included', () {
      expect(
        const TurnStep('digging', artists: ['Tems']),
        TurnStep('digging', artists: ['Tems'].toList()),
      );
      expect(
        const TurnStep('digging', artists: ['Tems']).hashCode,
        TurnStep('digging', artists: ['Tems'].toList()).hashCode,
      );
      expect(
        const TurnStep('digging', artists: ['Tems']),
        isNot(const TurnStep('digging', artists: ['Asake'])),
      );
      expect(
        const TurnStep('digging'),
        isNot(const TurnStep('digging', scope: 'library')),
      );
    });

    test('TurnStreamOpened and TurnSessionStarted compare by value', () {
      // ignore: prefer_const_constructors
      expect(TurnStreamOpened(), const TurnStreamOpened());
      // ignore: prefer_const_constructors
      expect(TurnSessionStarted('s1'), const TurnSessionStarted('s1'));
      expect(
        const TurnSessionStarted('s1'),
        isNot(const TurnSessionStarted('s2')),
      );
    });
  });
}
