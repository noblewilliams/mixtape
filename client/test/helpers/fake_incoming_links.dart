// A universal-link source and a shared-mix presenter the tests drive by
// hand, so no test touches the `app_links` channels or SharedMixScreen.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:mixtape/presentation/providers/incoming_link_provider.dart';

class FakeIncomingLinkSource implements IncomingLinkSource {
  FakeIncomingLinkSource({this.initial});

  /// The link the app was launched with, if any.
  Uri? initial;

  late final StreamController<Uri> _links = StreamController<Uri>(
    onListen: () => listens++,
    onCancel: () => cancels++,
  );
  int listens = 0;
  int cancels = 0;

  bool get listening => _links.hasListener;

  /// A link tapped while the app is running.
  void tap(Uri uri) => _links.add(uri);

  @override
  Future<Uri?> initialLink() async => initial;

  @override
  Stream<Uri> get links => _links.stream;
}

/// Records every presentation, and the navigator it would push on.
class RecordingSharedMixPresenter {
  final List<String> tokens = [];
  final List<NavigatorState?> rootNavigators = [];

  void call(BuildContext context, String token) {
    tokens.add(token);
    rootNavigators.add(Navigator.maybeOf(context, rootNavigator: true));
  }
}
