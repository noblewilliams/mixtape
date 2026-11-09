/// The two platform sheets (decisions 2026-11-06; one platform,
/// `docs/mockups/approved/2026-11-09-one-platform-play.md`):
///
/// * [WhereYouListenSheet] — asked once over the shell when nothing tells us
///   the device's platform (`listen_on_prompt.dart`): Apple Music or
///   Spotify, and nothing but an answer closes it.
/// * [SpotifyHandoffSheet] — the first Spotify Create playlist on a device
///   says what is about to happen (copy the songs, open TuneMyMusic, paste)
///   before it happens.
///
/// Both are the app's standard [showMixtapeSheet], laid out like the
/// first-mix sheet (`keep_sheet.dart`): a headline, one line, paper pills.
library;

import 'package:flutter/material.dart';

import '../../data/settings/music_platform_store.dart';
import '../screens/first_run/step_scaffold.dart'
    show FirstRunColors, FirstRunPill;
import '../theme/mixtape_theme.dart';
import 'foundation/mixtape_sheet.dart';
import 'foundation/service_marks.dart';

abstract final class WhereYouListenSheet {
  static const String headline = 'Where do you listen?';
  static const String line =
      'Your mixes play or save there. You can change it any time in You.';
  static const String spotifyLabel = 'Spotify';
  static const String appleLabel = 'Apple Music';

  static const Key spotifyKey = Key('where-you-listen-spotify');
  static const Key appleKey = Key('where-you-listen-apple');

  /// `.tape.sp .mk, .fpill .mk`: the marks beside the pill labels.
  static const double markSize = 18;
}

/// Asks where the listener listens: Apple Music (listed first, the one
/// platform the app can play) or Spotify, two equal pills with their marks.
/// The answer decides every mix's actions, so there is no grab handle and
/// neither the scrim, a drag nor back closes it. It goes on the root
/// navigator, over the shell's tabs, dock and side rail, so no tab switch or
/// rail tap can hide or pop it. Null only if something pops it from outside.
Future<MusicPlatform?> askWhereYouListen(BuildContext context) =>
    showMixtapeSheet<MusicPlatform>(
      context,
      useRootNavigator: true,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      showHandle: false,
      builder: (sheetContext) => PopScope(
        canPop: false,
        child: _SheetBody(
          headline: WhereYouListenSheet.headline,
          line: WhereYouListenSheet.line,
          children: [
            FirstRunPill(
              key: WhereYouListenSheet.appleKey,
              label: WhereYouListenSheet.appleLabel,
              leading: const AppleMusicMark(
                size: WhereYouListenSheet.markSize,
                color: FirstRunColors.ink,
              ),
              onPressed: () =>
                  Navigator.of(sheetContext).pop(MusicPlatform.apple),
            ),
            const SizedBox(height: 10),
            FirstRunPill(
              key: WhereYouListenSheet.spotifyKey,
              label: WhereYouListenSheet.spotifyLabel,
              leading: const SpotifyMark(
                size: WhereYouListenSheet.markSize,
                color: FirstRunColors.ink,
              ),
              onPressed: () =>
                  Navigator.of(sheetContext).pop(MusicPlatform.spotify),
            ),
          ],
        ),
      ),
    );

abstract final class SpotifyHandoffSheet {
  static const String headline = 'Make it a Spotify playlist';
  static const String goLabel = 'Copy songs and open TuneMyMusic';
  static const String cancelLabel = 'Cancel';

  static const Key goKey = Key('spotify-handoff-go');
  static const Key cancelKey = Key('spotify-handoff-cancel');

  /// TuneMyMusic names every pasted list "My Playlist" and writes its own
  /// description; the name is an editable field on its review step, styled
  /// as plain text, so we point at it. No link or paste format presets it.
  static const String _nameStep =
      'tap “My Playlist” to give it this mix’s name, then connect Spotify. '
      'TuneMyMusic adds its own note to the description; you can edit it '
      'in Spotify.';

  /// What is about to happen, with the real count.
  static String lineFor(int count) => count == 1
      ? 'We’ll copy the song and open TuneMyMusic. Paste it in, $_nameStep'
      : 'We’ll copy your $count songs and open TuneMyMusic. Paste them in, '
            '$_nameStep';
}

/// The explainer before the first Spotify playlist handoff on a device. True to go ahead; false
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
