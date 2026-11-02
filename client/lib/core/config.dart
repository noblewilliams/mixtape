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
}

/// Why a release build must not start with [apiBaseUrl], or null when it may.
/// The define is easy to leave off (`flutter build` silently keeps the
/// localhost default), and a store build pointing at localhost would look like
/// a broken app to every listener; `scripts/build-ios-release.sh` passes it.
String? releaseConfigProblem(String apiBaseUrl, {required bool release}) {
  if (!release) return null;
  final uri = Uri.tryParse(apiBaseUrl);
  if (uri == null || uri.scheme != 'https') {
    return 'API_BASE_URL must be an https origin in a release build';
  }
  if (uri.host == 'localhost' || uri.host == '127.0.0.1' || uri.host == '::1') {
    return 'API_BASE_URL is unset or local in a release build';
  }
  return null;
}
