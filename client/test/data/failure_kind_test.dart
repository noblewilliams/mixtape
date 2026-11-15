// Three kinds of load failure, so the error copy can say which one happened
// (founder, 2026-11-15): the device is offline, Mixtape's server cannot be
// reached, or something else went wrong. A timeout or a DNS failure cannot
// tell the first two apart on its own, so ApiClient asks the reachability
// probe before it says "offline".
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/api/failure_kind.dart';
import 'package:mixtape/data/auth/token_store.dart';

void main() {
  group('failureKindOf', () {
    test('no route to the internet is offline', () {
      for (final message in [
        'Failed host lookup: api.example.com',
        'Connection failed (OS Error: Network is unreachable, errno = 51)',
        'Network is down',
        'No route to host',
      ]) {
        expect(
          failureKindOf(NetworkException(http.ClientException(message))),
          FailureKind.offline,
          reason: message,
        );
      }
      expect(
        failureKindOf(
          NetworkException(const SocketException('Failed host lookup: x')),
        ),
        FailureKind.offline,
      );
    });

    test('a timeout, a refusal or a reset is the server not answering', () {
      for (final cause in <Object>[
        TimeoutException('slow'),
        http.ClientException('Connection refused'),
        http.ClientException('Connection reset by peer'),
        const HandshakeException('bad certificate'),
      ]) {
        expect(
          failureKindOf(NetworkException(cause)),
          FailureKind.unreachable,
          reason: '$cause',
        );
      }
    });

    test('a gateway or unavailable response is the server not answering', () {
      for (final status in [502, 503, 504]) {
        expect(
          failureKindOf(ApiException(status, '')),
          FailureKind.unreachable,
        );
      }
    });

    test('anything else is other', () {
      expect(failureKindOf(ApiException(500, 'boom')), FailureKind.other);
      expect(failureKindOf(ApiException(404, '')), FailureKind.other);
      expect(failureKindOf(StateError('parse')), FailureKind.other);
      expect(failureKindOf(null), FailureKind.other);
    });

    test('a probe verdict overrides the message', () {
      final dns = http.ClientException('Failed host lookup: x');
      expect(
        failureKindOf(NetworkException(dns, offline: false)),
        FailureKind.unreachable,
      );
      expect(
        failureKindOf(NetworkException(TimeoutException('t'), offline: true)),
        FailureKind.offline,
      );
    });
  });

  group('ApiClient settles ambiguous failures with the probe', () {
    tearDown(() => ApiClient.reachabilityProbe = null);

    Future<NetworkException> failure(
      Future<http.Response> Function() respond, {
      Duration timeout = const Duration(seconds: 30),
    }) async {
      final client = ApiClient(
        baseUrl: 'http://x',
        tokenStore: InMemoryTokenStore(),
        inner: MockClient((_) => respond()),
        timeout: timeout,
      );
      try {
        await client.getJson('/anything');
      } on NetworkException catch (e) {
        return e;
      }
      fail('expected a NetworkException');
    }

    test('a DNS failure while the internet answers is unreachable', () async {
      var probes = 0;
      ApiClient.reachabilityProbe = () async {
        probes++;
        return true;
      };
      final e = await failure(
        () async => throw http.ClientException('Failed host lookup: x'),
      );
      expect(probes, 1);
      expect(failureKindOf(e), FailureKind.unreachable);
    });

    test('a timeout with no internet is offline', () async {
      ApiClient.reachabilityProbe = () async => false;
      final e = await failure(
        () => Completer<http.Response>().future,
        timeout: const Duration(milliseconds: 10),
      );
      expect(failureKindOf(e), FailureKind.offline);
    });

    test('a refusal needs no probe', () async {
      var probes = 0;
      ApiClient.reachabilityProbe = () async {
        probes++;
        return false;
      };
      final e = await failure(
        () async => throw http.ClientException('Connection refused'),
      );
      expect(probes, 0);
      expect(failureKindOf(e), FailureKind.unreachable);
    });

    test('a probe that throws leaves the message to decide', () async {
      ApiClient.reachabilityProbe = () async => throw StateError('probe');
      final e = await failure(
        () async => throw http.ClientException('Failed host lookup: x'),
      );
      expect(failureKindOf(e), FailureKind.offline);
    });

    test('without a probe the message decides', () async {
      final e = await failure(
        () async => throw http.ClientException('Failed host lookup: x'),
      );
      expect(failureKindOf(e), FailureKind.offline);
    });
  });
}
