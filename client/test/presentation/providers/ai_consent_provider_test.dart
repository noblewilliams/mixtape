// The AI-consent state (plan `2026-11-02-ai-consent-and-privacy.md`):
// derived from the one `/me` reader, reset on every auth transition, with a
// grant that records the answer and a Not now that lasts for the launch.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/presentation/providers/account_provider.dart';
import 'package:mixtape/presentation/providers/ai_consent_provider.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/capabilities_provider.dart';

import '../../helpers/fake_ai_consent.dart';

class _TestAuth extends AuthNotifier {
  _TestAuth(this._initial);
  final AuthStatus _initial;

  @override
  AuthStatus build() => _initial;

  void set(AuthStatus status) {
    if (state == status) {
      ref.notifyListeners();
    } else {
      state = status;
    }
  }
}

({ProviderContainer container, _TestAuth auth, FakeConsentAccountApi api})
_make({AuthStatus status = AuthStatus.session, bool aiConsent = false}) {
  final auth = _TestAuth(status);
  final api = FakeConsentAccountApi(aiConsent: aiConsent);
  final container = ProviderContainer(
    overrides: [
      tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      authProvider.overrideWith(() => auth),
      accountApiProvider.overrideWithValue(api),
    ],
  );
  addTearDown(container.dispose);
  container.listen(aiConsentNeededProvider, (_, _) {});
  container.listen(aiConsentProvider, (_, _) {});
  return (container: container, auth: auth, api: api);
}

Future<void> _settle(ProviderContainer container) async {
  try {
    await container.read(meProvider.future);
  } catch (_) {}
  for (var i = 0; i < 3; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('aiConsentNeededProvider', () {
    test('true when /me says false', () async {
      final h = _make();
      await _settle(h.container);
      expect(h.container.read(aiConsentNeededProvider), isTrue);
    });

    test('false when /me says true, or before /me answers', () async {
      final h = _make(aiConsent: true);
      expect(h.container.read(aiConsentNeededProvider), isFalse);
      await _settle(h.container);
      expect(h.container.read(aiConsentNeededProvider), isFalse);
    });

    test('false without a session', () async {
      final h = _make(status: AuthStatus.noSession);
      await _settle(h.container);
      expect(h.container.read(aiConsentNeededProvider), isFalse);
      expect(h.api.meCalls, 0);
    });

    test('a grant clears it without another /me read', () async {
      final h = _make();
      await _settle(h.container);
      await h.container.read(aiConsentProvider.notifier).grant();
      expect(h.api.grants, 1);
      expect(h.container.read(aiConsentNeededProvider), isFalse);
      expect(h.container.read(aiConsentProvider).granted, isTrue);
    });
  });

  group('AiConsentNotifier', () {
    test('Not now lasts until the next auth transition', () async {
      final h = _make();
      await _settle(h.container);
      h.container.read(aiConsentProvider.notifier).dismiss();
      expect(h.container.read(aiConsentProvider).dismissed, isTrue);
      h.auth.set(AuthStatus.session); // e.g. the anonymous-to-account link
      await _settle(h.container);
      expect(h.container.read(aiConsentProvider).dismissed, isFalse);
    });

    test(
      'isRequired without a session asks only before the first one',
      () async {
        final h = _make(status: AuthStatus.noSession);
        final notifier = h.container.read(aiConsentProvider.notifier);
        expect(await notifier.isRequired(beforeSession: true), isTrue);
        expect(await notifier.isRequired(), isFalse);
      },
    );

    test('isRequired follows /me with a session', () async {
      final asks = _make();
      expect(
        await asks.container.read(aiConsentProvider.notifier).isRequired(),
        isTrue,
      );
      final given = _make(aiConsent: true);
      expect(
        await given.container.read(aiConsentProvider.notifier).isRequired(),
        isFalse,
      );
    });

    test('isRequired is false once granted', () async {
      final h = _make();
      await h.container.read(aiConsentProvider.notifier).grant();
      expect(
        await h.container.read(aiConsentProvider.notifier).isRequired(),
        isFalse,
      );
    });

    test('grant skips the POST when /me already says granted', () async {
      // An older Worker without the field reads as granted: nothing to post.
      final h = _make(aiConsent: true);
      await h.container.read(aiConsentProvider.notifier).grant();
      expect(h.api.grants, 0);
      expect(h.container.read(aiConsentProvider).granted, isTrue);
    });

    test('a server 403 marks it required even when /me said granted', () async {
      // A /me read that failed (or an older answer) under enforcement.
      final h = _make(aiConsent: true);
      await _settle(h.container);
      final notifier = h.container.read(aiConsentProvider.notifier);
      expect(await notifier.isRequired(), isFalse);

      notifier.markRequired();
      expect(await notifier.isRequired(), isTrue);
      // The shell's one-time sheet is not re-raised by it: the send that hit
      // the 403 shows the sheet itself.
      expect(h.container.read(aiConsentNeededProvider), isFalse);

      // A grant posts even though /me said true, and clears it.
      await notifier.grant();
      expect(h.api.grants, 1);
      expect(await notifier.isRequired(), isFalse);
    });

    test('a failed grant throws and records nothing', () async {
      final h = _make();
      h.api.failGrantWith = NetworkException('offline');
      await expectLater(
        h.container.read(aiConsentProvider.notifier).grant(),
        throwsA(isA<NetworkException>()),
      );
      expect(h.container.read(aiConsentProvider).granted, isFalse);
      await _settle(h.container);
      expect(h.container.read(aiConsentNeededProvider), isTrue);
    });
  });
}
