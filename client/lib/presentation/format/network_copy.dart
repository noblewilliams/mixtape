/// What a failed call to the DJ says, told apart as the phone being offline
/// or the DJ not answering (founder, 2026-11-15: "if it's because the user
/// isn't connected to the internet, the error should say that" — and only
/// then). The classification is [NetworkException.isOffline], the same one
/// the load-error states use.
library;

import '../../data/api/api_client.dart';

abstract final class NetworkCopy {
  /// The chat's own lowercase register (bubbles, Home's start, interview).
  static const String djOffline =
      'you’re offline — check your connection and try again';
  static const String djUnreachable =
      'couldn’t reach the DJ — try again in a moment';

  /// Sentence case, no em dashes (first run, playlist edits).
  static const String offline =
      'You’re offline. Check your connection and try again.';
  static const String unreachable =
      'Couldn’t reach the DJ. Try again in a moment.';
}

String djNetworkMessage(NetworkException error) =>
    error.isOffline ? NetworkCopy.djOffline : NetworkCopy.djUnreachable;

String sentenceNetworkMessage(NetworkException error) =>
    error.isOffline ? NetworkCopy.offline : NetworkCopy.unreachable;
