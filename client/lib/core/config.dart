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
