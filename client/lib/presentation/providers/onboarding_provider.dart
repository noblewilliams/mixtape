// Providers for the listening-export onboarding state (`GET /me/onboarding`)
// and the two funnel steps the request flow records. Same auth-transition
// rules as dj_providers.dart: user-scoped, watch the AsyncValue rather than
// `.future` across a sign-out.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../data/listening/listening_api.dart';
import '../../data/listening/listening_models.dart';
import '../../data/reminders/reminder_scheduler.dart';
import 'auth_provider.dart';

/// Shares the app's [ApiClient] (its timeout suits these small routes; the
/// import service brings its own long-running client).
final listeningApiProvider =
    Provider<ListeningApi>((ref) => ListeningApi(ref.watch(apiClientProvider)));

/// Device-local; tests override it with a fake so no platform channel runs.
final reminderSchedulerProvider =
    Provider<ReminderScheduler>((ref) => LocalNotificationReminderScheduler());

typedef LinkOpener = Future<bool> Function(Uri uri);

/// Opens an address outside the app (Safari); overridden in widget tests.
final linkOpenerProvider = Provider<LinkOpener>(
  (ref) => (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);

class OnboardingNotifier extends AsyncNotifier<OnboardingState> {
  @override
  Future<OnboardingState> build() async {
    ref.watch(authProvider); // user-scoped: reload/reset on every auth transition
    final api = ref.watch(listeningApiProvider);
    return api.getOnboarding();
  }

  /// Same contract as SessionsNotifier.refresh: returns whether the refetch
  /// succeeded; a failure keeps the previous value showing.
  Future<bool> refresh() async {
    final next = await AsyncValue.guard(() => ref.read(listeningApiProvider).getOnboarding());
    if (!ref.mounted) return false;
    state = next;
    return !next.hasError;
  }

  /// The listener picked Spotify at the service gate.
  Future<void> markChoseSpotify() => _record(FunnelEventType.choseSpotify);

  /// The listener tapped "I've requested it" on the request screen.
  Future<void> markRequested() => _record(FunnelEventType.markedRequested);

  /// Funnel steps are fire-and-forget, like session events: a failed post
  /// is dropped silently and never surfaces. The refetch afterwards is what
  /// moves the screens on (the server derives the onboarding state from
  /// these events), so a dropped post simply leaves them where they were.
  Future<void> _record(FunnelEventType type) async {
    try {
      await ref.read(listeningApiProvider).postFunnelEvent(type);
    } catch (_) {
      // Silent by design — no retry, no surfaced error.
    }
    if (!ref.mounted) return;
    await refresh();
  }
}

final onboardingProvider =
    AsyncNotifierProvider<OnboardingNotifier, OnboardingState>(OnboardingNotifier.new);
