// Device-local integrations shared by the signed-in tree and the sign-out
// path. Each is overridden with a fake in tests so no platform channel runs.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import '../../data/files/archive_picker.dart';
import '../../data/files/opened_archive_channel.dart';
import '../../data/onboarding/funnel_once_store.dart';
import '../../data/onboarding/service_preference_store.dart';
import '../../data/reminders/reminder_scheduler.dart';
import '../../data/share/text_sharer.dart';

/// The one local reminder this app sends (the Spotify request nudge).
final reminderSchedulerProvider =
    Provider<ReminderScheduler>((ref) => LocalNotificationReminderScheduler());

/// The per-user "service chosen" flag the gate consults (keychain).
final servicePreferenceStoreProvider =
    Provider<ServicePreferenceStore>((ref) => SecureServicePreferenceStore());

/// The per-user "already posted" flags for the once-only funnel milestones
/// (keychain), cleared alongside the service flag on sign-out.
final funnelOnceStoreProvider = Provider<FunnelOnceStore>((ref) => SecureFunnelOnceStore());

/// The share sheet behind "Send to a transfer tool" on the queue screen.
final textSharerProvider = Provider<TextSharer>((ref) => const SharePlusTextSharer());

/// The ZIP picker behind "Choose a ZIP" (the document picker).
final archivePickerProvider = Provider<ArchivePicker>((ref) => const FilePickerArchivePicker());

/// The other way in: a ZIP handed to the app from Files or Mail. Not
/// user-scoped itself (the channel outlives any one listener); the notifier
/// that reads it is.
final openedArchiveSourceProvider = Provider<OpenedArchiveSource>((ref) {
  final source = MethodChannelOpenedArchiveSource();
  ref.onDispose(source.dispose);
  return source;
});

typedef TimeZoneReader = Future<String> Function();

/// The device's IANA zone, which an import records and converts local days
/// to. UTC when the platform cannot say, so an import is never blocked on it.
final deviceTimeZoneProvider = Provider<TimeZoneReader>((ref) => readDeviceTimeZone);

Future<String> readDeviceTimeZone() async {
  try {
    final zone = (await FlutterTimezone.getLocalTimezone()).identifier;
    return zone.isEmpty ? 'UTC' : zone;
  } catch (_) {
    return 'UTC';
  }
}
