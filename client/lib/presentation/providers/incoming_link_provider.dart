// Universal links (spec 2026-11-13 shared-mixes → Platform pieces, iOS;
// Recipient in the app). A share link (`<share base>/m/<token>`) that opens
// the app, on a cold start or while it runs, becomes [pendingSharedMixProvider]
// until the root ([SharedMixLinkListener] in the shell and the first-run flow)
// opens it. Every other link is ignored.
//
// Not user-scoped: a link belongs to the device, and must open before any
// session exists (a fresh install that has not been through first run).
import 'dart:async';
import 'dart:io' show Platform;

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/share/share_link.dart';
import '../screens/shared_mix_screen.dart';

/// Where links that open the app come from. Tests use a fake, so no test
/// touches the `app_links` channels.
abstract class IncomingLinkSource {
  /// The link the app was launched with, if any.
  Future<Uri?> initialLink();

  /// Links that open the app while it runs.
  Stream<Uri> get links;
}

/// [IncomingLinkSource] over the `app_links` plugin.
///
/// On iOS the plugin also replays the launch link to the stream's first
/// listener; [PendingSharedMixNotifier] delivers that link once.
class AppLinksIncomingLinkSource implements IncomingLinkSource {
  final AppLinks _appLinks = AppLinks();

  @override
  Future<Uri?> initialLink() => _appLinks.getInitialLink();

  @override
  Stream<Uri> get links => _appLinks.uriLinkStream;
}

/// No links at all: anywhere but an iOS device or simulator (the test VM
/// included, where the plugin's channels have no handler and an unanswered
/// event channel reports a Flutter error).
class NoIncomingLinks implements IncomingLinkSource {
  const NoIncomingLinks();

  @override
  Future<Uri?> initialLink() async => null;

  @override
  Stream<Uri> get links => const Stream<Uri>.empty();
}

final incomingLinkSourceProvider = Provider<IncomingLinkSource>(
  (ref) =>
      Platform.isIOS ? AppLinksIncomingLinkSource() : const NoIncomingLinks(),
);

/// The token of a shared mix a link opened, waiting for the root to show it.
class PendingSharedMixNotifier extends Notifier<String?> {
  /// The launch link, once `initialLink` has answered.
  Uri? _launchLink;
  bool _launchAnswered = false;

  /// The first link the stream delivered, which on iOS may be the launch
  /// link replayed.
  Uri? _firstStreamed;
  bool _streamStarted = false;

  @override
  String? build() {
    final source = ref.watch(incomingLinkSourceProvider);
    final subscription = source.links.listen(
      _streamed,
      // A broken channel is no reason to bother the listener.
      onError: (Object _) {},
    );
    ref.onDispose(subscription.cancel);
    unawaited(_readLaunchLink(source));
    return null;
  }

  Future<void> _readLaunchLink(IncomingLinkSource source) async {
    Uri? uri;
    try {
      uri = await source.initialLink();
    } catch (_) {
      return;
    }
    if (!ref.mounted) return;
    _launchAnswered = true;
    _launchLink = uri;
    // The stream got there first with the same link.
    if (uri == null || uri == _firstStreamed) return;
    _offer(uri);
  }

  void _streamed(Uri uri) {
    if (!_streamStarted) {
      _streamStarted = true;
      _firstStreamed = uri;
      // The launch link replayed to the first listener: already offered.
      if (_launchAnswered && uri == _launchLink) return;
    }
    _offer(uri);
  }

  void _offer(Uri uri) {
    final token = shareTokenFrom(uri);
    if (token != null) state = token;
  }

  /// Hands the pending token over and clears it, so it opens once. A later
  /// arrival of the same link is pending again.
  String? consume() {
    final token = state;
    state = null;
    return token;
  }
}

final pendingSharedMixProvider =
    NotifierProvider<PendingSharedMixNotifier, String?>(
      PendingSharedMixNotifier.new,
    );

/// Opens the shared mix [token] on [navigator], which its host chose
/// ([SharedMixLinkListener.navigator]).
typedef SharedMixPresenter =
    void Function(NavigatorState navigator, String token);

/// Pushes the read-only [SharedMixScreen] (spec 2026-11-13 shared-mixes): in
/// the shell on the selected tab's navigator, so the dock steps aside as for
/// any route inside a tab and the screen's own pushes (the owner's
/// conversation, Now Playing) stay in that tab; in first run on the root
/// navigator. Tests override it to observe the call.
final sharedMixPresenterProvider = Provider<SharedMixPresenter>(
  (ref) => (navigator, token) {
    navigator.push(
      MaterialPageRoute<void>(builder: (_) => SharedMixScreen(token: token)),
    );
  },
);
