/// Which of three things went wrong when something failed to load, so the
/// error copy can say it (founder, 2026-11-15).
library;

import 'api_client.dart';

enum FailureKind {
  /// The phone has no internet.
  offline,

  /// The internet works but Mixtape's server did not answer: a timeout, a
  /// refused or reset connection, a TLS failure, or a gateway response.
  unreachable,

  /// Anything else: a server error, a bad answer, a bug.
  other,
}

FailureKind failureKindOf(Object? error) => switch (error) {
  NetworkException(isOffline: true) => FailureKind.offline,
  NetworkException() => FailureKind.unreachable,
  ApiException(statusCode: 502 || 503 || 504) => FailureKind.unreachable,
  _ => FailureKind.other,
};
