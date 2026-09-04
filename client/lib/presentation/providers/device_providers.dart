// Device-local integrations shared by the signed-in tree and the sign-out
// path. Each is overridden with a fake in tests so no platform channel runs.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/onboarding/service_preference_store.dart';
import '../../data/reminders/reminder_scheduler.dart';

/// The one local reminder this app sends (the Spotify request nudge).
final reminderSchedulerProvider =
    Provider<ReminderScheduler>((ref) => LocalNotificationReminderScheduler());

/// The per-user "service chosen" flag the gate consults (keychain).
final servicePreferenceStoreProvider =
    Provider<ServicePreferenceStore>((ref) => SecureServicePreferenceStore());
