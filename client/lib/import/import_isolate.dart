import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'snapshot.dart';
import 'spotify_parser.dart';
import 'zip_reader.dart';

/// Parses the archive at [path] in a worker isolate via [Isolate.run].
///
/// Progress events are relayed to [ParseOptions.onProgress] on the calling
/// isolate; cancelling [ParseOptions.cancelToken] forwards a cancel message to
/// the worker, which throws [ImportCancelled] at its next checkpoint.
/// [UnreadableExportException] and [ImportCancelled] propagate typed; a file
/// that is not a ZIP archive is unreadable with a null file.
Future<ParsedExport> parseExportInIsolate(String path, ParseOptions options) {
  final onProgress = options.onProgress;
  return _runCancellable(
    options.cancelToken,
    (events) => _spawnParse(
      path,
      options.timeZone,
      options.includePrivateSessions,
      events,
    ),
    onEvent: onProgress == null
        ? null
        : (message) => onProgress(
            ParseStage.values[message[0] as int],
            message[1] as String?,
            message[2] as int,
            message[3] as int,
          ),
  );
}

/// Lists the archive at [path] in a worker isolate: which files the parser
/// would read and their row counts, without aggregating anything. Cancelling
/// [cancelToken] stops the worker as in [parseExportInIsolate]. A file that
/// is not a ZIP archive is unreadable with a null file.
Future<ExportInventory> inspectExportInIsolate(
  String path, {
  CancelToken? cancelToken,
}) => _runCancellable(cancelToken, (events) => _spawnInspect(path, events));

/// Runs [spawn] with the port the worker reports its cancel port on (and, for
/// the parser, sends progress events to). Cancelling [token] forwards a
/// message to the worker, which throws [ImportCancelled] at its next
/// checkpoint; a token cancelled before the worker reports its port is
/// forwarded the moment it does.
Future<T> _runCancellable<T>(
  CancelToken? token,
  Future<T> Function(SendPort events) spawn, {
  void Function(List<Object?> message)? onEvent,
}) async {
  final events = ReceivePort();
  SendPort? cancelPort;
  var cancelRequested = false;

  void requestCancel() {
    cancelRequested = true;
    cancelPort?.send(null);
  }

  final subscription = events.listen((message) {
    if (message is SendPort) {
      cancelPort = message;
      if (cancelRequested) message.send(null);
    } else if (message is List && onEvent != null) {
      onEvent(message);
    }
  });

  var finished = false;
  if (token != null) {
    if (token.isCancelled) {
      requestCancel();
    } else {
      unawaited(
        token.whenCancelled.then((_) {
          if (!finished) requestCancel();
        }),
      );
    }
  }

  try {
    return await spawn(events.sendPort);
  } finally {
    finished = true;
    await subscription.cancel();
    events.close();
  }
}

// The spawn functions live in scopes that hold only sendable values, so the
// closures handed to Isolate.run capture nothing else.
Future<ParsedExport> _spawnParse(
  String path,
  String timeZone,
  bool includePrivateSessions,
  SendPort events,
) => Isolate.run(
  () => _parse(path, timeZone, includePrivateSessions, events),
  debugName: 'spotify-export-parser',
);

Future<ExportInventory> _spawnInspect(String path, SendPort events) =>
    Isolate.run(
      () => _inspect(path, events),
      debugName: 'spotify-export-inspector',
    );

Future<ParsedExport> _parse(
  String path,
  String timeZone,
  bool includePrivateSessions,
  SendPort events,
) => _withArchive(
  path,
  events,
  (archive, token) => parseExport(
    archive,
    ParseOptions(
      timeZone: timeZone,
      includePrivateSessions: includePrivateSessions,
      cancelToken: token,
      onProgress: (stage, file, completed, total) =>
          events.send([stage.index, file, completed, total]),
    ),
  ),
);

Future<ExportInventory> _inspect(String path, SendPort events) => _withArchive(
  path,
  events,
  (archive, token) => inspectExport(archive, cancelToken: token),
);

/// Worker side: reports a cancel port on [events], opens the archive, and
/// runs [body] with a token that port cancels.
Future<T> _withArchive<T>(
  String path,
  SendPort events,
  Future<T> Function(ExportArchive archive, CancelToken token) body,
) async {
  final cancels = ReceivePort();
  final token = CancelToken();
  cancels.listen((_) => token.cancel());
  events.send(cancels.sendPort);

  final ExportArchive archive;
  try {
    archive = openExportArchive(File(path));
  } on ArchiveFormatException {
    cancels.close();
    throw const UnreadableExportException(
      file: null,
      inventory: ExportInventory.empty,
    );
  }
  try {
    return await body(archive, token);
  } finally {
    await archive.close();
    cancels.close();
  }
}
