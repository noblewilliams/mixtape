/// The two sheets behind Play for a Spotify listener (decisions 2026-11-06):
///
/// * [WhereYouListenSheet] — the first Play from a listener with no known
///   service asks Spotify or Apple Music, once; the answer becomes the
///   remembered Play destination.
/// * [SpotifyHandoffSheet] — the first Play on Spotify says what is about to
///   happen (copy the songs, open TuneMyMusic, paste) before it happens.
///
/// Both are the app's standard [showMixtapeSheet], laid out like the
/// first-mix sheet (`keep_sheet.dart`): a headline, one line, paper pills.
library;

import 'package:flutter/material.dart';

import '../../data/settings/play_destination_store.dart';
import '../screens/first_run/step_scaffold.dart' show FirstRunPill;
import '../theme/mixtape_theme.dart';
import 'foundation/mixtape_sheet.dart';

abstract final class WhereYouListenSheet {
  static const String headline = 'Where do you listen?';
  static const String line =
      'We’ll play your mixes there. You can change it any time in You.';
  static const String spotifyLabel = 'Spotify';
  static const String appleLabel = 'Apple Music';

  static const Key spotifyKey = Key('where-you-listen-spotify');
  static const Key appleKey = Key('where-you-listen-apple');
}

/// Asks where the listener listens. Spotify, [PlayDestination.here] for
/// Apple Music (the app's own player, which needs an Apple Music
/// subscription), or null when the sheet was closed without an answer.
Future<PlayDestination?> askWhereYouListen(BuildContext context) =>
    showMixtapeSheet<PlayDestination>(
      context,
      isScrollControlled: true,
      builder: (sheetContext) => _SheetBody(
        headline: WhereYouListenSheet.headline,
        line: WhereYouListenSheet.line,
        children: [
          FirstRunPill(
            key: WhereYouListenSheet.spotifyKey,
            label: WhereYouListenSheet.spotifyLabel,
            emphasis: true,
            onPressed: () =>
                Navigator.of(sheetContext).pop(PlayDestination.spotify),
          ),
          const SizedBox(height: 10),
          FirstRunPill(
            key: WhereYouListenSheet.appleKey,
            label: WhereYouListenSheet.appleLabel,
            onPressed: () =>
                Navigator.of(sheetContext).pop(PlayDestination.here),
          ),
        ],
      ),
    );

abstract final class SpotifyHandoffSheet {
  static const String headline = 'Make it a Spotify playlist';
  static const String goLabel = 'Copy songs and open TuneMyMusic';
  static const String cancelLabel = 'Cancel';

  static const Key goKey = Key('spotify-handoff-go');
  static const Key cancelKey = Key('spotify-handoff-cancel');

  /// What is about to happen, with the real count.
  static String lineFor(int count) => count == 1
      ? 'We’ll copy the song and open TuneMyMusic. Paste it in, connect '
            'Spotify, and it makes the playlist for you.'
      : 'We’ll copy your $count songs and open TuneMyMusic. Paste them '
            'in, connect Spotify, and it makes the playlist for you.';
}

/// The explainer before the first Spotify handoff. True to go ahead; false
/// for Cancel, the scrim or the handle.
Future<bool> confirmSpotifyHandoff(BuildContext context, int count) async {
  final go = await showMixtapeSheet<bool>(
    context,
    isScrollControlled: true,
    builder: (sheetContext) {
      final tokens = MixtapeSheet.tokensOf(sheetContext);
      return _SheetBody(
        headline: SpotifyHandoffSheet.headline,
        line: SpotifyHandoffSheet.lineFor(count),
        children: [
          FirstRunPill(
            key: SpotifyHandoffSheet.goKey,
            label: SpotifyHandoffSheet.goLabel,
            emphasis: true,
            onPressed: () => Navigator.of(sheetContext).pop(true),
          ),
          const SizedBox(height: 8),
          Center(
            child: TextButton(
              key: SpotifyHandoffSheet.cancelKey,
              onPressed: () => Navigator.of(sheetContext).pop(false),
              style: TextButton.styleFrom(
                foregroundColor: tokens.text,
                minimumSize: const Size(
                  MixtapeMetrics.minTarget,
                  MixtapeMetrics.minTarget,
                ),
              ),
              child: Text(
                SpotifyHandoffSheet.cancelLabel,
                style: tokens.body.copyWith(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: tokens.text,
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
  return go ?? false;
}

/// The shared layout: headline first in reading order, one line, then the
/// actions. 200 % text scrolls inside the sheet rather than overflowing it.
class _SheetBody extends StatelessWidget {
  const _SheetBody({
    required this.headline,
    required this.line,
    required this.children,
  });

  final String headline;
  final String line;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final tokens = MixtapeSheet.tokensOf(context);
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: headline,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              header: true,
              child: Text(
                headline,
                style: tokens.largeTitle.copyWith(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  height: 1.1,
                  letterSpacing: -0.6,
                  color: tokens.text,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              line,
              style: tokens.body.copyWith(
                fontSize: 16,
                height: 1.4,
                color: tokens.text,
              ),
            ),
            const SizedBox(height: 22),
            ...children,
          ],
        ),
      ),
    );
  }
}
