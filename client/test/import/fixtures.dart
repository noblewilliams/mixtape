import 'dart:convert';
import 'dart:io';

import 'package:mixtape/import/zip_reader.dart';

/// The repo's shared listening-export fixture suite, found by walking up from
/// the working directory until a `fixtures/listening-exports` directory exists.
Directory listeningExportFixtures() {
  var dir = Directory.current.absolute;
  while (true) {
    final candidate = Directory('${dir.path}/fixtures/listening-exports');
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('fixtures/listening-exports not found above ${Directory.current.path}');
    }
    dir = parent;
  }
}

String baseName(String path) => path.substring(path.lastIndexOf('/') + 1);

/// Every `<case>/` directory in the fixture suite, in name order.
List<Directory> fixtureCases() {
  final root = listeningExportFixtures();
  return root
      .listSync()
      .whereType<Directory>()
      .where((dir) => baseName(dir.path) != 'src')
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

Map<String, dynamic> caseDefinition(Directory caseDir) {
  final root = listeningExportFixtures();
  final name = baseName(caseDir.path);
  final file = File('${root.path}/src/$name/case.json');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

File fixtureArchive(String caseName) =>
    File('${listeningExportFixtures().path}/$caseName/archive.zip');

Map<String, dynamic> expectedFor(String caseName, String option) {
  final file = File('${listeningExportFixtures().path}/$caseName/expected.$option.json');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

/// Wraps an archive and records every path handed to [readText], so a test
/// can assert that the parser never opened an entry it must not.
class RecordingArchive extends ExportArchive {
  RecordingArchive(this.inner);

  final ExportArchive inner;
  final List<String> reads = [];

  @override
  Future<List<ArchiveEntryInfo>> entries() => inner.entries();

  @override
  Future<String> readText(String path) {
    reads.add(path);
    return inner.readText(path);
  }

  @override
  Future<void> close() => inner.close();
}
