/// Draws the composer's mic; Phase 7 (voice input) flips it to true.
const bool voiceInputEnabled = false;

class AppConfig {
  // flutter run --dart-define=API_BASE_URL=https://mixtape-api.<account>.workers.dev
  // Origin only — no path prefix (Uri.resolve would drop it).
  static const apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8787',
  );
}
