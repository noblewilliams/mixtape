/// Step 2 of 3, How do you want to add it? (board frames B2 and B3).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'doing_screen.dart';
import 'first_run_flow.dart';
import 'step_scaffold.dart';

enum MusicService { apple, spotify }

/// How the music comes in: Step 3's four pages.
enum AddMethod { appleSync, appleExport, exportify, spotifyExport }

class ChooseMethodScreen extends StatelessWidget {
  const ChooseMethodScreen({
    super.key,
    required this.service,
    this.mode = AddMusicMode.firstRun,
  });

  final MusicService service;
  final AddMusicMode mode;

  static const String headline = 'How do you want to add it?';
  static const String spotifyLine =
      'Exportify brings your playlists and likes. The data export adds what '
      'you actually played.';
  static const String foot = 'You can add more later from Library.';

  static const Key appleSyncKey = Key('method-apple-sync');
  static const Key appleExportKey = Key('method-apple-export');
  static const Key exportifyKey = Key('method-exportify');
  static const Key spotifyExportKey = Key('method-spotify-export');

  void _choose(BuildContext context, AddMethod method) => unawaited(
    pushFirstRunPage<void>(
      context,
      DoingScreen(method: method, mode: mode),
      name: '${addMusicRoutePrefix}3',
    ),
  );

  @override
  Widget build(BuildContext context) {
    final apple = service == MusicService.apple;
    return StepScaffold(
      background: FirstRunBackground.step2,
      headline: headline,
      step: 2,
      line: apple ? null : spotifyLine,
      actions: apple
          ? [
              FirstRunPill(
                key: appleSyncKey,
                label: 'Sync my library',
                onPressed: () => _choose(context, AddMethod.appleSync),
              ),
              FirstRunPill(
                key: appleExportKey,
                label: 'Upload an Apple export',
                onPressed: () => _choose(context, AddMethod.appleExport),
              ),
            ]
          : [
              FirstRunPill(
                key: exportifyKey,
                label: 'Exportify, a few minutes',
                onPressed: () => _choose(context, AddMethod.exportify),
              ),
              FirstRunPill(
                key: spotifyExportKey,
                label: 'Spotify data export, a few days',
                onPressed: () => _choose(context, AddMethod.spotifyExport),
              ),
            ],
      foot: const FootNote(foot),
    );
  }
}
