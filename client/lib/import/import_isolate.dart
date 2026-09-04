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
Future<ParsedExport> parseExportInIsolate(String path, ParseOptions options) async {
  final events = ReceivePort();
  final onProgress = options.onProgress;
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
    } else if (message is List && onProgress != null) {
      onProgress(
        ParseStage.values[message[0] as int],
        message[1] as String?,
        message[2] as int,
        message[3] as int,
      );
    }
  });

  final token = options.cancelToken;
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
    return await _spawn(path, options.timeZone, options.includePrivateSessions, events.sendPort);
  } finally {
    finished = true;
    await subscription.cancel();
    events.close();
  }
}

// Kept in a scope that holds only sendable values, so the closure handed to
// Isolate.run captures nothing else.
Future<ParsedExport> _spawn(String path, String timeZone, bool includePrivateSessions, SendPort events) =>
    Isolate.run(
      () => _work(path, timeZone, includePrivateSessions, events),
      debugName: 'spotify-export-parser',
    );

Future<ParsedExport> _work(String path, String timeZone, bool includePrivateSessions, SendPort events) async {
  final cancels = ReceivePort();
  final token = CancelToken();
  cancels.listen((_) => token.cancel());
  events.send(cancels.sendPort);

  final ZipExportArchive archive;
  try {
    archive = ZipExportArchive.open(File(path));
  } on ArchiveFormatException {
    cancels.close();
    throw const UnreadableExportException(file: null, inventory: ExportInventory.empty);
  }
  try {
    return await parseExport(
      archive,
      ParseOptions(
        timeZone: timeZone,
        includePrivateSessions: includePrivateSessions,
        cancelToken: token,
        onProgress: (stage, file, completed, total) => events.send([stage.index, file, completed, total]),
      ),
    );
  } finally {
    await archive.close();
    cancels.close();
  }
}

/// Lists the archive at [path] in a worker isolate: which files the parser
/// would read and their row counts, without aggregating anything. A file
/// that is not a ZIP archive is unreadable with a null file, as in
/// [parseExportInIsolate].
Future<ExportInventory> inspectExportInIsolate(String path) =>
    Isolate.run(() => _inspect(path), debugName: 'spotify-export-inspector');

Future<ExportInventory> _inspect(String path) async {
  final ZipExportArchive archive;
  try {
    archive = ZipExportArchive.open(File(path));
  } on ArchiveFormatException {
    throw const UnreadableExportException(file: null, inventory: ExportInventory.empty);
  }
  try {
    return await inspectExport(archive);
  } finally {
    await archive.close();
  }
}
