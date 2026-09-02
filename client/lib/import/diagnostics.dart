import 'snapshot.dart';
import 'spotify_parser.dart';
import 'zip_reader.dart';

/// Recorded with a failed import so a report can be read without the archive.
const String spotifyParserVersion = 'client-spotify-1';

/// Names, byte sizes, row counts, and top-level keys; never a value.
///
/// Rows and headers are filled only for the files the detected package reads
/// (the same set the inventory lists as `read`); every other entry, allow-listed
/// or not, is reported by path and size alone. Headers are the keys of the first
/// array element of a history file, or of the library / playlist object.
Future<ExportDiagnostics> diagnoseExport(ExportArchive archive) async {
  final files = await listExportFiles(archive);
  final package = detectPackage(files);
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
