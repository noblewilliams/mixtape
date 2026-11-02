import 'dart:async';

import 'package:mixtape/data/auth/account_api.dart';
import 'package:mixtape/presentation/providers/ai_consent_provider.dart';

/// `/me` and `POST /me/ai-consent` only; anything else fails loudly.
class FakeConsentAccountApi implements AccountApi {
  FakeConsentAccountApi({this.aiConsent = false, this.anonymous = false});

  /// What `/me` says, until a grant succeeds.
  bool aiConsent;
  bool anonymous;
  int meCalls = 0;
  int grants = 0;

  /// Thrown by the next grants while set.
  Object? failGrantWith;

  /// Holds a grant open while set.
  Completer<void>? grantGate;

  @override
  Future<Me> me() async {
    meCalls++;
    return Me(id: 'u1', isAnonymous: anonymous, aiConsent: aiConsent);
  }

  @override
  Future<void> grantAiConsent() async {
    grants++;
    final gate = grantGate;
    if (gate != null) await gate.future;
    final failure = failGrantWith;
    if (failure != null) throw failure;
    aiConsent = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

/// Consent already given, whatever the session: for pages whose tests are
/// about something else.
class GrantedAiConsent extends AiConsentNotifier {
  @override
  AiConsentState build() => const AiConsentState(granted: true);
}
