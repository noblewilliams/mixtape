import 'dart:io';
import 'package:archive/archive_io.dart';
// The ZIP picker behind "Choose a ZIP". Screens depend on the interface (via
// `archivePickerProvider`) so widget tests inject a fake and never touch the
// document-picker channel.
import 'package:file_picker/file_picker.dart';

/// A ZIP the listener picked: where the parser finds it, and what to call it
/// on screen. The name is the file's own, never anything from inside it.
class PickedArchive {
  const PickedArchive({
    required this.path,
    required this.name,
    required this.bytes,
    this.temporaryDirectory,
  });

  final String path;
  final String name;
  final int bytes;
  final String? temporaryDirectory;

  Future<void> discardTemporaryCopy() async {
    final path = temporaryDirectory;
    if (path == null) return;
    try {
      await Directory(path).delete(recursive: true);
    } on FileSystemException {
      /* Already removed. */
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PickedArchive &&
      other.path == path &&
      other.name == name &&
      other.bytes == bytes;

  @override
  int get hashCode => Object.hash(path, name, bytes);
}

abstract class ArchivePicker {
  /// Null when the listener dismissed the picker.
  Future<PickedArchive?> pick();
}

/// [ArchivePicker] over `file_picker`, restricted to `.zip` so Files only
/// offers archives.
class FilePickerArchivePicker implements ArchivePicker {
  const FilePickerArchivePicker();

  @override
  Future<PickedArchive?> pick() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip', 'csv'],
      allowMultiple: true,
    );
    final files = result?.files;
    if (files != null && files.length > 1) {
      if (files.length > 2000 ||
          files.any(
            (f) => !f.name.toLowerCase().endsWith('.csv') || f.path == null,
          ) ||
          files.fold<int>(0, (n, f) => n + f.size) > 64 * 1024 * 1024) {
        throw const FormatException(
          'Choose one ZIP or several CSV files, up to 64 MB.',
        );
      }
      final directory = await Directory.systemTemp.createTemp(
        'mixtape-import-',
      );
      final destination = '${directory.path}/selected_playlists.zip';
      final encoder = ZipFileEncoder()..create(destination);
      try {
        for (var i = 0; i < files.length; i++) {
          await encoder.addFile(File(files[i].path!), '$i/${files[i].name}');
        }
        encoder.close();
        return PickedArchive(
          path: destination,
          name: 'Selected playlists',
          temporaryDirectory: directory.path,
          bytes: await File(destination).length(),
        );
      } catch (_) {
        encoder.close();
        await directory.delete(recursive: true);
        rethrow;
      }
    }
    final file = result?.files.singleOrNull;
    final path = file?.path;
    if (file == null || path == null) return null;
    return PickedArchive(path: path, name: file.name, bytes: file.size);
  }
}
