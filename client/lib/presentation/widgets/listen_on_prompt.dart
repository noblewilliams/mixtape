/// Ask once, on app open (decision 2 of
/// `docs/superpowers/specs/2026-11-09-one-platform-play-design.md`;
/// `docs/mockups/approved/2026-11-09-one-platform-play.md` → Ask once).
///
/// The shell wraps itself in [ListenOnPrompt]. The shell only mounts once the
/// first-run flow (and the name page) have handed off, so the question never
/// interrupts first run or sign-in. It opens the "Where do you listen?" sheet
/// on the root navigator (over the tabs, the dock and the side rail) when,
/// and only when, nothing tells us the device's platform
/// ([MusicPlatformNotifier.unknown]) — at most once per launch, never again
/// once answered (the answer is stored), and only after the AI-consent sheet
/// has had its turn.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/ai_consent_provider.dart';
import '../providers/music_platform_provider.dart';
import '../providers/onboarding_provider.dart';
import 'spotify_handoff_sheets.dart';

/// Whether this launch has already asked. Not user-scoped: a shell rebuilt
/// under an open sheet does not ask a second time this launch. A sheet
/// closed without an answer is not counted ([forget]).
class ListenOnAskedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void markAsked() => state = true;

  void forget() => state = false;
}

final listenOnAskedProvider = NotifierProvider<ListenOnAskedNotifier, bool>(
  ListenOnAskedNotifier.new,
);

class ListenOnPrompt extends ConsumerStatefulWidget {
  const ListenOnPrompt({super.key, required this.child, this.onShowingChanged});

  final Widget child;

  /// True when the sheet goes up, false when it comes down: the shell puts
  /// its bottom dock away meanwhile, since a root-navigator sheet is not a
  /// route on any tab.
  final ValueChanged<bool>? onShowingChanged;

  @override
  ConsumerState<ListenOnPrompt> createState() => _ListenOnPromptState();
}

class _ListenOnPromptState extends ConsumerState<ListenOnPrompt> {
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    // Anything that can settle the question re-checks it: the stored
    // platform, onboarding answering, the AI-consent sheet stepping aside.
    ref.listenManual(musicPlatformProvider, (_, _) => _schedule());
    ref.listenManual(onboardingProvider, (_, _) => _schedule());
    ref.listenManual(aiConsentNeededProvider, (_, _) => _schedule());
    ref.listenManual(aiConsentProvider, (_, _) => _schedule());
    ref.listenManual(aiConsentSettledProvider, (_, _) => _schedule());
    ref.listenManual(listenOnAskedProvider, (_, _) => _schedule());
    _schedule();
  }

  void _schedule() =>
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_check()));

  Future<void> _check() async {
    if (_checking || !mounted || ref.read(listenOnAskedProvider)) return;
    _checking = true;
    try {
      final platform = ref.read(musicPlatformProvider.notifier);
      await platform.ready;
      if (!mounted || ref.read(listenOnAskedProvider)) return;
      if (!platform.unknown) return;
      // The AI-consent sheet goes first; this one follows once it is down,
      // and not before `/me` has said whether it is needed at all.
      if (!ref.read(aiConsentSettledProvider)) return;
      if (ref.read(aiConsentNeededProvider) &&
          !ref.read(aiConsentProvider).dismissed) {
        return;
      }
      final asked = ref.read(listenOnAskedProvider.notifier);
      asked.markAsked();
      widget.onShowingChanged?.call(true);
      final answer = await askWhereYouListen(context);
      if (mounted) widget.onShowingChanged?.call(false);
      // The notifiers outlive this widget: an answer given as the shell was
      // replaced still counts, and a sheet closed without one is asked again.
      if (answer != null) {
        await platform.choose(answer);
      } else {
        asked.forget();
      }
    } finally {
      _checking = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
