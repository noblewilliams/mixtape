/// The door on a catalog mix (approval
/// `docs/mockups/approved/2026-11-09-add-your-music-loop.md`; board frames 1A
/// to 1E, 2A to 2D and 3A in `docs/mockups/2026-11-09-add-your-music-loop.html`).
///
/// One quiet line and one action under the last turn of a mix the DJ made
/// from Mixtape's catalog (the session's `notPersonal`), and on the tape
/// screen's flush block. It is the honest label for a catalog mix, so it has
/// no dismiss, and it follows the run it starts in place: syncing, failed,
/// Spotify's export waiting, and music in.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/listening/listening_models.dart';
import '../add_music/add_music_router.dart';
import '../providers/library_sync_provider.dart';
import '../providers/music_platform_provider.dart';
import '../providers/onboarding_provider.dart';
import '../theme/mixtape_theme.dart';
import 'foundation/idea_pill.dart';
import 'foundation/service_marks.dart';
import 'foundation/tape_button.dart';
import 'tape_strip.dart';

/// Where the door is drawn: under the conversation's last turn, or as the
/// tape screen's "Not personal yet" block with a hairline under it.
enum MusicDoorLayout { transcript, tape }

/// What the door says, in the contract's priority order.
enum MusicDoorState {
  /// Not a catalog mix (any more): nothing is drawn.
  remade,

  /// The listener's music is ready; the mix predates it.
  musicIn,

  /// An Apple Music sync is running (its alert hidden).
  syncing,

  /// The last sync this session failed, on an Apple Music (or unknown)
  /// device. Not a refused access: the alert's Settings link handles that,
  /// and the door goes back to [noMusic]. On a Spotify device a failed Apple
  /// sync never replaces the Spotify states.
  syncFailed,

  /// The Spotify data export was requested and nothing has landed.
  spotifyWaiting,

  /// Everything else: the line and the platform's action.
  noMusic,
}

/// The door's state for a mix with [notPersonal], given the listener's
/// [onboarding], the library [sync] and the device's [platform] (null:
/// nothing known).
///
/// A sync that has just finished invalidates onboarding as it lands; while
/// that read is in flight ([onboardingReloading]) the run has not landed for
/// the door yet, so it still reads as syncing rather than flashing the
/// catalog line before "Your music is in".
MusicDoorState musicDoorState({
  required bool notPersonal,
  required OnboardingState? onboarding,
  required SyncState sync,
  required MusicPlatform? platform,
  bool onboardingReloading = false,
}) {
  if (!notPersonal) return MusicDoorState.remade;
  if (onboarding?.musicReady ?? false) return MusicDoorState.musicIn;
  if (sync is SyncRunning) return MusicDoorState.syncing;
  if (sync is SyncDone && onboardingReloading) return MusicDoorState.syncing;
  if (sync is SyncFailed &&
      !sync.accessDenied &&
      platform != MusicPlatform.spotify) {
    return MusicDoorState.syncFailed;
  }
  if (spotifyDataWaiting(onboarding)) return MusicDoorState.spotifyWaiting;
  return MusicDoorState.noMusic;
}

class MusicDoor extends ConsumerWidget {
  const MusicDoor({
    super.key,
    required this.notPersonal,
    required this.layout,
    this.onRemake,
  });

  /// The session's `notPersonal`; false draws nothing.
  final bool notPersonal;
  final MusicDoorLayout layout;

  /// "Remake with my music". Null draws the button disabled.
  final VoidCallback? onRemake;

  /// The one container and live region.
  static const Key lineKey = Key('music-door');
  static const Key textKey = Key('music-door-text');
  static const Key actionKey = Key('music-door-action');
  static const Key remakeKey = Key('music-door-remake');
  static const Key barKey = Key('music-door-bar');
  static const Key reelKey = Key('music-door-reel');

  static const String catalogLine =
      "From Mixtape's catalog for now. With your music, the DJ picks from "
      'what you actually play.';
  static const String syncAppleLabel = 'Sync Apple Music';
  static const String addSpotifyLabel = 'Add Spotify music';
  static const String addMusicLabel = 'Add your music';
  static const String syncingLead = 'Syncing Apple Music…';
  static const String syncingTail = 'You can keep chatting while it runs.';

  /// What the live region holds while a sync runs: no percent, so a moving
  /// count never re-announces it.
  static const String syncingSemantics =
      'Syncing Apple Music. You can keep chatting while it runs.';
  static const String failedLine = "Sync didn't finish.";
  static const String retryLabel = 'Try again';
  static const String waitingLine =
      'Waiting on your Spotify data. It can take a few days.';
  static const String chooseFilesLabel = 'Choose files';
  static const String musicInLead = 'Your music is in.';
  static const String musicInTail = 'This mix was made before it.';
  static const String remakeLabel = 'Remake with my music';
  static const String remakeHint = 'Makes a new version from your music.';
  static const String tapeTitle = 'Not personal yet';

  /// The syncing line's bold lead: the percent once there is one.
  static String syncingBold(double progress) => progress == 0
      ? syncingLead
      : '$syncingLead ${(progress * 100).round()}%.';

  /// `.door { gap: 9px }`: the line, then the action or the bar.
  static const double actionGap = 9;

  /// `.door .bar { width: 200px; height: 3px }`.
  static const double barWidth = 200;
  static const double barHeight = 3;

  /// `.door .pill .mk` and `.door .pill svg.ico`.
  static const double markSize = 18;
  static const double glyphSize = 16;

  /// `.tape .reel { width: 20px }`, 8 pt in from the shell's edge
  /// (`.tape { padding: 0 14px 0 8px }`).
  static const double reelSize = 20;
  static const double reelInset = 8;

  /// `.phone.large .door .pill, .phone.large .door .tape { min-height: 52px }`.
  static const double largeActionHeight = 52;

  /// `.door p { max-width: 92% }`, the full width at large text.
  static const double lineWidthFraction = 0.92;

  /// From here on the line takes the full width and the action goes full
  /// width: the tape strip's own threshold for stacking its actions.
  static const double largeScale = TapeStrip.stackScale;

  /// Weight 650 for the bold leads, as the conversation's voices set it.
  static const List<FontVariation> _w650 = [FontVariation('wght', 650)];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final onboarding = ref.watch(onboardingProvider);
    final sync = ref.watch(librarySyncProvider);
    final platform = ref.watch(musicPlatformProvider);
    final state = musicDoorState(
      notPersonal: notPersonal,
      onboarding: onboarding.value,
      sync: sync,
      platform: platform,
      onboardingReloading: onboarding.isLoading,
    );
    if (state == MusicDoorState.remade) return const SizedBox.shrink();

    final tokens = context.tokens;
    final large =
        MediaQuery.textScalerOf(context).scale(100) / 100 >= largeScale;
    final progress = switch (sync) {
      SyncRunning(:final progress) => progress,
      _ => 1.0,
    };

    final (String? bold, String rest, String spoken) = switch (state) {
      MusicDoorState.musicIn => (
        musicInLead,
        musicInTail,
        '$musicInLead $musicInTail',
      ),
      MusicDoorState.syncing => (
        syncingBold(progress),
        syncingTail,
        syncingSemantics,
      ),
      MusicDoorState.syncFailed => (null, failedLine, failedLine),
      MusicDoorState.spotifyWaiting => (null, waitingLine, waitingLine),
      MusicDoorState.noMusic ||
      MusicDoorState.remade => (null, catalogLine, catalogLine),
    };

    final lineStyle = tokens.meta.copyWith(
      color: state == MusicDoorState.syncFailed ? tokens.errInk : tokens.smoke,
      fontWeight: FontWeight.w500,
      height: 1.42,
    );
    final line = Text.rich(
      TextSpan(
        children: [
          if (bold != null)
            TextSpan(
              text: '$bold ',
              style: TextStyle(
                color: tokens.text,
                fontWeight: FontWeight.w600,
                fontVariations: _w650,
              ),
            ),
          TextSpan(text: rest),
        ],
      ),
      key: textKey,
      style: lineStyle,
    );

    void route(AddMusicTarget target) =>
        unawaited(openAddMusicFor(context, ref, target));

    // Every action's label wraps rather than clips; at large text it also
    // goes full width at 52 pt (board frame 1E).
    IdeaPill pill({
      required String label,
      required AddMusicTarget target,
      Widget? leading,
    }) => IdeaPill(
      key: actionKey,
      label: label,
      leading: leading,
      labelWeight: FontWeight.w600,
      wrap: true,
      fill: large,
      minHeight: large ? largeActionHeight : null,
      onPressed: () => route(target),
    );

    final Widget? action = switch (state) {
      MusicDoorState.noMusic => pill(
        label: switch (platform) {
          MusicPlatform.apple => syncAppleLabel,
          MusicPlatform.spotify => addSpotifyLabel,
          null => addMusicLabel,
        },
        leading: switch (platform) {
          MusicPlatform.apple => AppleMusicMark(
            size: markSize,
            color: tokens.text,
          ),
          MusicPlatform.spotify => SpotifyMark(
            size: markSize,
            color: tokens.text,
          ),
          null => null,
        },
        target: AddMusicTarget.door,
      ),
      MusicDoorState.syncFailed => pill(
        label: retryLabel,
        leading: Icon(
          CupertinoIcons.arrow_2_circlepath,
          size: glyphSize,
          color: tokens.text,
        ),
        target: AddMusicTarget.retrySync,
      ),
      MusicDoorState.spotifyWaiting => pill(
        label: chooseFilesLabel,
        leading: Icon(CupertinoIcons.doc, size: glyphSize, color: tokens.text),
        target: AddMusicTarget.door,
      ),
      MusicDoorState.musicIn => TapeButton(
        key: remakeKey,
        label: remakeLabel,
        semanticsHint: remakeHint,
        leading: const _Reel(key: reelKey, size: reelSize),
        leadingPadding: reelInset,
        wrap: true,
        fill: large,
        minHeight: large ? largeActionHeight : null,
        onPressed: onRemake,
      ),
      MusicDoorState.syncing || MusicDoorState.remade => null,
    };

    final door = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: large
          ? CrossAxisAlignment.stretch
          : CrossAxisAlignment.start,
      children: [
        // The live region carries the words; the visible line (with the
        // moving percent) is not read twice.
        ExcludeSemantics(
          child: large
              ? line
              : FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: layout == MusicDoorLayout.tape
                      ? 1
                      : lineWidthFraction,
                  child: line,
                ),
        ),
        const SizedBox(height: actionGap),
        if (action != null)
          action
        else
          Align(
            alignment: Alignment.centerLeft,
            child: _Bar(progress: progress),
          ),
      ],
    );

    final Widget body = switch (layout) {
      MusicDoorLayout.transcript => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: door,
      ),
      // `.tdoor`: the bold label, the door 4 pt under it, a hairline under
      // the whole block.
      MusicDoorLayout.tape => Container(
        padding: const EdgeInsets.fromLTRB(0, 8, 0, 12),
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tokens.hairline)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ExcludeSemantics(
              child: Text(
                tapeTitle,
                style: tokens.rowTitle.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 4),
            door,
          ],
        ),
      ),
    };

    // One container and one live region: the line in words, then the action
    // as its own button. A state change (syncing, failed, music in) is
    // announced without moving focus; the percent never is.
    return Semantics(
      key: lineKey,
      container: true,
      explicitChildNodes: true,
      liveRegion: true,
      label: layout == MusicDoorLayout.tape ? '$tapeTitle\n$spoken' : spoken,
      child: body,
    );
  }
}

/// `.door .bar`: a thin plum bar on a hairline track. Decoration: the line
/// above it says the state in words.
class _Bar extends StatelessWidget {
  const _Bar({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return ExcludeSemantics(
      child: ClipRRect(
        key: MusicDoor.barKey,
        borderRadius: const BorderRadius.all(Radius.circular(2)),
        child: SizedBox(
          width: MusicDoor.barWidth,
          height: MusicDoor.barHeight,
          child: ColoredBox(
            color: tokens.hairline,
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: progress.clamp(0.0, 1.0),
                heightFactor: 1,
                child: ColoredBox(color: tokens.plum),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.tape .reel`: the tape button's reel, light spokes on a dark hub inside
/// a dark rim, for the one tape button that carries one (board 3A).
class _Reel extends StatelessWidget {
  const _Reel({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: const CustomPaint(painter: _ReelPainter()),
  );
}

class _ReelPainter extends CustomPainter {
  const _ReelPainter();

  /// `repeating-conic-gradient(#e4e1dd 0 24deg, transparent 24deg 45deg)`
  /// on `#262329`, inside a 2.5 px `#262329` border.
  static const Color _hub = Color(0xFF262329);
  static const Color _spoke = Color(0xFFE4E1DD);
  static const double _rim = 2.5;
  static const int _spokes = 8;
  static const double _spokeSweep = 24 * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    canvas.drawCircle(center, radius, Paint()..color = _hub);
    final wedge = Rect.fromCircle(center: center, radius: radius - _rim);
    final spoke = Paint()..color = _spoke;
    const step = 2 * math.pi / _spokes;
    for (var i = 0; i < _spokes; i++) {
      // CSS conic gradients start at twelve o'clock.
      canvas.drawArc(wedge, -math.pi / 2 + i * step, _spokeSweep, true, spoke);
    }
  }

  @override
  bool shouldRepaint(_ReelPainter oldDelegate) => false;
}
