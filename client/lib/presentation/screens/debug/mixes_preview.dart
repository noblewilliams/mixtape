/// The Mixes tab on made-up mixes, so its list, toggle and swipes can be
/// checked in the simulator without signing in.
///
/// Debug only — `main.dart` reaches it behind `kDebugMode` and
/// `--dart-define=MIXTAPE_PREVIEW=mixes`, so it never ships in a release
/// build. Archive, Unarchive and Rename change the made-up list in memory.
///
/// It also opens on the DJ's work in flight (device smoke, 2026-11-13): a
/// new mix being made, one mix with a turn out and one with a reply waiting.
/// Any mix opens a short made-up conversation with a playlist attached, and
/// a message sent there takes the DJ 40 seconds, so the working caption and
/// the Mixes rows can be watched. The made-up turn streams its steps as a
/// catalogue mix would (turn steps, 2026-11-13), names included, so the
/// caption follows them: listening, the crates, picking past its 12 s
/// line, the sound check, pressing, labelling, and a note overtaken by the
/// liner notes before it can show.
///
/// The made-up API answers the shared-mix calls too (spec 2026-11-13
/// shared-mixes), so `SharedMixScreen` opens on made-up data from here:
/// [MixesPreview.sharedToken] loads, [MixesPreview.goneToken] reads as a
/// stopped share. Both sit in the list as saved shares: "From Ada" two hours
/// ago, and one "From a friend" (a sender who cleared their name) whose
/// share was stopped, so its screen offers Remove. Remove takes either out
/// of the made-up list.
///
/// Select mode works on it too (select and delete mixes, 2026-11-16): the ⋯
/// in the nav bar opens it, Archive and Delete change the made-up list, and
/// the second mix reads as shared so the confirm's share line shows.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/dj/dj_api.dart';
import '../../../data/push/push_ask_store.dart';
import '../../../data/push/push_service.dart';
import '../../../data/dj/dj_models.dart';
import '../../../data/playlists/playlist_context_api.dart';
import '../../../data/playlists/playlist_context_models.dart';
import '../../providers/app_update_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/capabilities_provider.dart';
import '../../providers/dj_providers.dart';
import '../../providers/dj_status_provider.dart';
import '../../providers/mix_activity_provider.dart';
import '../../providers/onboarding_provider.dart';
import '../../../data/listening/listening_models.dart';
import '../../providers/playlist_context_provider.dart';
import '../../providers/push_provider.dart';
import '../mixes_screen.dart';
import '../shell/shell_screen.dart';
import 'update_preview.dart';

class MixesPreview extends StatefulWidget {
  const MixesPreview({super.key});

  /// A made-up share from Ada, ten songs, two with no Apple Music match.
  static const String sharedToken = 'PreviewShareAdaLateDrv';

  /// Opens with the DJ paused, so the paused composers can be checked.
  static const bool djPaused = bool.fromEnvironment(
    'MIXTAPE_PREVIEW_DJ_PAUSED',
  );

  /// `--dart-define=MIXTAPE_PREVIEW=shell`: the whole shell (dock or side
  /// rail, every tab) on the same made-up data, so the shell's chrome can be
  /// checked on any screen size without signing in.
  static const bool shell =
      String.fromEnvironment('MIXTAPE_PREVIEW') == 'shell' ||
      String.fromEnvironment('MIXTAPE_PREVIEW') == 'push-ask' ||
      String.fromEnvironment('MIXTAPE_PREVIEW') == 'shell-update' ||
      String.fromEnvironment('MIXTAPE_PREVIEW') == 'shell-update-applied';

  /// `--dart-define=MIXTAPE_PREVIEW=push-ask`: the shell with nothing in
  /// flight and a phone iOS has not asked yet, so the Mix ready pop-up
  /// comes up over Home once it settles (after "Where do you listen?" if
  /// this simulator has no platform stored). Its pill brings up a made-up
  /// Allow; You's row then reads on. The once rule is kept in memory, so
  /// every launch asks again.
  static const bool pushAsk =
      String.fromEnvironment('MIXTAPE_PREVIEW') == 'push-ask';

  /// A made-up share its sender stopped.
  static const String goneToken = 'PreviewShareStoppedXyz';

  @override
  State<MixesPreview> createState() => _MixesPreviewState();
}

class _MixesPreviewState extends State<MixesPreview> {
  // A container of its own rather than a nested scope: the session list lives
  // where the API does, so overriding the API under the app's scope would
  // leave the list reading the real one.
  final _container = ProviderContainer(
    overrides: [
      djApiProvider.overrideWithValue(_PreviewApi()),
      authProvider.overrideWith(_SignedIn.new),
      isAnonymousProvider.overrideWithValue(false),
      albumPicksEnabledProvider.overrideWithValue(true),
      playlistContextApiProvider.overrideWithValue(_PreviewContextApi()),
      // `--dart-define=MIXTAPE_PREVIEW_DJ_PAUSED=true`: every composer in
      // its paused state (the DJ paused kill switch).
      if (MixesPreview.djPaused) djStatusProvider.overrideWith(_PausedDj.new),
      // `shell-update` / `shell-update-applied`: the update note on Home and
      // You (the root's update state is the app's, not this container's).
      ...updatePreviewOverrides(
        const String.fromEnvironment('MIXTAPE_PREVIEW'),
      ),
      // `--dart-define=MIXTAPE_PREVIEW_SOURCES=apple|spotify|both|history`:
      // Library and Add your music on made-up sources.
      if (_previewSources.isNotEmpty)
        onboardingProvider.overrideWith(_PreviewOnboarding.new),
      if (MixesPreview.pushAsk) ...[
        pushChannelProvider.overrideWithValue(_PreviewPushChannel()),
        pushAskStoreProvider.overrideWithValue(InMemoryPushAskStore()),
      ],
    ],
  );

  @override
  void initState() {
    super.initState();
    _container.listen(appUpdateMonitorProvider, (_, _) {});
    // After the first frame: a provider must not change while the tree is
    // being built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The pop-up asks on Home only with no turn out.
      if (!mounted || MixesPreview.pushAsk) return;
      final activity = _container.read(mixActivityProvider.notifier);
      activity.beginNewMix('Sunrise run, steady 170 bpm');
      activity.beginTurn('a1');
      activity.beginTurn('a2')(ready: true);
    });
  }

  @override
  void dispose() {
    _container.dispose();
    super.dispose();
  }

  // A navigator of its own too, so the screens Mixes pushes (Archived, a
  // conversation) sit under the preview's container rather than the app's.
  @override
  Widget build(BuildContext context) => UncontrolledProviderScope(
    container: _container,
    child: Navigator(
      onGenerateRoute: (_) => MaterialPageRoute(
        builder: (_) =>
            MixesPreview.shell ? const ShellScreen() : const MixesScreen(),
      ),
    ),
  );
}

class _PausedDj extends DjStatusNotifier {
  @override
  DjStatus build() => DjStatus.paused;
}

class _SignedIn extends AuthNotifier {
  @override
  AuthStatus build() => AuthStatus.session;
}

/// Answers the calls the Mixes tab makes; anything else is not wired.
class _PreviewApi
    implements
        DjApi,
        DjTurnProgressSender,
        DjSharedMixes,
        DjTurnStopper,
        DjSessionDeleter {
  _PreviewApi() {
    final now = DateTime.now();
    const active = [
      ('Shaking Lagos Nonstop', '#d88c9a'),
      ("Cole's Flow State", '#5fb3a8'),
      ('Candlelit Confessions', '#e6b52e'),
      ('Basement Cipher Nights', '#7b4f8e'),
      ('Instrumental Flow State', '#8a9a3c'),
      ('Melancholic Euphoria on the Floor', '#c9b8d8'),
      ('Amber Afternoon Pages', '#e6b52e'),
      ('Midnight Confessions, Velvet Dreams', '#3c5fa8'),
      ('Afrobeat Revolution', '#e8b1b5'),
      ('Afrobeats Midnight Flow', '#5fb3a8'),
    ];
    const archived = [
      ('Rainy drive home', '#762d44'),
      ('Sunday reset', '#efbd91'),
      ('Deadline sprint, no lyrics', '#3c5fa8'),
    ];
    var i = 0;
    for (final (title, color) in active) {
      _sessions.add(
        DjSession(
          id: 'a$i',
          title: title,
          status: 'active',
          queueVersion: 1,
          updatedAt: now.subtract(Duration(minutes: 40 + 20 * i)),
          caseColor: color,
          shared: i == 1,
        ),
      );
      i++;
    }
    for (final (title, color) in archived) {
      _sessions.add(
        DjSession(
          id: 'z$i',
          title: title,
          status: 'archived',
          queueVersion: 1,
          updatedAt: now.subtract(Duration(days: i)),
          caseColor: color,
        ),
      );
      i++;
    }
  }

  final List<DjSession> _sessions = [];

  DjSession _replace(String id, DjSession Function(DjSession) change) {
    final index = _sessions.indexWhere((s) => s.id == id);
    final next = change(_sessions[index]);
    _sessions[index] = next;
    return next;
  }

  DjSession _copy(
    DjSession s, {
    String? status,
    String? title,
    String? color,
  }) => DjSession(
    id: s.id,
    title: title ?? s.title,
    status: status ?? s.status,
    queueVersion: s.queueVersion,
    updatedAt: s.updatedAt,
    caseColor: color ?? s.caseColor,
    kind: s.kind,
    pick: s.pick,
    shared: s.shared,
  );

  Future<void> get _latency =>
      Future.delayed(const Duration(milliseconds: 350));

  @override
  Future<List<DjSession>> listSessions() async {
    await _latency;
    return List.of(_sessions);
  }

  @override
  Future<DjSession> setStatus(String id, String status) async {
    await _latency;
    return _replace(id, (s) => _copy(s, status: status));
  }

  @override
  Future<DjSession> renameSession(String id, String title) async {
    await _latency;
    return _replace(id, (s) => _copy(s, title: title));
  }

  @override
  Future<DjSession> setCaseColor(String id, String caseColor) async {
    await _latency;
    return _replace(id, (s) => _copy(s, color: caseColor));
  }

  @override
  Future<List<String>> deleteSessions(List<String> ids) async {
    await _latency;
    _sessions.removeWhere((s) => ids.contains(s.id));
    return ids;
  }

  @override
  Future<List<ListenLaterEntry>> listListenLater() async {
    await _latency;
    // No real Apple artwork here, so each cover is its tint; signed in, the
    // shelf draws the cover the server stored from Apple Music.
    AlbumArtwork tint(String hex) => AlbumArtwork(url: '', bgColor: hex);
    return [
      ListenLaterEntry(
        id: 'l1',
        title: 'Low Tide Hours',
        artist: 'Mara Ilesanmi',
        type: 'album',
        releaseYear: 2019,
        savedAt: DateTime(2026, 11, 1),
        artwork: tint('#3c5fa8'),
        reason: 'A live record, warm and unhurried.',
      ),
      ListenLaterEntry(
        id: 'l2',
        title: 'Kitchen Radio Sessions',
        artist: 'Odun & the Weather',
        type: 'live',
        releaseYear: 2021,
        savedAt: DateTime(2026, 10, 28),
        artwork: tint('#e6b52e'),
      ),
      ListenLaterEntry(
        id: 'l3',
        title: 'Nightshift Radio',
        artist: 'The Quiet Parade',
        type: 'ep',
        savedAt: DateTime(2026, 10, 2),
        listenedAt: DateTime(2026, 10, 12),
        artwork: tint('#762d44'),
      ),
    ];
  }

  @override
  Future<SessionDetail> getSession(String id) async {
    await _latency;
    final session = _sessions.firstWhere((s) => s.id == id);
    final at = DateTime.now().subtract(const Duration(minutes: 5));
    // The first two stay as they were (a new mix, one the DJ is on); every
    // other mix has a tape, so its strip, actions and Shape can be seen.
    if (id != 'a0' && id != 'a1') return _withTape(session, at);
    return SessionDetail(
      session: _copyAt(session, queueVersion: 0),
      messages: [
        DjMessage(
          id: '$id-1',
          role: 'user',
          content:
              'i want to extend my running playlist, songs that match the '
              'same bpm',
          createdAt: at,
        ),
        DjMessage(
          id: '$id-2',
          role: 'dj',
          content:
              'Found it, "running beats for the streets". Want me to build '
              'an extension from it, matching its BPM and vibe?',
          createdAt: at,
        ),
      ],
      queue: const [],
    );
  }

  /// Two turns and a 15-song tape at version 2.
  SessionDetail _withTape(DjSession session, DateTime at) {
    const songs = [
      ('Says', 'Nils Frahm'),
      ('On The Nature Of Daylight', 'Max Richter'),
      ('Infra 5', 'Max Richter'),
      ('Ambre', 'Nils Frahm'),
      ('November', 'Max Richter'),
      ("Vladimir's Blues", 'Max Richter'),
      ('Time', 'Hans Zimmer'),
      ('Cornfield Chase', 'Hans Zimmer'),
      ('Can You Hear the Music', 'Ludwig Göransson'),
      ('Them', 'Nils Frahm'),
      ('Spring 1', 'Max Richter'),
      ('Re', 'Nils Frahm'),
      ('Experience', 'Ludovico Einaudi'),
      ('Crown', 'Kendrick Lamar'),
      ('hey now', 'Kendrick Lamar'),
    ];
    return SessionDetail(
      session: _copyAt(session, queueVersion: 2),
      messages: [
        DjMessage(
          id: '${session.id}-1',
          role: 'user',
          content: 'focus music, no vocals',
          createdAt: at,
        ),
        DjMessage(
          id: '${session.id}-2',
          role: 'dj',
          content:
              'Got your focus queue going: 13 instrumental tracks for steady '
              'concentration, mostly ambient and neo-classical.',
          createdAt: at,
          queueVersion: 1,
        ),
        DjMessage(
          id: '${session.id}-3',
          role: 'user',
          content: 'swap in some Kendrick',
          createdAt: at,
        ),
        DjMessage(
          id: '${session.id}-4',
          role: 'dj',
          content:
              'Swapped in two Kendrick tracks at the end of the queue. Heads '
              'up: those have vocals.',
          createdAt: at,
          queueVersion: 2,
        ),
      ],
      queue: [
        for (var i = 0; i < songs.length; i++)
          QueueTrack(
            position: i,
            trackId: 'p${session.id}-$i',
            appleId: '${1000 + i}',
            title: songs[i].$1,
            artist: songs[i].$2,
            durationMs: 240000,
          ),
      ],
    );
  }

  /// How long a made-up turn takes.
  static const Duration _turnTime = Duration(seconds: 40);

  /// A made-up turn's progress, and when each arrives after the send.
  static const List<(Duration, TurnProgress)> _steps = [
    (Duration(milliseconds: 400), TurnStreamOpened()),
    (
      Duration(seconds: 5),
      TurnStep('digging', scope: 'catalogue', artists: ['Tems']),
    ),
    (Duration(seconds: 10), TurnStep('picking', artists: ['Tems'])),
    (Duration(seconds: 29), TurnStep('checking', genres: ['Afrobeats'])),
    (Duration(seconds: 32), TurnStep('pressing', count: 18)),
    (Duration(seconds: 34), TurnStep('labelling', title: 'Sunrise Run')),
    // Overtaken while the label's line holds: it never shows.
    (Duration(milliseconds: 34200), TurnStep('noting')),
    (Duration(seconds: 35), TurnStep('writing')),
  ];

  /// Every stop takes: the preview's turns write nothing until they land.
  @override
  Future<bool> stopTurn(String sessionId) async {
    await _latency;
    return true;
  }

  @override
  Future<TurnResult> sendMessageWithProgress(
    String id,
    String text, {
    void Function(TurnProgress progress)? onProgress,
  }) async {
    var at = Duration.zero;
    for (final (after, progress) in _steps) {
      await Future<void>.delayed(after - at);
      at = after;
      onProgress?.call(progress);
    }
    await Future<void>.delayed(_turnTime - at);
    return _reply(id);
  }

  @override
  Future<TurnResult> sendMessage(String id, String text) async {
    await Future<void>.delayed(_turnTime);
    return _reply(id);
  }

  TurnResult _reply(String id) {
    // A mix with a tape keeps it (one version on), so a turn sent from the
    // tape can be watched landing there.
    final tape = id == 'a0' || id == 'a1'
        ? null
        : _withTape(
            _sessions.firstWhere((s) => s.id == id),
            DateTime.now(),
          );
    return TurnResult(
      djMessage: DjMessage(
        id: '$id-${DateTime.now().millisecondsSinceEpoch}',
        role: 'dj',
        content: 'Here is a made-up reply: the preview has no DJ.',
        createdAt: DateTime.now(),
        queueVersion: tape == null ? null : 3,
      ),
      queue: tape?.queue ?? const [],
      queueVersion: tape == null ? 0 : 3,
    );
  }

  @override
  Future<void> postSessionEvent(String sessionId, String type) async {}

  DjSession _copyAt(DjSession s, {required int queueVersion}) => DjSession(
    id: s.id,
    title: s.title,
    status: s.status,
    queueVersion: queueVersion,
    updatedAt: s.updatedAt,
    caseColor: s.caseColor,
    kind: s.kind,
    pick: s.pick,
  );

  final Set<String> _removedShares = {};

  @override
  Future<SharedMix> getSharedMix(String token) async {
    await _latency;
    if (token != MixesPreview.sharedToken) {
      throw const SharedMixGoneException(SharedMixGoneReason.revoked);
    }
    const songs = [
      ('Midnight City', 'M83', '1'),
      ('Nightcall', 'Kavinsky', '2'),
      ('Electric Feel', 'MGMT', null),
      ('Feels Like We Only Go Backwards', 'Tame Impala', '4'),
      ('Dreams', 'Fleetwood Mac', '5'),
      ('Redbone', 'Childish Gambino', '6'),
      ('Ivy', 'Frank Ocean', null),
      ('Pink + White', 'Frank Ocean', '8'),
      ('Kiss of Life', 'Sade', '9'),
      ('Teardrop', 'Massive Attack', '10'),
    ];
    return SharedMix(
      token: token,
      title: 'Late drive, windows down',
      caseColor: '#bc5734',
      sharerName: 'Ada',
      sharedAt: DateTime.now().subtract(const Duration(hours: 2)),
      isOwner: false,
      tracks: [
        for (final (title, artist, id) in songs)
          SharedMixTrack(
            title: title,
            artist: artist,
            durationMs: 246000,
            appleId: id,
          ),
      ],
    );
  }

  @override
  Future<void> saveSharedMix(String token) async {
    await _latency;
    _removedShares.remove(token);
  }

  @override
  Future<void> removeSharedMix(String token) async {
    await _latency;
    _removedShares.add(token);
  }

  @override
  Future<List<SharedMixRow>> listSharedMixes() async {
    await _latency;
    final now = DateTime.now();
    final rows = [
      SharedMixRow(
        token: MixesPreview.sharedToken,
        title: 'Late drive, windows down',
        caseColor: '#bc5734',
        sharerName: 'Ada',
        savedAt: now.subtract(const Duration(hours: 2)),
        trackCount: 10,
        durationMs: 2460000,
      ),
      SharedMixRow(
        token: MixesPreview.goneToken,
        title: 'Saturday Kitchen',
        caseColor: '#5fb3a8',
        savedAt: now.subtract(const Duration(days: 2)),
        trackCount: 14,
        durationMs: 3120000,
      ),
    ];
    return [
      for (final row in rows)
        if (!_removedShares.contains(row.token)) row,
    ];
  }

  @override
  Future<ShareLinkResult> shareSession(String sessionId) async {
    await _latency;
    return const ShareLinkResult(
      token: MixesPreview.sharedToken,
      url: 'https://miixtape.netlify.app/m/${MixesPreview.sharedToken}',
    );
  }

  @override
  Future<void> stopSharing(String sessionId) => _latency;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('not wired in the Mixes preview');
}

/// Every made-up mix wears the same attached playlist.
class _PreviewContextApi implements PlaylistContextApi {
  static const _seed = PlaylistSeedState(
    playlistId: 'p1',
    revision: 1,
    excludeSourceTracks: false,
    status: PlaylistSeedStatus.ready,
    name: 'running beats for the streets',
    source: null,
    fingerprint: null,
    updatedAt: null,
    entries: 24,
    resolvedEntries: 24,
    recordings: 24,
    profile: null,
  );

  /// Detaching takes it off that mix only, for this run.
  final Map<String, PlaylistSeedState> _changed = {};

  @override
  Future<PlaylistSeedState?> getSessionSeed(String sessionId) async =>
      _changed[sessionId] ?? _seed;

  /// Only detach is wired: there is no library here to pick another from.
  @override
  Future<PlaylistSeedState> selectSeed(
    String sessionId, {
    required String? playlistId,
    required int expectedRevision,
    bool excludeSourceTracks = false,
  }) async {
    if (playlistId != null) {
      throw UnimplementedError('picking is not wired in the Mixes preview');
    }
    return _changed[sessionId] = PlaylistSeedState(
      playlistId: null,
      revision: expectedRevision + 1,
      excludeSourceTracks: false,
      status: PlaylistSeedStatus.none,
      name: null,
      source: null,
      fingerprint: null,
      updatedAt: null,
      entries: 0,
      resolvedEntries: 0,
      recordings: 0,
      profile: null,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('not wired in the Mixes preview');
}

const String _previewSources = String.fromEnvironment(
  'MIXTAPE_PREVIEW_SOURCES',
);

/// Made-up music sources for the Library and Add your music previews.
class _PreviewOnboarding extends OnboardingNotifier {
  @override
  Future<OnboardingState> build() async {
    final synced = DateTime(2026, 11, 2);
    final apple = _previewSources != 'spotify';
    final spotify = _previewSources == 'spotify' || _previewSources == 'both';
    return OnboardingState(
      userId: 'preview',
      sources: [
        if (apple)
          MusicSource(
            source: 'apple_live',
            connectedAt: synced,
            lastImportedAt: synced,
            ledgerFrom: null,
            ledgerTo: null,
          ),
        if (_previewSources == 'history')
          MusicSource(
            source: 'apple_export',
            connectedAt: DateTime(2026, 10, 28),
            lastImportedAt: DateTime(2026, 10, 28),
            ledgerFrom: '2019-03-01',
            ledgerTo: '2026-10-20',
          ),
        if (spotify)
          MusicSource(
            source: 'spotify_export',
            connectedAt: DateTime(2026, 10, 12),
            lastImportedAt: DateTime(2026, 10, 12),
            ledgerFrom: '2018-01-01',
            ledgerTo: '2026-10-01',
            packages: const ['spotify_exportify'],
          ),
      ],
      hasLibrary: apple,
      chosenService: apple ? 'apple' : 'spotify',
      markedRequestedAt: null,
      interviewCompletedAt: synced,
      importCompletedAt: synced,
    );
  }

  @override
  Future<bool> refresh() async => true;
}

/// `mixtape/push` for the `push-ask` preview: not asked yet, a made-up
/// Allow after a beat, and no token, so nothing is sent to a server.
class _PreviewPushChannel implements PushChannel {
  PushStatus _status = PushStatus.notDetermined;

  @override
  Future<PushStatus> status() async => _status;

  @override
  Future<PushStatus> requestAuthorization() async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    return _status = PushStatus.authorized;
  }

  @override
  Future<String> register() async =>
      throw UnsupportedError('no registration in the preview');

  @override
  Future<String?> appVersion() async => null;

  @override
  Future<String?> environment() async => null;

  @override
  Future<void> setVisibleSession(String? sessionId) async {}

  @override
  Future<PushTap?> initialTap() async => null;

  @override
  Stream<PushTap> get taps => const Stream.empty();
}
