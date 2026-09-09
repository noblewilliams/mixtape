// Local acceptance check: emits aggregate counts and a parity digest only.
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:mixtape/import/spotify_parser.dart';
import 'package:mixtape/import/zip_reader.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) { stderr.writeln('Provide one local export path.'); exitCode = 2; return; }
  final archive = openExportArchive(File(args.single));
  try {
    final result = await parseExport(archive, const ParseOptions(timeZone: 'UTC'));
    final snapshot = result.snapshot;
    stdout.writeln(jsonEncode({
      'package': snapshot.package.wire,
      'files': result.inventory.read.length,
      'tracks': snapshot.tracks.length,
      'playlists': snapshot.playlists.length,
      'entries': snapshot.playlists.fold<int>(0, (n,p) => n + p.entries.length),
      'unresolved': snapshot.unresolved.rows,
      'digest': sha256.convert(utf8.encode(jsonEncode(snapshot.toCanonicalJson()))).toString(),
    }));
  } catch (_) { stderr.writeln('Export acceptance failed. No music data logged.'); exitCode = 1; }
  finally { await archive.close(); }
}
