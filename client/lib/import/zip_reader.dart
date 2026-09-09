import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';

/// A file entry as the central directory describes it: path and uncompressed
/// byte size. Nothing else about an entry is known until it is read.
class ArchiveEntryInfo {
  const ArchiveEntryInfo({required this.path, required this.bytes});

  final String path;
  final int bytes;

  @override
  String toString() => 'ArchiveEntryInfo($path, $bytes bytes)';
}

/// The parser's view of an export archive. Implementations must only
/// materialize the bytes of an entry when [readText] asks for that entry, so a
/// wrapper that records [readText] calls proves which entries were opened.
abstract class ExportArchive {
  /// File entries only, in the archive's own order; directory entries are
  /// never listed.
  Future<List<ArchiveEntryInfo>> entries();

  /// Decompresses one entry and decodes it as UTF-8: a leading byte-order
  /// mark is stripped, and a malformed sequence throws [FormatException].
  Future<String> readText(String path);

  Future<void> close() async {}
}

/// The bytes are not a ZIP archive this reader can open.
class ArchiveFormatException implements Exception {
  const ArchiveFormatException(this.message);

  final String message;

  @override
  String toString() => 'ArchiveFormatException: $message';
}

/// ZIP archive over a file or a byte buffer using `package:archive`.
///
/// `ZipDecoder.decodeStream` reads the central directory and each entry's
/// local header only; every entry keeps a view onto its compressed bytes and
/// is inflated on demand, so [readText] materializes the requested entry and
/// nothing else. Sizes come from the central directory, which is why an entry
/// whose local header defers to a data descriptor reads like any other.
class ZipExportArchive extends ExportArchive {
  ZipExportArchive._(this._input, this._files);

  /// Opens [file] with a buffered file stream; the whole archive is never
  /// loaded into memory. Call [close] when done.
  factory ZipExportArchive.open(File file) =>
      _decode(InputFileStream(file.path));

  factory ZipExportArchive.fromBytes(Uint8List bytes) =>
      _decode(InputMemoryStream(bytes));

  static ZipExportArchive _decode(InputStream input) {
    final Archive archive;
    final decoder = ZipDecoder();
    try {
      archive = decoder.decodeStream(input);
    } on ArchiveException catch (error) {
      input.closeSync();
      throw ArchiveFormatException(error.message);
    } on RangeError {
      input.closeSync();
      throw const ArchiveFormatException('truncated archive');
    }
    // `ZipDirectory.read` returns silently when no end-of-central-directory
    // record is found, leaving an empty archive; treat that as not a ZIP.
    if (decoder.directory.filePosition < 0) {
      input.closeSync();
      throw const ArchiveFormatException('no end-of-central-directory record');
    }
    final files = <String, ArchiveFile>{};
    for (final entry in archive) {
      if (!entry.isFile || entry.name.endsWith('/')) continue;
      if (files.containsKey(entry.name)) {
        input.closeSync();
        throw const ArchiveFormatException('duplicate entry');
      }
      files[entry.name] = entry;
    }
    return ZipExportArchive._(input, files);
  }

  final InputStream _input;
  final Map<String, ArchiveFile> _files;

  @override
  Future<List<ArchiveEntryInfo>> entries() async => [
    for (final file in _files.values)
      ArchiveEntryInfo(path: file.name, bytes: file.size),
  ];

  @override
  Future<String> readText(String path) async {
    final file = _files[path];
    if (file == null) {
      throw ArgumentError.value(path, 'path', 'not an entry of the archive');
    }
    final output = OutputMemoryStream(size: file.size);
    // Inflates this one entry into [output] without caching it on the entry.
    file.decompress(output);
    return decodeExportText(output.getBytes());
  }

  @override
  Future<void> close() async {
    _input.closeSync();
  }
}

/// Strict UTF-8 with a leading byte-order mark stripped.
String decodeExportText(Uint8List bytes) {
  final hasBom =
      bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF;
  final body = hasBom ? Uint8List.sublistView(bytes, 3) : bytes;
  return utf8.decode(body, allowMalformed: false);
}

/// CSV and ZIP share the same parser boundary; classification follows content.
ExportArchive openExportArchive(File file) {
  if(!file.path.toLowerCase().endsWith('.csv')) return ZipExportArchive.open(file);
  return _CsvFileArchive(file);
}

class _CsvFileArchive extends ExportArchive {
  _CsvFileArchive(this.file);
  final File file;
  String get path =>
      '${file.uri.pathSegments.last.replaceFirst(RegExp(r"\.csv$", caseSensitive: false), "")}.csv';
  @override
  Future<List<ArchiveEntryInfo>> entries() async {
    final bytes = await file.length();
    if (bytes > 64 * 1024 * 1024) {
      throw const ArchiveFormatException('Export is too large');
    }
    return [ArchiveEntryInfo(path: path, bytes: bytes)];
  }

  @override
  Future<String> readText(String path) async =>
      decodeExportText(await file.readAsBytes());
}
