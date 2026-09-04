// The other way into the import flow: a listener taps a Spotify export ZIP
// in Files or Mail and picks Mixtape. iOS hands the file to
// `AppDelegate.application(_:open:options:)`, which copies it into our own
// temporary directory and pushes `{path, name, size}` over this channel.
// Screens depend on the interface (via `openedArchiveSourceProvider`) so
// tests never touch the channel.
import 'dart:async';

import 'package:flutter/services.dart';

import 'archive_picker.dart';

abstract class OpenedArchiveSource {
  /// Files opened while the app is running and someone is listening.
  Stream<PickedArchive> get opened;

  /// The archive a launch (or a stretch with nobody listening) left waiting,
  /// handed over exactly once: a second ask gets nothing.
  Future<PickedArchive?> takePending();
}

/// [OpenedArchiveSource] over the `mixtape/open-archive` channel.
///
/// The native side buffers the last opened archive and clears that buffer
/// only when this handler answers `true`, so the two paths never deliver the
/// same file twice and never lose one:
///  * cold start — the open lands before Dart is up, so [takePending] asks
///    for it;
///  * running, someone listening — it arrives on [opened];
///  * running, nobody listening (signed out) — it is held here until the
///    next [takePending], which is what the sign-in does.
class MethodChannelOpenedArchiveSource implements OpenedArchiveSource {
  MethodChannelOpenedArchiveSource() {
    _channel.setMethodCallHandler(_handle);
  }

  static const MethodChannel _channel = MethodChannel('mixtape/open-archive');

  final StreamController<PickedArchive> _opened = StreamController<PickedArchive>.broadcast();
  PickedArchive? _held;

  @override
  Stream<PickedArchive> get opened => _opened.stream;

  @override
  Future<PickedArchive?> takePending() async {
    final held = _held;
    if (held != null) {
      _held = null;
      return held;
    }
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('getPendingArchive');
      return _archive(raw);
    } catch (_) {
      // Nothing waiting is the normal answer; a channel that cannot say is
      // the same thing as far as the flow is concerned.
      return null;
    }
  }

  Future<dynamic> _handle(MethodCall call) async {
    if (call.method != 'onOpenedArchive') return null;
    final archive = _archive(call.arguments as Map<dynamic, dynamic>?);
    if (archive == null) return false;
    if (_opened.hasListener) {
      _opened.add(archive);
    } else {
      _held = archive;
    }
    // Taken: the native side drops its copy of it.
    return true;
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    _opened.close();
  }

  static PickedArchive? _archive(Map<dynamic, dynamic>? raw) {
    if (raw == null) return null;
    final path = raw['path'];
    final name = raw['name'];
    if (path is! String || path.isEmpty || name is! String || name.isEmpty) return null;
    final size = raw['size'];
    return PickedArchive(path: path, name: name, bytes: size is int ? size : 0);
  }
}
