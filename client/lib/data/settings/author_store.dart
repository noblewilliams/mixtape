import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Remembers the name playlists are attributed to — Apple Music shows it as
/// "by &lt;author&gt;" on every playlist the app creates. The value is not a
/// secret; secure storage is used only because it's the one persistence
/// dependency the app already ships (mirrors [TokenStore]'s shape so the
/// in-memory fake pattern carries over to tests).
abstract class AuthorStore {
  Future<String?> read();
  Future<void> write(String author);
}

class SecureAuthorStore implements AuthorStore {
  SecureAuthorStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'mixtape_playlist_author';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String author) => _storage.write(key: _key, value: author);
}

class InMemoryAuthorStore implements AuthorStore {
  InMemoryAuthorStore([this._author]);
  String? _author;

  @override
  Future<String?> read() async => _author;

  @override
  Future<void> write(String author) async => _author = author;
}
