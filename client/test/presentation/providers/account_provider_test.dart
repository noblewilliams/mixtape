import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/account_api.dart';
import 'package:mixtape/data/auth/apple_auth_gateway.dart';
import 'package:mixtape/presentation/providers/account_provider.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'dj_providers_test.dart' show TestAuthNotifier;

class FakeAccountApi implements AccountApi {
  Future<List<LinkedAccount>> Function() onList = () async => [];
  Future<void> Function(AccountProvider, String) onLink = (_, _) async {};
  Future<void> Function(LinkedAccount) onUnlink = (_) async {};
  int links = 0;
  int unlinks = 0;
  @override
  Future<List<LinkedAccount>> list() => onList();
  @override
  Future<void> link({
    required AccountProvider provider,
    required String token,
  }) {
    links++;
    return onLink(provider, token);
  }

  @override
  Future<void> unlink(LinkedAccount account) {
    unlinks++;
    return onUnlink(account);
  }
}

const apple = LinkedAccount(
  id: 'apple-row',
  accountId: 'apple-subject',
  providerId: 'apple',
);
const google = LinkedAccount(
  id: 'google-row',
  accountId: 'google-subject',
  providerId: 'google',
);
Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeAccountApi api;
  late TestAuthNotifier auth;
  late ProviderContainer container;
  setUp(() {
    api = FakeAccountApi()..onList = () async => [apple];
    auth = TestAuthNotifier(AuthStatus.signedIn);
    container = ProviderContainer(
      overrides: [
        accountApiProvider.overrideWithValue(api),
        accountIdentityTokenProvider.overrideWithValue(
          (_) async => 'identity-token',
        ),
        authProvider.overrideWith(() => auth),
      ],
    );
    container.listen(accountProvider, (_, _) {});
  });
  tearDown(() => container.dispose());

  test('lost link response reconciles canonical methods', () async {
    await flush();
    api.onLink = (_, _) async {
      throw StateError('lost response');
    };
    api.onList = () async => [apple, google];
    expect(
      await container
          .read(accountProvider.notifier)
          .link(AccountProvider.google),
      isTrue,
    );
    expect(container.read(accountProvider).accounts, [apple, google]);
  });
  test('final login method cannot be unlinked', () async {
    await flush();
    expect(
      await container.read(accountProvider.notifier).unlink('apple-row'),
      isFalse,
    );
    expect(api.unlinks, 0);
  });
  test(
    'unknown mutation outcome blocks writes until canonical reload',
    () async {
      await flush();
      api.onList = () async => throw StateError('offline');
      final notifier = container.read(accountProvider.notifier);
      expect(await notifier.link(AccountProvider.google), isFalse);
      expect(container.read(accountProvider).accounts, isNull);
      expect(await notifier.link(AccountProvider.google), isFalse);
      expect(api.links, 1);
      api.onList = () async => [apple, google];
      expect(await notifier.refresh(), isTrue);
      expect(container.read(accountProvider).canModify, isTrue);
    },
  );
  test(
    'provider authentication serializes writes and ignores account changes',
    () async {
      final token = Completer<String>();
      container.updateOverrides([
        accountApiProvider.overrideWithValue(api),
        accountIdentityTokenProvider.overrideWithValue((_) => token.future),
        authProvider.overrideWith(() => auth),
      ]);
      await flush();
      final notifier = container.read(accountProvider.notifier);
      final link = notifier.link(AccountProvider.google);
      expect(await notifier.link(AccountProvider.google), isFalse);
      auth.set(AuthStatus.signedOut);
      await flush();
      token.complete('old-account-token');
      expect(await link, isFalse);
      expect(api.links, 0);
      expect(container.read(accountProvider).accounts, isNull);
    },
  );
  test('unlink adopts canonical methods after an uncertain response', () async {
    api.onList = () async => [apple, google];
    await container.read(accountProvider.notifier).refresh();
    api.onUnlink = (account) async {
      expect(account.id, 'google-row');
      throw StateError('lost response');
    };
    api.onList = () async => [apple];
    expect(
      await container.read(accountProvider.notifier).unlink('google-row'),
      isTrue,
    );
    expect(container.read(accountProvider).accounts, [apple]);
  });
  test(
    'native cancellation never links or changes canonical methods',
    () async {
      container.updateOverrides([
        accountApiProvider.overrideWithValue(api),
        accountIdentityTokenProvider.overrideWithValue(
          (_) async => throw AppleSignInCancelled(),
        ),
        authProvider.overrideWith(() => auth),
      ]);
      await flush();
      expect(
        await container
            .read(accountProvider.notifier)
            .link(AccountProvider.google),
        isFalse,
      );
      expect(api.links, 0);
      expect(container.read(accountProvider).accounts, [apple]);
      expect(container.read(accountProvider).error, isNull);
      expect(container.read(accountProvider).canModify, isTrue);
    },
  );
  test(
    '401 stays visible and clears actionable methods without another read',
    () async {
      await flush();
      final unauthorized = AccountApiException(
        401,
        'unauthorized',
        'unauthorized',
      );
      api.onLink = (_, _) async => throw unauthorized;
      api.onList = () async => throw StateError('must not read');
      expect(
        await container
            .read(accountProvider.notifier)
            .link(AccountProvider.google),
        isFalse,
      );
      expect(container.read(accountProvider).error, same(unauthorized));
      expect(container.read(accountProvider).accounts, isNull);
    },
  );
  test(
    'server final-method rejection retains error and canonical methods',
    () async {
      api.onList = () async => [apple, google];
      await container.read(accountProvider.notifier).refresh();
      final rejected = AccountApiException(400, 'rejected', 'last_account');
      api.onUnlink = (_) async => throw rejected;
      api.onList = () async => [google];
      expect(
        await container.read(accountProvider.notifier).unlink('google-row'),
        isFalse,
      );
      expect(container.read(accountProvider).accounts, [google]);
      expect(container.read(accountProvider).error, same(rejected));
    },
  );
  test(
    'late canonical read after account change cannot expose old methods',
    () async {
      await flush();
      final oldRead = Completer<List<LinkedAccount>>();
      api.onList = () => oldRead.future;
      final refresh = container.read(accountProvider.notifier).refresh();
      auth.set(AuthStatus.signedOut);
      await flush();
      oldRead.complete([apple, google]);
      expect(await refresh, isFalse);
      expect(container.read(accountProvider).accounts, isNull);
    },
  );
  test('captured notifier rejects calls after disposal', () async {
    await flush();
    final notifier = container.read(accountProvider.notifier);
    container.dispose();
    // Give tearDown a fresh container rather than disposing the same one twice.
    container = ProviderContainer();
    expect(await notifier.link(AccountProvider.google), isFalse);
    expect(await notifier.unlink('apple-row'), isFalse);
    expect(await notifier.refresh(), isFalse);
    expect(api.links, 0);
    expect(api.unlinks, 0);
  });
}
