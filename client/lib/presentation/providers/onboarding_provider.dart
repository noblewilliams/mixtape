// Providers for the listening-export onboarding state (`GET /me/onboarding`)
// and the two funnel steps the request flow records. Same auth-transition
// rules as dj_providers.dart: user-scoped, watch the AsyncValue rather than
// `.future` across a sign-out.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../data/listening/listening_api.dart';
import '../../data/listening/listening_models.dart';
import 'auth_provider.dart';
import 'device_providers.dart';

/// Shares the app's [ApiClient] (its timeout suits these small routes; the
/// import service brings its own long-running client).
final listeningApiProvider =
    Provider<ListeningApi>((ref) => ListeningApi(ref.watch(apiClientProvider)));

typedef LinkOpener = Future<bool> Function(Uri uri);

/// Opens an address outside the app (Safari); overridden in widget tests.
final linkOpenerProvider = Provider<LinkOpener>(
  (ref) => (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);

typedef LinkProbe = Future<bool> Function(Uri uri);

/// Whether this device can open [uri] at all — the app-scheme check behind
/// "Open in Spotify" (iOS answers only for schemes Info.plist declares under
/// LSApplicationQueriesSchemes); overridden in widget tests.
final linkProbeProvider = Provider<LinkProbe>((ref) => canLaunchUrl);

class OnboardingNotifier extends AsyncNotifier<OnboardingState> {
  @override
  Future<OnboardingState> build() async {
    ref.watch(authProvider); // user-scoped: reload/reset on every auth transition
    final api = ref.watch(listeningApiProvider);
    return _load(api);
  }

  /// The server's answer, with the choice remembered on this device filled
  /// in when the server has none: choosing Apple records nothing
  /// server-side, and a dropped `chose_spotify` post would otherwise show
  /// the gate again next launch. The server's own answer always wins, and
  /// the flag is keyed by the listener so another account's never applies.
  Future<OnboardingState> _load(ListeningApi api) async {
    final remote = await api.getOnboarding();
    if (remote.chosenService != null) return remote;
    final local = await _remembered(remote.userId);
    return local == null ? remote : remote.withChosenService(local);
  }

  /// Both directions are best effort, like the funnel posts: the flag is a
  /// convenience for the next launch, and an unreadable or unwritable
  /// keychain must fail neither the load nor the choice.
  Future<String?> _remembered(String userId) async {
    try {
      return await ref.read(servicePreferenceStoreProvider).read(userId);
    } catch (_) {
      return null;
    }
  }

  Future<void> _remember(String userId, String service) async {
    try {
      await ref.read(servicePreferenceStoreProvider).write(userId, service);
    } catch (_) {
      // Silent by design.
    }
  }

  /// Same contract as SessionsNotifier.refresh: returns whether the refetch
  /// succeeded; a failure keeps the previous value showing.
  Future<bool> refresh() async {
    final next = await AsyncValue.guard(() => _load(ref.read(listeningApiProvider)));
    if (!ref.mounted) return false;
    state = next;
    return !next.hasError;
  }

  /// The listener picked Apple Music at the service gate. Nothing is posted
  /// (the server infers Apple once a library syncs), so the choice lives on
  /// this device and the state takes it directly. The gate only offers the
  /// choice over a loaded state; with none (or only a previous account's,
  /// carried into a loading state) there is no listener to remember it for.
  Future<void> markChoseApple() async {
    final current = state.unwrapPrevious().value;
    if (current == null) return;
    await _remember(current.userId, 'apple');
    if (!ref.mounted) return;
    state = AsyncData(current.withChosenService('apple'));
  }

  /// The listener picked Spotify at the service gate: remembered on the
  /// device before the post, so a dropped `chose_spotify` still shows the
  /// waiting state on the next launch.
  Future<void> markChoseSpotify() async {
    final userId = state.unwrapPrevious().value?.userId;
    if (userId != null) await _remember(userId, 'spotify');
    if (!ref.mounted) return;
    await _record(FunnelEventType.choseSpotify);
  }

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

/// No retry: the gate decides from the first answer (an error falls through
/// to Home), and a retry would have Riverpod re-issue the GET through its
/// backoff — including after a sign-out, when the 401 would just repeat.
final onboardingProvider = AsyncNotifierProvider<OnboardingNotifier, OnboardingState>(
  OnboardingNotifier.new,
  retry: (_, _) => null,
);
