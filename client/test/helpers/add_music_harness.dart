// The providers the music door and its router read, faked: a signed-in
// listener, the onboarding read, the device's platform, the library sync and
// the import flow's picker, with no platform channel touched.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/token_store.dart';
import 'package:mixtape/data/library/library_sync_service.dart';
import 'package:mixtape/data/listening/listening_models.dart';
import 'package:mixtape/data/onboarding/funnel_once_store.dart';
import 'package:mixtape/data/onboarding/service_preference_store.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/device_providers.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/library_sync_provider.dart';
import 'package:mixtape/presentation/providers/listening_import_provider.dart';
import 'package:mixtape/presentation/providers/music_platform_provider.dart';
import 'package:mixtape/presentation/providers/onboarding_provider.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';

import 'fake_import_service.dart';
import 'fake_listening_api.dart';
import 'onboarding_harness.dart';

const LibrarySyncSummary landedSummary = LibrarySyncSummary(
  songs: 120,
  playlists: 3,
  entries: 0,
  resolvedEntries: 0,
  unresolvedEntries: 0,
);

/// The library sync, driven by the test. [land] does what the real one does
/// as a run lands: onboarding is invalidated, then the result is set.
class ScriptedSync extends LibrarySyncNotifier {
  ScriptedSync(this.initial);

  /// What the provider holds before anything is asked of it.
  SyncState initial;
  int runs = 0;

  @override
  SyncState build() {
    ref.watch(authProvider);
    return initial;
  }

  /// A determinate start, so the alert's bar does not keep a settle running.
  @override
  Future<void> sync() async {
    runs++;
    state = const SyncRunning(0.1);
  }

  void progress(double value) => state = SyncRunning(value);
  void fail() => state = const SyncFailed('Sync failed. Try again.');
  void deny() => state = const SyncFailed(
    'Music library access was denied. Enable it in Settings.',
    accessDenied: true,
  );
  void cancel() => state = const SyncIdle();

  void land() {
    ref.invalidate(onboardingProvider);
    state = const SyncDone(landedSummary);
  }
}

/// The device's platform pinned for the test; null is "nothing known".
class FixedPlatform extends MusicPlatformNotifier {
  FixedPlatform(this._platform);
  final MusicPlatform? _platform;

  @override
  MusicPlatform? build() => _platform;
}

class AddMusicHarness {
  AddMusicHarness({
    this.platform,
    OnboardingState? onboarding,
    SyncState sync = const SyncIdle(),
  }) : listening = FakeListeningApi(
         onboarding: onboarding ?? onboardingState(),
       ),
       sync = ScriptedSync(sync);

  final MusicPlatform? platform;
  final FakeListeningApi listening;
  final ScriptedSync sync;
  final FakeArchivePicker picker = FakeArchivePicker();
  final FakeLinkOpener links = FakeLinkOpener();

  List<FunnelEventType> get events => listening.funnelEvents;

  late final ProviderContainer container = () {
    final c = ProviderContainer(
      overrides: [
        authProvider.overrideWith(() => TestAuthNotifier(AuthStatus.session)),
        tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
        djApiProvider.overrideWithValue(BareDjApi()),
        listeningApiProvider.overrideWithValue(listening),
        servicePreferenceStoreProvider.overrideWithValue(
          InMemoryServicePreferenceStore(),
        ),
        funnelOnceStoreProvider.overrideWithValue(InMemoryFunnelOnceStore()),
        reminderSchedulerProvider.overrideWithValue(FakeReminderScheduler()),
        linkOpenerProvider.overrideWithValue(links.call),
        librarySyncProvider.overrideWith(() => sync),
        musicPlatformProvider.overrideWith(() => FixedPlatform(platform)),
        listeningImportServiceProvider.overrideWithValue(FakeImportService()),
        archivePickerProvider.overrideWithValue(picker),
        openedArchiveSourceProvider.overrideWithValue(
          FakeOpenedArchiveSource(),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }();

  /// Pumps [child] on a 390 x 844 phone in the app's theme.
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: brightness == Brightness.dark
              ? MixtapeTheme.dark()
              : MixtapeTheme.light(),
          builder: (context, app) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: app!,
          ),
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }
}
