/// Step 1 of 3, Which do you use? (board frame B1). Replaces the once-only
/// service gate of 2026-09-01; Library's Add your music opens it too.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/listening/listening_models.dart';
import '../../providers/first_run_flags_provider.dart';
import '../../widgets/foundation/service_marks.dart';
import 'choose_method_screen.dart';
import 'first_run_flow.dart';
import 'step_scaffold.dart';

class ChooseServiceScreen extends ConsumerWidget {
  const ChooseServiceScreen({super.key, this.mode = AddMusicMode.firstRun});

  final AddMusicMode mode;

  static const String headline = 'Which do you use?';
  static const String line = 'Mixes get better when the DJ knows your music.';
  static const String skipLabel = 'Skip for now';

  static const Key appleKey = Key('choose-apple');
  static const Key spotifyKey = Key('choose-spotify');
  static const Key skipKey = Key('choose-skip');

  void _choose(BuildContext context, MusicService service) {
    recordFirstRun(context, mode, FunnelEventType.choseService);
    unawaited(
      pushFirstRunPage<void>(
        context,
        ChooseMethodScreen(service: service, mode: mode),
        name: '${addMusicRoutePrefix}2',
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Skip's destination hangs on the server's flags; reading them here
    // (Welcome has usually started the read already) keeps them for Skip.
    if (mode == AddMusicMode.firstRun) ref.watch(firstRunFlagsProvider);
    return _build(context);
  }

  Widget _build(BuildContext context) => StepScaffold(
    background: FirstRunBackground.step1,
    headline: headline,
    step: 1,
    line: line,
    actions: [
      FirstRunPill(
        key: appleKey,
        label: 'Apple Music',
        leading: const AppleMusicMark(size: 22, color: FirstRunColors.ink),
        onPressed: () => _choose(context, MusicService.apple),
      ),
      FirstRunPill(
        key: spotifyKey,
        label: 'Spotify',
        leading: const SpotifyMark(size: 22, color: FirstRunColors.ink),
        onPressed: () => _choose(context, MusicService.spotify),
      ),
    ],
    // From Library the back button is the way out; "Skip" belongs to the
    // first run, where it leads on to Who do you love?, or to the prompt
    // page when the server never refuses ([skipAddMusic]).
    foot: mode == AddMusicMode.firstRun
        ? FootLink(
            key: skipKey,
            label: skipLabel,
            onPressed: () => unawaited(skipAddMusic(context, mode)),
          )
        : null,
  );
}
