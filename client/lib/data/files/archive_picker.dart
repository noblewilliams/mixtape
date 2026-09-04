// The ZIP picker behind "Choose a ZIP". Screens depend on the interface (via
// `archivePickerProvider`) so widget tests inject a fake and never touch the
// document-picker channel.
import 'package:file_picker/file_picker.dart';

/// A ZIP the listener picked: where the parser finds it, and what to call it
/// on screen. The name is the file's own, never anything from inside it.
class PickedArchive {
  const PickedArchive({required this.path, required this.name, required this.bytes});

  final String path;
  final String name;
  final int bytes;

  @override
  bool operator ==(Object other) =>
      other is PickedArchive && other.path == path && other.name == name && other.bytes == bytes;

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
      allowedExtensions: const ['zip'],
    );
    final file = result?.files.singleOrNull;
    final path = file?.path;
    if (file == null || path == null) return null;
    return PickedArchive(path: path, name: file.name, bytes: file.size);
  }
}
