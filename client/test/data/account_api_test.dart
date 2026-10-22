import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/account_api.dart';
import 'package:mixtape/data/auth/token_store.dart';

const accountJson = {
  'id': 'account-row',
  'accountId': 'provider-subject',
  'providerId': 'apple',
};

void main() {
  late InMemoryTokenStore store;
  setUp(() async {
    store = InMemoryTokenStore();
    await store.write('existing-session');
  });

  AccountApi apiWith(Future<http.Response> Function(http.Request) handler) =>
      AccountApi(
        ApiClient(
          baseUrl: 'https://example.test',
          tokenStore: store,
          inner: MockClient((request) async {
            expect(request.headers['Authorization'], 'Bearer existing-session');
            return handler(request);
          }),
        ),
      );

  test(
    'lists immutable account identities without retaining extra fields',
    () async {
      final api = apiWith((request) async {
        expect(request.method, 'GET');
        expect(request.url.path, '/api/auth/list-accounts');
        return http.Response(
          jsonEncode([
            {...accountJson, 'userId': 'user'},
          ]),
          200,
        );
      });
      final accounts = await api.list();
      expect(accounts.single.id, 'account-row');
      expect(accounts.single.accountId, 'provider-subject');
      expect(accounts.single.providerId, 'apple');
      expect(() => accounts.clear(), throwsUnsupportedError);
    },
  );

  test(
    'explicit linking preserves the session and never calls sign-in',
    () async {
      var calls = 0;
      final api = apiWith((request) async {
        calls++;
        expect(request.method, 'POST');
        expect(request.url.path, '/api/auth/link-social');
        expect(jsonDecode(request.body), {
          'provider': 'google',
          'idToken': {'token': 'identity-token'},
        });
        return http.Response(
          '{"status":true,"redirect":false,"url":""}',
          200,
          headers: {'set-auth-token': 'must-not-replace-session'},
        );
      });
      await api.link(provider: AccountProvider.google, token: 'identity-token');
      expect(calls, 1);
      expect(await store.read(), 'existing-session');
    },
  );

  test(
    'unlink uses the Better Auth row id, not the provider subject',
    () async {
      final api = apiWith((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/api/auth/unlink-account');
        expect(jsonDecode(request.body), {'accountId': 'account-row'});
        return http.Response('{"status":true}', 200);
      });
      await api.unlink(LinkedAccount.fromJson(accountJson));
      expect(await store.read(), 'existing-session');
    },
  );

  test(
    'canonical errors retain status and code without retrying or leaking text',
    () async {
      for (final entry in [
        (400, 'FAILED_TO_UNLINK_LAST_ACCOUNT'),
        (403, 'SESSION_NOT_FRESH'),
        (409, 'SOCIAL_ACCOUNT_ALREADY_LINKED'),
        (401, 'UNAUTHORIZED'),
      ]) {
        var calls = 0;
        final api = apiWith((_) async {
          calls++;
          return http.Response(
            jsonEncode({'code': entry.$2, 'message': 'private-sentinel'}),
            entry.$1,
          );
        });
        await expectLater(
          api.unlink(LinkedAccount.fromJson(accountJson)),
          throwsA(
            isA<AccountApiException>()
                .having((e) => e.statusCode, 'status', entry.$1)
                .having((e) => e.code, 'code', entry.$2)
                .having(
                  (e) => e.toString(),
                  'safe description',
                  isNot(contains('private-sentinel')),
                ),
          ),
        );
        expect(calls, 1);
        expect(await store.read(), 'existing-session');
      }
    },
  );

  test('non-JSON errors preserve HTTP status', () async {
    final api = apiWith((_) async => http.Response('private-sentinel', 401));
    await expectLater(
      api.list(),
      throwsA(
        isA<AccountApiException>()
            .having((e) => e.statusCode, 'status', 401)
            .having((e) => e.code, 'code', isNull)
            .having(
              (e) => e.toString(),
              'safe description',
              isNot(contains('private-sentinel')),
            ),
      ),
    );
  });

  test('malformed lists and account identifiers fail closed', () async {
    for (final body in [
      'not-json',
      '{}',
      '[null]',
      jsonEncode([
        {...accountJson, 'id': ''},
      ]),
      jsonEncode([
        {...accountJson, 'accountId': null},
      ]),
      jsonEncode([
        {...accountJson, 'providerId': 1},
      ]),
    ]) {
      final api = apiWith((_) async => http.Response(body, 200));
      await expectLater(api.list(), throwsA(isA<AccountModelException>()));
    }
  });

  test('link success must be direct and explicitly confirmed', () async {
    for (final body in [
      '{}',
      '{"status":false}',
      '{"status":true,"redirect":true,"url":"https://example.test"}',
    ]) {
      final api = apiWith((_) async => http.Response(body, 200));
      await expectLater(
        api.link(provider: AccountProvider.apple, token: 'token'),
        throwsA(isA<AccountModelException>()),
      );
    }
  });

  test('unlink success must be explicitly confirmed', () async {
    final api = apiWith((_) async => http.Response('{}', 200));
    await expectLater(
      api.unlink(LinkedAccount.fromJson(accountJson)),
      throwsA(isA<AccountModelException>()),
    );
  });

  group('me', () {
    Future<Me> meWith(Object? body) => apiWith((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/me');
      return http.Response(jsonEncode(body), 200);
    }).me();

    test('name is trimmed; blank or absent is null', () async {
      Future<String?> name(Object? value) async => (await meWith({
            'user': {'id': 'u1', 'isAnonymous': false, 'name': value},
            'merged': null,
          })).name;
      expect(await name('  Noble  '), 'Noble');
      expect(await name('   '), isNull);
      expect(await name(null), isNull);
      expect(await name(7), isNull);
    });

    test('albumPicks reads the capability; absent or non-true is off', () async {
      final on = await meWith({
        'user': {'id': 'u1', 'isAnonymous': false},
        'merged': null,
        'albumPicks': true,
      });
      expect(on.albumPicks, isTrue);
      final off = await meWith({
        'user': {'id': 'u1', 'isAnonymous': false},
        'merged': null,
        'albumPicks': false,
      });
      expect(off.albumPicks, isFalse);
      final older = await meWith({
        'user': {'id': 'u1', 'isAnonymous': false},
        'merged': null,
      });
      expect(older.albumPicks, isFalse);
    });

    test('neverRefuse reads the flag; absent or non-true is off', () async {
      final on = await meWith({
        'user': {'id': 'u1', 'isAnonymous': true},
        'merged': null,
        'neverRefuse': true,
      });
      expect(on.neverRefuse, isTrue);
      final off = await meWith({
        'user': {'id': 'u1', 'isAnonymous': true},
        'merged': null,
        'neverRefuse': 'yes',
      });
      expect(off.neverRefuse, isFalse);
      final older = await meWith({
        'user': {'id': 'u1', 'isAnonymous': true},
        'merged': null,
      });
      expect(older.neverRefuse, isFalse);
      expect(const Me(id: 'u1', isAnonymous: false).neverRefuse, isFalse);
    });

    test('maps each merged value to MergedMode', () async {
      for (final entry in {
        'all': MergedMode.all,
        'mixes_only': MergedMode.mixesOnly,
        'library_kept': MergedMode.libraryKept,
      }.entries) {
        final me = await meWith({
          'user': {'id': 'u1', 'isAnonymous': false, 'name': 'Listener'},
          'merged': entry.key,
        });
        expect(me.merged, entry.value);
        expect(me.id, 'u1');
        expect(me.isAnonymous, isFalse);
      }
    });

    test('null or unknown merged is null; isAnonymous is read', () async {
      final none = await meWith({
        'user': {'id': 'anon', 'isAnonymous': true},
        'merged': null,
      });
      expect(none.merged, isNull);
      expect(none.isAnonymous, isTrue);
      final future = await meWith({
        'user': {'id': 'u1', 'isAnonymous': false},
        'merged': 'something_new',
      });
      expect(future.merged, isNull);
    });

    test('a body without a user is a model error', () async {
      await expectLater(
        meWith({'merged': null}),
        throwsA(isA<AccountModelException>()),
      );
    });
  });
}
