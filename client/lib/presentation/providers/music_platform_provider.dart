import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/listening/listening_models.dart' show OnboardingState;
import '../../data/settings/music_platform_store.dart';
import '../widgets/library_sync_dialog.dart' show appleLiveSource;
import 'onboarding_provider.dart';

export '../../data/settings/music_platform_store.dart';

/// The keychain-backed store; tests override it with the in-memory one.
final musicPlatformStoreProvider = Provider<MusicPlatformStore>(
  (ref) => SecureMusicPlatformStore(),
);

/// The platform a service the listener already told us about implies:
/// `chosenService` apple/spotify first, then a live Apple library. Null when
/// nothing says.
MusicPlatform? platformFromOnboarding(OnboardingState? onboarding) {
  switch (onboarding?.chosenService) {
    case 'apple':
      return MusicPlatform.apple;
    case 'spotify':
      return MusicPlatform.spotify;
  }
  return appleLiveSource(onboarding) != null ? MusicPlatform.apple : null;
}

/// The device's platform (decisions 1–2 of
/// `docs/superpowers/specs/2026-11-09-one-platform-play-design.md`).
///
/// Resolution: the stored answer; else the service onboarding knows about
/// ([platformFromOnboarding]), written silently to the store; else null.
/// Null reads as Apple Music on every mix (the one platform the app can
/// play), and [unknown] tells the shell to ask once.
///
/// Not user-scoped: a device preference. It listens to onboarding rather
/// than watching it, so an auth transition (onboarding reloading) never
/// forgets an answer.
class MusicPlatformNotifier extends Notifier<MusicPlatform?> {
  bool _chosen = false;
  bool _loaded = false;
  Completer<void> _ready = Completer<void>();

  /// Completes once the store has been read (or failed to be).
  Future<void> get ready => _ready.future;

  /// Nothing tells us the platform: the store has been read and holds
  /// nothing, and onboarding has answered with no service. Not unknown while
  /// either is still loading, nor when onboarding failed.
  bool get unknown {
    if (!_loaded || state != null) return false;
    final onboarding = ref.read(onboardingProvider);
    return onboarding.hasValue && !onboarding.hasError;
  }

  @override
  MusicPlatform? build() {
    _chosen = false;
    _loaded = false;
    _ready = Completer<void>();
    ref.listen<AsyncValue<OnboardingState>>(
      onboardingProvider,
      (_, next) => _adopt(next.value),
    );
    unawaited(_load());
    return null;
  }

  Future<void> _load() async {
    final store = ref.read(musicPlatformStoreProvider);
    MusicPlatform? stored;
    try {
      stored = await store.read();
    } catch (_) {
      // A device that cannot remember asks (or infers) every launch.
    }
    if (!ref.mounted) return;
    _loaded = true;
    // A choice made while the read was in flight wins over the old value.
    if (!_chosen && stored != null) {
      state = stored;
    } else {
      _adopt(ref.read(onboardingProvider).value);
    }
    if (!_ready.isCompleted) _ready.complete();
  }

  /// Takes the platform onboarding implies, when nothing is set yet.
  void _adopt(OnboardingState? onboarding) {
    if (!_loaded || _chosen || state != null) return;
    final known = platformFromOnboarding(onboarding);
    if (known == null) return;
    state = known;
    unawaited(_write(known));
  }

  Future<void> _write(MusicPlatform platform) async {
    try {
      await ref.read(musicPlatformStoreProvider).write(platform);
    } catch (_) {
      // Remembering is a nicety; this session still uses the platform.
    }
  }

  /// Makes [platform] the device's, here and in the store.
  Future<void> choose(MusicPlatform platform) async {
    _chosen = true;
    state = platform;
    await _write(platform);
  }
}

final musicPlatformProvider =
    NotifierProvider<MusicPlatformNotifier, MusicPlatform?>(
      MusicPlatformNotifier.new,
    );
