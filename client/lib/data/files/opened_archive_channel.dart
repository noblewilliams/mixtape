// The other way into the import flow: a listener taps a Spotify export ZIP
// in Files or Mail and picks Mixtape. iOS hands the file to
// `AppDelegate.application(_:open:options:)`, which copies it into our own
// temporary directory and pushes `{path, name, size}` over this channel (or
// `{error, name}` when it could not even be copied). Screens depend on the
// interface (via `openedArchiveSourceProvider`) so tests never touch the
// channel.
import 'dart:async';

import 'package:flutter/services.dart';

import 'archive_picker.dart';

/// A file the listener handed to the app. [archive] is the copy the app made
/// of it, and is null when the file could not be read at all: there is
/// nothing to parse then, only a [name] to say so with.
class HandedArchive {
  const HandedArchive({required this.name, this.archive});

  /// The listener's own file name, whether or not the copy succeeded.
  final String name;
  final PickedArchive? archive;

  bool get unreadable => archive == null;

  @override
  bool operator ==(Object other) =>
      other is HandedArchive && other.name == name && other.archive == archive;

  @override
  int get hashCode => Object.hash(name, archive);
}

abstract class OpenedArchiveSource {
  /// Files opened while the app is running and someone is listening.
  Stream<HandedArchive> get opened;

  /// The archive a launch (or a stretch with nobody listening) left waiting,
  /// handed over exactly once: a second ask gets nothing.
  Future<HandedArchive?> takePending();

  /// Deletes the copy the app made of [archive]. The copy is the listener's
  /// whole export — the identity and payment files the parser refuses to
  /// read included — so it goes as soon as the import is over.
  Future<void> discard(PickedArchive archive);
}

/// [OpenedArchiveSource] over the `mixtape/open-archive` channel.
///
/// The native side buffers the last opened archive and clears that buffer
/// only when this handler answers `true`, so the two paths never lose a
/// file:
///  * cold start — the open lands before Dart is up, so [takePending] asks
///    for it;
///  * running, someone listening — it arrives on [opened];
///  * running, nobody listening (signed out) — it is held here until the
///    next [takePending], which is what the sign-in does.
///
/// Neither may deliver the same file twice: the acknowledgement can still be
/// in flight when [takePending] asks, so the last hand-over is remembered
/// and an answer equal to it is dropped. Two real opens of the same file are
/// copied into different directories, so this can never swallow one.
class MethodChannelOpenedArchiveSource implements OpenedArchiveSource {
  MethodChannelOpenedArchiveSource() {
    _channel.setMethodCallHandler(_handle);
  }

  static const MethodChannel _channel = MethodChannel('mixtape/open-archive');

  final StreamController<HandedArchive> _opened = StreamController<HandedArchive>.broadcast();
  HandedArchive? _held;
  HandedArchive? _delivered;

  @override
  Stream<HandedArchive> get opened => _opened.stream;

  @override
  Future<HandedArchive?> takePending() async {
    final held = _held;
    if (held != null) {
      _held = null;
      return _deliver(held);
    }
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>('getPendingArchive');
      final pending = _handed(raw);
      if (pending == null || pending == _delivered) return null;
      return _deliver(pending);
    } catch (_) {
      // Nothing waiting is the normal answer; a channel that cannot say is
      // the same thing as far as the flow is concerned.
      return null;
    }
  }

  @override
  Future<void> discard(PickedArchive archive) async {
    try {
      await _channel.invokeMethod<bool>('deleteOpenedArchive', {'path': archive.path});
    } catch (_) {
      // A copy that cannot be deleted now goes with the next launch, which
      // empties the directory before anything else.
    }
  }

  Future<dynamic> _handle(MethodCall call) async {
    if (call.method != 'onOpenedArchive') return null;
    final handed = _handed(call.arguments as Map<dynamic, dynamic>?);
    if (handed == null) return false;
    if (_opened.hasListener) {
      _opened.add(_deliver(handed));
    } else {
      _held = handed;
    }
    // Taken: the native side drops its copy of it.
    return true;
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    _opened.close();
  }

  HandedArchive _deliver(HandedArchive handed) {
    _delivered = handed;
    return handed;
  }

  static HandedArchive? _handed(Map<dynamic, dynamic>? raw) {
    if (raw == null) return null;
    final name = raw['name'];
    if (name is! String || name.isEmpty) return null;
    // A file the app could not copy out of its security scope: its name is
    // all there is to show.
    if (raw['error'] != null) return HandedArchive(name: name);
    final path = raw['path'];
    if (path is! String || path.isEmpty) return null;
    final size = raw['size'];
    return HandedArchive(
      name: name,
      archive: PickedArchive(path: path, name: name, bytes: size is int ? size : 0),
    );
  }
}
