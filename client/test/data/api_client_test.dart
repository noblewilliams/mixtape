import 'dart:convert';

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

  test('content-type set on POST but absent on GET', () async {
    String? postContentType = 'unset';
    String? getContentType = 'unset';
    final inner = MockClient((req) async {
      if (req.method == 'POST') {
        postContentType = req.headers['content-type'];
      } else {
        getContentType = req.headers['content-type'];
      }
      return http.Response('{}', 200);
    });
    final client =
        ApiClient(baseUrl: 'http://x', tokenStore: InMemoryTokenStore(), inner: inner);

    await client.postJson('/a', {'x': 1});
    await client.getJson('/b');

    expect(postContentType, 'application/json');
    expect(getContentType, isNull);
  });

  test('POST body is real JSON', () async {
    Map<String, dynamic>? decoded;
    final inner = MockClient((req) async {
      decoded = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response('{}', 200);
    });
    final client =
        ApiClient(baseUrl: 'http://x', tokenStore: InMemoryTokenStore(), inner: inner);

    await client.postJson('/ingest/library', {'songs': ['a', 'b']});

    expect(decoded, {'songs': ['a', 'b']});
  });

  test('URL is composed from base + path', () async {
    Uri? seenUrl;
    final inner = MockClient((req) async {
      seenUrl = req.url;
      return http.Response('{}', 200);
    });
    final client = ApiClient(
        baseUrl: 'http://example.com', tokenStore: InMemoryTokenStore(), inner: inner);

    await client.getJson('/ingest/library');

    expect(seenUrl.toString(), 'http://example.com/ingest/library');
  });

  test('2xx response is returned with headers readable by the caller', () async {
    final inner = MockClient((req) async {
      return http.Response('{"ok":true}', 200,
          headers: {'set-auth-token': 'new-tok-456'});
    });
    final client =
        ApiClient(baseUrl: 'http://x', tokenStore: InMemoryTokenStore(), inner: inner);

    final res = await client.getJson('/me');

    expect(res.headers['set-auth-token'], 'new-tok-456');
    expect(res.body, '{"ok":true}');
  });

  test('ApiException.body carries the payload', () async {
    final client = ApiClient(
      baseUrl: 'http://x',
      tokenStore: InMemoryTokenStore(),
      inner: MockClient((_) async => http.Response('{"error":"nope"}', 400)),
    );

    try {
      await client.getJson('/me');
      fail('expected ApiException');
    } on ApiException catch (e) {
      expect(e.body, '{"error":"nope"}');
    }
  });

  test('throws NetworkException when the transport throws http.ClientException', () async {
    final client = ApiClient(
      baseUrl: 'http://x',
      tokenStore: InMemoryTokenStore(),
      inner: MockClient((_) async => throw http.ClientException('boom')),
    );

    await expectLater(
      client.getJson('/me'),
      throwsA(isA<NetworkException>()),
    );
  });

  test('throws NetworkException on transport timeout', () async {
    final client = ApiClient(
      baseUrl: 'http://x',
      tokenStore: InMemoryTokenStore(),
      timeout: const Duration(milliseconds: 50),
      inner: MockClient((_) async {
        await Future.delayed(const Duration(milliseconds: 200));
        return http.Response('{}', 200);
      }),
    );

    await expectLater(
      client.getJson('/me'),
      throwsA(isA<NetworkException>()),
    );
  });

  test('patchJson sends PATCH with bearer + json body, throws on 4xx/5xx', () async {
    String? seenMethod;
    String? seenContentType;
    Map<String, dynamic>? decoded;
    final inner = MockClient((req) async {
      seenMethod = req.method;
      seenContentType = req.headers['content-type'];
      decoded = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response('{"ok":true}', 200);
    });
    final store = InMemoryTokenStore();
    await store.write('tok-999');
    final client = ApiClient(baseUrl: 'http://x', tokenStore: store, inner: inner);

    final res = await client.patchJson('/sessions/abc', {'status': 'archived'});

    expect(seenMethod, 'PATCH');
    expect(seenContentType, 'application/json');
    expect(decoded, {'status': 'archived'});
    expect(res.body, '{"ok":true}');

    final failing = ApiClient(
      baseUrl: 'http://x',
      tokenStore: InMemoryTokenStore(),
      inner: MockClient((_) async => http.Response('{"error":"nope"}', 409)),
    );
    await expectLater(
      failing.patchJson('/sessions/abc', {'status': 'archived'}),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 409)),
    );
  });

  test('deleteJson sends DELETE with bearer, no body, throws on 4xx/5xx', () async {
    String? seenMethod;
    String? seenAuth;
    final inner = MockClient((req) async {
      seenMethod = req.method;
      seenAuth = req.headers['Authorization'];
      return http.Response('{"ok":true}', 200);
    });
    final store = InMemoryTokenStore();
    await store.write('tok-777');
    final client = ApiClient(baseUrl: 'http://x', tokenStore: store, inner: inner);

    final res = await client.deleteJson('/me/memories/m1');

    expect(seenMethod, 'DELETE');
    expect(seenAuth, 'Bearer tok-777');
    expect(res.body, '{"ok":true}');

    final failing = ApiClient(
      baseUrl: 'http://x',
      tokenStore: InMemoryTokenStore(),
      inner: MockClient((_) async => http.Response('{"error":"not_found"}', 404)),
    );
    await expectLater(
      failing.deleteJson('/me/memories/m1'),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404)),
    );
  });

  test('InMemoryTokenStore write -> read -> clear -> read round-trip', () async {
    final store = InMemoryTokenStore();
    expect(await store.read(), isNull);

    await store.write('tok-abc');
    expect(await store.read(), 'tok-abc');

    await store.clear();
    expect(await store.read(), isNull);
  });
}
