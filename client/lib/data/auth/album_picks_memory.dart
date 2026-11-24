// The last album-picks answer `/me` gave on this device, so a cold start can
// draw Home's composer row (Mix | Album and Shape) in its final layout before
// `/me` answers, instead of showing the Mix-only row and then the toggle.
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

abstract class AlbumPicksMemory {
  /// Null when nothing is remembered (a fresh install, or signed out since).
  Future<bool?> read();
  Future<void> write(bool albumPicks);
  Future<void> clear();
}

/// A small file in Application Support. It goes with the app, so a reinstall
/// starts from nothing (unlike the Keychain).
class FileAlbumPicksMemory implements AlbumPicksMemory {
  FileAlbumPicksMemory({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  static const String fileName = 'capabilities.json';
  static const String _key = 'albumPicks';

  final Future<Directory> Function() _directory;

  Future<File> _file() async => File('${(await _directory()).path}/$fileName');

  @override
  Future<bool?> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map && decoded[_key] is bool) return decoded[_key] as bool;
    } catch (_) {}
    return null;
  }

  @override
  Future<void> write(bool albumPicks) async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({_key: albumPicks}), flush: true);
    } catch (_) {}
  }

  @override
  Future<void> clear() async {
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

class InMemoryAlbumPicksMemory implements AlbumPicksMemory {
  InMemoryAlbumPicksMemory([this.value]);
  bool? value;
  int writes = 0;

  @override
  Future<bool?> read() async => value;
  @override
  Future<void> write(bool albumPicks) async {
    writes++;
    value = albumPicks;
  }

  @override
  Future<void> clear() async => value = null;
}
