import 'dart:io';
import 'dart:isolate';

import 'exportify_parser.dart';
import 'snapshot.dart';
import 'spotify_parser.dart';
import 'zip_reader.dart';

/// Recorded with a failed import so a report can be read without the archive.
const String spotifyParserVersion = 'client-spotify-2';

/// Names, byte sizes, row counts, and top-level keys; never a value.
///
/// Rows and headers are filled only for the files the detected package reads
/// (the same set the inventory lists as `read`); every other entry, allow-listed
/// or not, is reported by path and size alone. Headers are the keys of the first
/// array element of a history file, or of the library / playlist object. An
/// archive of CSVs (Exportify) reports every CSV's header row instead.
Future<ExportDiagnostics> diagnoseExport(ExportArchive archive) async {
  final files = await listExportFiles(archive);
  final package = detectPackage(files);
  if (package == null && files.any((f) => isCsvPath(f.path))) {
    return _diagnoseExportify(archive, files);
  }
  final readKinds = readKindsFor(package);
  final report = <DiagnosticsFile>[];
  for (final file in files) {
    int? rows;
    List<String>? headers;
    if (readKinds.contains(file.kind)) {
      final loaded = await loadExportFile(archive, file);
      if (loaded != null) {
        rows = loaded.rows;
        headers = loaded.headers;
      }
    }
    report.add(DiagnosticsFile(path: file.path, bytes: file.bytes, rows: rows, headers: headers));
  }
  return ExportDiagnostics(
    source: package == null ? 'unknown' : 'spotify_export',
    files: report,
    parserVersion: spotifyParserVersion,
  );
}

/// Exportify files are CSVs: each one reports its header row (known column
/// labels only) and the rows under it; anything else, path and size alone.
Future<ExportDiagnostics> _diagnoseExportify(
  ExportArchive archive,
  List<ExportFile> files,
) async {
  final report = <DiagnosticsFile>[];
  for (final file in files) {
    final shape = isCsvPath(file.path) && file.bytes <= 64 * 1024 * 1024
        ? await exportifyCsvShape(archive, file.path)
        : null;
    report.add(
      DiagnosticsFile(
        path: file.path,
        bytes: file.bytes,
        rows: shape?.rows,
        headers: shape?.headers,
      ),
    );
  }
  return ExportDiagnostics(
    source: ExportPackage.spotifyExportify.wire,
    files: report,
    parserVersion: spotifyParserVersion,
  );
}

/// [diagnoseExport] over the archive at [path], off the main isolate (it
/// decodes every file the parser would read, which for a long history is
/// seconds of work). A file that is not a ZIP reports `unknown` with no
/// files.
Future<ExportDiagnostics> diagnoseExportFile(String path) => Isolate.run(() => _diagnoseFile(path));

Future<ExportDiagnostics> _diagnoseFile(String path) async {
  final ZipExportArchive archive;
  try {
    archive = ZipExportArchive.open(File(path));
  } on ArchiveFormatException {
    return const ExportDiagnostics(source: 'unknown', files: [], parserVersion: spotifyParserVersion);
  }
  try {
    return await diagnoseExport(archive);
  } finally {
    await archive.close();
  }
}
