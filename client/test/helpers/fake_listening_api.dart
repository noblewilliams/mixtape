import 'package:mixtape/data/listening/listening_api.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/data/reminders/reminder_scheduler.dart';

/// Implements [ListeningApi]'s public surface (not `extends` — its
/// constructor wants a real [ApiClient]), the same way the screen tests'
/// FakeDjApi stands in for DjApi. Only the onboarding, funnel, and
/// interview calls the screens make are wired; every other method throws
/// so an unexpected call fails loudly rather than hanging.
class FakeListeningApi implements ListeningApi {
  FakeListeningApi({OnboardingState? onboarding})
      : onboarding = onboarding ?? onboardingState(chosenService: 'apple');

  /// What [getOnboarding] answers with unless [onGetOnboarding] is set.
  OnboardingState onboarding;
  Future<OnboardingState> Function()? onGetOnboarding;
  Future<void> Function(FunnelEventType type)? onPostFunnelEvent;
  Future<InterviewResult> Function(InterviewAnswers answers)? onPostInterview;
  Future<DeleteSourceResult> Function(String source)? onDeleteSource;

  final List<FunnelEventType> funnelEvents = [];
  final List<String> deletedSources = [];
  final List<InterviewAnswers> interviews = [];
  int getOnboardingCalls = 0;

  @override
  String get surface => 'ios';

  @override
  Future<OnboardingState> getOnboarding() {
    getOnboardingCalls++;
    final impl = onGetOnboarding;
    return impl == null ? Future.value(onboarding) : impl();
  }

  @override
  Future<void> postFunnelEvent(FunnelEventType type) {
    funnelEvents.add(type);
    final impl = onPostFunnelEvent;
    return impl == null ? Future.value() : impl(type);
  }

  @override
  Future<InterviewResult> postInterview(InterviewAnswers answers) {
    interviews.add(answers);
    final impl = onPostInterview;
    if (impl == null) throw UnimplementedError('onPostInterview not wired');
    return impl(answers);
  }

  @override
  Future<ListeningImportRun> beginImport(BeginListeningImport body) =>
      throw UnimplementedError();

  @override
  Future<int> putTracks(String importId, List<Map<String, Object?>> rows) =>
      throw UnimplementedError();

  @override
  Future<int> putDays(String importId, List<Map<String, Object?>> rows) =>
      throw UnimplementedError();

  @override
  Future<int> putLibrary(String importId, List<Map<String, Object?>> rows) =>
      throw UnimplementedError();

  @override
  Future<int> putArtists(String importId, List<Map<String, Object?>> rows) =>
      throw UnimplementedError();

  @override
  Future<ListeningImportSummary> completeImport(String importId) =>
      throw UnimplementedError();

  @override
  Future<DeleteSourceResult> deleteSource(String source) {
    deletedSources.add(source);
    final impl = onDeleteSource;
    if (impl == null) throw UnimplementedError('onDeleteSource not wired');
    return impl(source);
  }

  @override
  Future<PlaylistSyncRun> beginPlaylistSync({
    required int expectedPlaylists,
    required int expectedEntries,
  }) =>
      throw UnimplementedError();

  @override
  Future<int> putPlaylists(String syncId, List<Map<String, Object?>> playlists) =>
      throw UnimplementedError();

  @override
  Future<int> putPlaylistEntries(
    String syncId,
    String playlistAppleId,
    List<Map<String, Object?>> entries,
  ) =>
      throw UnimplementedError();

  @override
  Future<PlaylistSyncSummary> completePlaylistSync(String syncId) =>
      throw UnimplementedError();

  @override
  Future<List<MusicSource>> getMusicSources() => throw UnimplementedError();

  @override
  Future<List<ArtistSeed>> getArtistSeeds() => throw UnimplementedError();

  @override
  Future<List<ArtistSeed>> putArtistSeeds(List<String> names) => throw UnimplementedError();

  @override
  Future<List<SeedTrack>> getSeedTracks() => throw UnimplementedError();

  @override
  Future<SeedTracksResult> postSeedTracks(List<String> spotifyIds) =>
      throw UnimplementedError();

  @override
  Future<DeleteSeedTrackResult> deleteSeedTrack(String trackId) =>
      throw UnimplementedError();
}

/// An onboarding answer with every field defaulted to "nothing yet".
OnboardingState onboardingState({
  String userId = 'user-1',
  String? chosenService,
  DateTime? markedRequestedAt,
  DateTime? interviewCompletedAt,
  DateTime? importCompletedAt,
  bool hasLibrary = false,
  List<MusicSource> sources = const [],
  InterviewCounts? interview,
}) =>
    OnboardingState(
      userId: userId,
      sources: sources,
      hasLibrary: hasLibrary,
      chosenService: chosenService,
      markedRequestedAt: markedRequestedAt,
      interviewCompletedAt: interviewCompletedAt,
      importCompletedAt: importCompletedAt,
      interview: interview,
    );

/// A connected source row; [packages] is what actually landed for it.
MusicSource musicSource({
  String source = 'spotify_export',
  List<String> packages = const [],
  DateTime? connectedAt,
  DateTime? lastImportedAt,
  String? ledgerFrom,
  String? ledgerTo,
}) =>
    MusicSource(
      source: source,
      connectedAt: connectedAt ?? DateTime.utc(2026, 9, 1, 10),
      lastImportedAt: lastImportedAt,
      ledgerFrom: ledgerFrom,
      ledgerTo: ledgerTo,
      packages: packages,
    );

/// Records every reminder a screen asks for, and every cancellation; touches
/// no platform channel.
class FakeReminderScheduler implements ReminderScheduler {
  final List<Duration> scheduled = [];
  int cancelled = 0;

  @override
  Future<void> scheduleRequestReminder({required Duration after}) async {
    scheduled.add(after);
  }

  @override
  Future<void> cancelRequestReminder() async {
    cancelled++;
  }
}
