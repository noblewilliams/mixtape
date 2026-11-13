/// Draws the composer's mic. Voice input landed in Phase 7 (recorded clip →
/// server transcription → on-device fallback), so it is on.
const bool voiceInputEnabled = true;

class AppConfig {
  // flutter run --dart-define=API_BASE_URL=https://mixtape-api.<account>.workers.dev
  // Origin only — no path prefix (Uri.resolve would drop it).
  static const apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8787',
  );

  // The site a shared mix's link opens (`<shareBaseUrl>/m/<token>`), and the
  // only host whose links the app takes as shares. Origin only, https; the
  // production site in every build unless SHARE_BASE_URL overrides it.
  static const shareBaseUrl = String.fromEnvironment(
    'SHARE_BASE_URL',
    defaultValue: 'https://miixtape.netlify.app',
  );
}

/// Why a release build must not start with [apiBaseUrl] (or [shareBaseUrl]),
/// or null when it may.
/// The define is easy to leave off (`flutter build` silently keeps the
/// localhost default), and a store build pointing at localhost would look like
/// a broken app to every listener; `scripts/build-ios-release.sh` passes it.
String? releaseConfigProblem(
  String apiBaseUrl, {
  required bool release,
  String shareBaseUrl = AppConfig.shareBaseUrl,
}) {
  if (!release) return null;
  final uri = Uri.tryParse(apiBaseUrl);
  if (uri == null || uri.scheme != 'https') {
    return 'API_BASE_URL must be an https origin in a release build';
  }
  if (_isLocal(uri.host)) {
    return 'API_BASE_URL is unset or local in a release build';
  }
  final share = Uri.tryParse(shareBaseUrl);
  if (share == null ||
      share.scheme != 'https' ||
      _isLocal(share.host) ||
      (share.path.isNotEmpty && share.path != '/') ||
      share.hasQuery ||
      share.hasFragment) {
    return 'SHARE_BASE_URL must be a public https origin in a release build';
  }
  return null;
}

bool _isLocal(String host) =>
    host.isEmpty || host == 'localhost' || host == '127.0.0.1' || host == '::1';
