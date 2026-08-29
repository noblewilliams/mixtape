import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';

void main() {
  test('attaches bearer token when present', () async {
    String? seenAuth;
    final inner = MockClient((req) async {
      seenAuth = req.headers['Authorization'];
      return http.Response('{}', 200);
    });
    final store = InMemoryTokenStore();
    await store.write('tok-123');
    final client = ApiClient(baseUrl: 'http://x', tokenStore: store, inner: inner);

    await client.postJson('/ingest/library', {'songs': []});
    expect(seenAuth, 'Bearer tok-123');
  });

  test('omits header when signed out', () async {
    String? seenAuth = 'sentinel';
    final inner = MockClient((req) async {
      seenAuth = req.headers['Authorization'];
      return http.Response('{}', 200);
    });
    final client =
        ApiClient(baseUrl: 'http://x', tokenStore: InMemoryTokenStore(), inner: inner);

    await client.postJson('/anything', {});
    expect(seenAuth, isNull);
  });

  test('throws ApiException with status on 4xx/5xx', () async {
    final client = ApiClient(
      baseUrl: 'http://x',
      tokenStore: InMemoryTokenStore(),
      inner: MockClient((_) async => http.Response('{"error":"unauthorized"}', 401)),
    );
    await expectLater(
      client.getJson('/me'),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401)),
    );
  });
}
