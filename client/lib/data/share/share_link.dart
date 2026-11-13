// Shared mix links (spec 2026-11-13 shared-mixes): `<share base>/m/<token>`.
// The base comes from [AppConfig.shareBaseUrl], never a literal in feature
// code. Tokens are opaque to the client: 22 base62 characters.
import '../../core/config.dart';

final RegExp _token = RegExp(r'^[A-Za-z0-9]{22}$');

String _origin(String base) =>
    base.endsWith('/') ? base.substring(0, base.length - 1) : base;

/// The link a share of [token] opens.
String shareUrlFor(String token, {String base = AppConfig.shareBaseUrl}) =>
    '${_origin(base)}/m/$token';

/// The share token in [uri], or null when [uri] is not a share link: https,
/// exactly the configured share host and port, no user info, and the path
/// `/m/<token>` with an optional trailing slash. Any query or fragment is
/// ignored.
String? shareTokenFrom(Uri uri, {String base = AppConfig.shareBaseUrl}) {
  final expected = Uri.tryParse(_origin(base));
  if (expected == null || expected.host.isEmpty) return null;
  if (uri.scheme != 'https' || expected.scheme != 'https') return null;
  if (uri.userInfo.isNotEmpty) return null;
  if (uri.host != expected.host || uri.port != expected.port) return null;
  var path = uri.path;
  if (path.endsWith('/')) path = path.substring(0, path.length - 1);
  const prefix = '/m/';
  if (!path.startsWith(prefix)) return null;
  final token = path.substring(prefix.length);
  return _token.hasMatch(token) ? token : null;
}
