import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/presentation/format/network_copy.dart';
import 'package:mixtape/presentation/screens/first_run/first_run_flow.dart';

void main() {
  final offline = NetworkException(
    http.ClientException('Network is unreachable'),
  );
  final unreachable = NetworkException(
    TimeoutException('Future not completed'),
  );
  final refused = NetworkException(http.ClientException('Connection refused'));

  group('djNetworkMessage (the chat register)', () {
    test('says offline only when the phone is offline', () {
      expect(djNetworkMessage(offline), NetworkCopy.djOffline);
      expect(djNetworkMessage(offline), contains('offline'));
    });

    test('says the DJ did not answer otherwise, without blaming the '
        'connection', () {
      for (final e in [unreachable, refused]) {
        expect(djNetworkMessage(e), NetworkCopy.djUnreachable);
        expect(djNetworkMessage(e), isNot(contains('connection')));
      }
    });

    test('a probe verdict wins over the message', () {
      expect(
        djNetworkMessage(NetworkException(unreachable.cause, offline: true)),
        NetworkCopy.djOffline,
      );
    });
  });

  group('sentenceNetworkMessage (first run, playlist edits)', () {
    test('offline and unreachable read differently, with no em dashes', () {
      expect(sentenceNetworkMessage(offline), NetworkCopy.offline);
      expect(sentenceNetworkMessage(refused), NetworkCopy.unreachable);
      expect(NetworkCopy.offline, isNot(contains('—')));
      expect(NetworkCopy.unreachable, isNot(contains('—')));
    });
  });

  group('firstRunErrorFor', () {
    test('tells offline from unreachable', () {
      expect(firstRunErrorFor(offline), NetworkCopy.offline);
      expect(firstRunErrorFor(unreachable), NetworkCopy.unreachable);
    });

    test('a gateway answer is the server not answering, not a bug', () {
      expect(firstRunErrorFor(ApiException(503, '')), NetworkCopy.unreachable);
      expect(firstRunErrorFor(ApiException(500, '')), FirstRunErrors.generic);
    });
  });
}
