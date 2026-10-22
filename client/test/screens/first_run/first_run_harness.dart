import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/config/config_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/library/library_sync_service.dart';
import 'package:mixtape/data/onboarding/funnel_once_store.dart';
import 'package:mixtape/data/onboarding/service_preference_store.dart';
import 'package:mixtape/data/playlists/playlist_context_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/device_providers.dart';
import 'package:mixtape/presentation/providers/first_run_flags_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/listening_import_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';

import '../../helpers/fake_import_service.dart';
import '../../helpers/fake_listening_api.dart';
import '../../helpers/onboarding_harness.dart';

/// Auth for the first-run pages: starts where told and counts anonymous
/// sign-ins, which move noSession to an anonymous session as the real one
/// does.
class FirstRunAuth extends AuthNotifier {
  FirstRunAuth(this._initial, {bool anonymous = false}) : _anon = anonymous;

  final AuthStatus _initial;
  bool _anon;
  int anonymousSignIns = 0;

  /// Holds the sign-in open when set.
  Completer<void>? gate;
  Object? failWith;

  @override
  AuthStatus build() => _initial;

  @override
  bool get isAnonymous => _anon;

  /// What the real sign-out does to the state, without the keychain.
  @override
  Future<void> signOut() async {
    _anon = false;
    state = AuthStatus.noSession;
  }

  @override
  Future<void> signInAnonymously() async {
    if (state == AuthStatus.session) return;
    anonymousSignIns++;
    final hold = gate;
    if (hold != null) await hold.future;
    final failure = failWith;
    if (failure != null) throw failure;
    _anon = true;
    state = AuthStatus.session;
  }
}

/// A DjApi whose createSession records the prompt and answers with a new
/// session; everything else answers nothing.
class FirstRunDjApi extends BareDjApi {
  final List<String> prompts = [];
  String nextId = 'session-new';
  Object? failWith;

  /// Holds the DJ turn open when set, as a real 20 to 60 second turn does.
  Completer<void>? gate;

  @override
  Future<List<DjSession>> listSessions() async => [];

  @override
  Future<SessionDetail> createSession(
    String prompt, {
    InitialPlaylistSeed? playlistSeed,
    SessionKind kind = SessionKind.mix,
  }) async {
    prompts.add(prompt);
    final hold = gate;
    if (hold != null) await hold.future;
    final failure = failWith;
    if (failure != null) throw failure;
    return SessionDetail(
      session: DjSession(
        id: nextId,
        title: 'New mix',
        status: 'active',
        queueVersion: 1,
        updatedAt: DateTime(2026, 10, 20),
      ),
      messages: const [],
      queue: const [],
    );
  }

  @override
  Future<SessionDetail> getSession(String id) async => SessionDetail(
    session: DjSession(
      id: id,
      title: 'New mix',
      status: 'active',
      queueVersion: 1,
      updatedAt: DateTime(2026, 10, 20),
    ),
    messages: const [],
    queue: const [],
  );

  @override
  Future<void> postSessionEvent(String sessionId, String type) async {}
}

/// `GET /health`'s flags, answered with [answer] (or thrown [failWith]); counts reads and notes whether an
/// anonymous listener existed when each was made.
class FakeConfigApi implements ConfigApi {
  FakeConfigApi(this._auth);

  final FirstRunAuth _auth;
  FirstRunFlags answer = FirstRunFlags.off;
  Object? failWith;
  int calls = 0;

  /// The anonymous sign-ins made before each read, in order.
  final List<int> signInsAtRead = [];

  @override
  Future<FirstRunFlags> flags() async {
    calls++;
    signInsAtRead.add(_auth.anonymousSignIns);
    final failure = failWith;
    if (failure != null) throw failure;
    return answer;
  }
}

/// The library sync, driven by the test.
class ControlledSync extends LibrarySyncNotifier {
  int runs = 0;

  /// What the provider holds before this page asks for anything: a result
  /// left from an earlier run, say.
  SyncState initial = const SyncIdle();

  @override
  SyncState build() {
    ref.watch(authProvider);
    return initial;
  }

  @override
  Future<void> sync() async {
    runs++;
    state = const SyncRunning(0);
  }

  void progress(int songs) => state = SyncRunning(0.3, songs: songs);
  void fail() => state = const SyncFailed('Sync failed. Try again.');
  void deny() => state = const SyncFailed(
    'Music library access was denied. Enable it in Settings.',
    accessDenied: true,
  );
  void done(int songs) => state = SyncDone(
    LibrarySyncSummary(
      songs: songs,
      playlists: 0,
      entries: 0,
      resolvedEntries: 0,
      unresolvedEntries: 0,
    ),
  );
}

class FirstRunHarness {
  FirstRunHarness({
    AuthStatus status = AuthStatus.noSession,
    bool anonymous = false,
  }) : auth = FirstRunAuth(status, anonymous: anonymous) {
    config = FakeConfigApi(auth);
  }

  final FirstRunAuth auth;
  late final FakeConfigApi config;
  final FirstRunDjApi dj = FirstRunDjApi();
  final FakeListeningApi listening = FakeListeningApi(
    onboarding: onboardingState(userId: 'anon-1'),
  );
  final FakeReminderScheduler reminders = FakeReminderScheduler();
  final FakeLinkOpener links = FakeLinkOpener();
  final FakeArchivePicker picker = FakeArchivePicker();
  final ControlledSync sync = ControlledSync();
  final InMemoryServicePreferenceStore prefs = InMemoryServicePreferenceStore();

  List<Override> get overrides => [
    authProvider.overrideWith(() => auth),
    tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
    djApiProvider.overrideWithValue(dj),
    configApiProvider.overrideWithValue(config),
    listeningApiProvider.overrideWithValue(listening),
    reminderSchedulerProvider.overrideWithValue(reminders),
    servicePreferenceStoreProvider.overrideWithValue(prefs),
    funnelOnceStoreProvider.overrideWithValue(InMemoryFunnelOnceStore()),
    linkOpenerProvider.overrideWithValue(links.call),
    librarySyncProvider.overrideWith(() => sync),
    listeningImportServiceProvider.overrideWithValue(FakeImportService()),
    archivePickerProvider.overrideWithValue(picker),
    openedArchiveSourceProvider.overrideWithValue(FakeOpenedArchiveSource()),
  ];

  late final ProviderContainer container = () {
    final c = ProviderContainer(overrides: overrides);
    addTearDown(c.dispose);
    return c;
  }();

  /// Pumps [home] on a 390 x 844 phone in the app's theme.
  Future<void> pump(WidgetTester tester, Widget home) async {
    phone(tester);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: MixtapeTheme.light(), home: home),
      ),
    );
    await tester.pumpAndSettle();
  }
}

void phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

/// Reduced motion for the test: the cassette's hubs and the composer's
/// rotation stop, so a settle finishes.
void reduceMotion() {
  setUp(
    () =>
        TestWidgetsFlutterBinding.ensureInitialized()
            .platformDispatcher
            .accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
          disableAnimations: true,
        ),
  );
  tearDown(
    () => TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
        .clearAccessibilityFeaturesTestValue(),
  );
}

/// The [TextButton] at [key] is enabled.
bool enabled(WidgetTester tester, Key key) =>
    tester
        .widget<TextButton>(
          find.descendant(
            of: find.byKey(key),
            matching: find.byType(TextButton),
          ),
        )
        .onPressed !=
    null;
