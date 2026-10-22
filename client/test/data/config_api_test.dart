import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/config/config_api.dart';

void main() {
  ConfigApi apiWith(Future<http.Response> Function(http.Request) handler) =>
      ConfigApi(
        ApiClient(
          baseUrl: 'https://example.test',
          tokenStore: InMemoryTokenStore(),
          inner: MockClient(handler),
        ),
      );

  test('flags GETs /health without a session and maps neverRefuse', () async {
    late http.Request seen;
    final flags = await apiWith((request) async {
      seen = request;
      return http.Response(
        '{"ok":true,"service":"mixtape-api","neverRefuse":true}',
        200,
      );
    }).flags();
    expect(seen.method, 'GET');
    expect(seen.url.path, '/health');
    expect(seen.headers.containsKey('Authorization'), isFalse);
    expect(flags.neverRefuse, isTrue);
  });

  test('absent or non-true neverRefuse is off', () async {
    for (final body in [
      '{"ok":true,"service":"mixtape-api"}',
      '{"ok":true,"neverRefuse":false}',
      '{"ok":true,"neverRefuse":1}',
    ]) {
      final flags = await apiWith(
        (_) async => http.Response(body, 200),
      ).flags();
      expect(flags.neverRefuse, isFalse, reason: body);
    }
  });

  test(
    'a 404, a server error, a bad body or no network reads as off',
    () async {
      final failures = <Future<http.Response> Function(http.Request)>[
        (_) async => http.Response('Not Found', 404),
        (_) async => http.Response('boom', 500),
        (_) async => http.Response('not json', 200),
        (_) async => http.Response('[true]', 200),
        (_) async => throw http.ClientException('offline'),
      ];
      for (final handler in failures) {
        expect((await apiWith(handler).flags()).neverRefuse, isFalse);
      }
    },
  );
}
