// C5: the archive a listener handed the app from Files or Mail, waiting for
// Home to open the import flow with it. User-scoped like every other
// provider that caches per-account state: an archive opened for one listener
// is dropped on the auth transition rather than surfacing for the next.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/files/archive_picker.dart';
import '../../data/files/opened_archive_channel.dart';
import 'auth_provider.dart';
import 'device_providers.dart';

class OpenedArchiveNotifier extends Notifier<PickedArchive?> {
  /// Bumped by every rebuild so a [takePending] still in flight for the
  /// previous listener cannot land on this one's state.
  int _generation = 0;

  @override
  PickedArchive? build() {
    _generation++;
    // Nothing is opened for a listener who is not there: while signed out
    // the archive stays with the source (the native buffer, or the Dart-side
    // hold), and the sign-in's rebuild takes it below.
    if (ref.watch(authProvider) != AuthStatus.signedIn) return null;
    final source = ref.watch(openedArchiveSourceProvider);
    final generation = _generation;
    final subscription = source.opened.listen((archive) {
      if (_current(generation)) state = archive;
    });
    ref.onDispose(subscription.cancel);
    unawaited(_takePending(source, generation));
    return null;
  }

  Future<void> _takePending(OpenedArchiveSource source, int generation) async {
    PickedArchive? pending;
    try {
      pending = await source.takePending();
    } catch (_) {
      return; // nothing to open is not a failure worth showing anyone
    }
    if (pending == null || !_current(generation)) return;
    // A file opened while this was in flight is the newer one; it wins.
    state ??= pending;
  }

  /// Home opened the flow with it. Consumed exactly once: reopening Home,
  /// or a later run ending, must not start the same import again.
  void consumed(PickedArchive archive) {
    if (state == archive) state = null;
  }

  bool _current(int generation) => ref.mounted && generation == _generation;
}

final openedArchiveProvider =
    NotifierProvider<OpenedArchiveNotifier, PickedArchive?>(OpenedArchiveNotifier.new);
