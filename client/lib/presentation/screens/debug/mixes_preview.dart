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
/// stopped share.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/dj/dj_api.dart';
import '../../../data/dj/dj_models.dart';
import '../../../data/playlists/playlist_context_api.dart';
import '../../../data/playlists/playlist_context_models.dart';
import '../../providers/auth_provider.dart';
import '../../providers/capabilities_provider.dart';
import '../../providers/dj_providers.dart';
import '../../providers/mix_activity_provider.dart';
import '../../providers/playlist_context_provider.dart';
import '../mixes_screen.dart';

class MixesPreview extends StatefulWidget {
  const MixesPreview({super.key});

  /// A made-up share from Ada, ten songs, two with no Apple Music match.
  static const String sharedToken = 'PreviewShareAdaLateDrv';

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
    ],
  );

  @override
  void initState() {
    super.initState();
    // After the first frame: a provider must not change while the tree is
    // being built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
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
      onGenerateRoute: (_) =>
          MaterialPageRoute(builder: (_) => const MixesScreen()),
    ),
  );
}

class _SignedIn extends AuthNotifier {
  @override
  AuthStatus build() => AuthStatus.session;
}

/// Answers the calls the Mixes tab makes; anything else is not wired.
class _PreviewApi implements DjApi, DjTurnProgressSender, DjSharedMixes {
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
    return TurnResult(
      djMessage: DjMessage(
        id: '$id-${DateTime.now().millisecondsSinceEpoch}',
        role: 'dj',
        content: 'Here is a made-up reply: the preview has no DJ.',
        createdAt: DateTime.now(),
      ),
      queue: const [],
      queueVersion: 0,
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

  final Set<String> _savedShares = {};

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
    _savedShares.add(token);
  }

  @override
  Future<void> removeSharedMix(String token) async {
    await _latency;
    _savedShares.remove(token);
  }

  @override
  Future<List<SharedMixRow>> listSharedMixes() async {
    await _latency;
    return const [];
  }

  @override
  Future<ShareLinkResult> shareSession(String sessionId) =>
      throw UnimplementedError('not wired in the Mixes preview');

  @override
  Future<void> stopSharing(String sessionId) =>
      throw UnimplementedError('not wired in the Mixes preview');

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

  @override
  Future<PlaylistSeedState?> getSessionSeed(String sessionId) async => _seed;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('not wired in the Mixes preview');
}
