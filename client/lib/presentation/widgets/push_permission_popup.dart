/// The Mix ready notifications ask
/// (`docs/mockups/approved/2026-11-21-push-permission-modal.md`, board
/// `docs/mockups/2026-11-21-push-permission-modal-r3.html`, art I1; spec
/// 2026-11-21 durable mix turns → Asking for permission).
///
/// One pop-up, shown once per device: the cassette with a "Your mix is
/// ready" notification rising out of it, one line of why, the paper pill
/// "Turn on notifications" (the only thing that brings up iOS's prompt) and
/// "Not now". [PushAskTrigger] decides when: about 3 s into a turn's working
/// state (Making your mix, the chat, Home's starting state), or on arrival
/// at Home. Never stacked on another ask, never when iOS has already
/// decided.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/push/push_service.dart';
import '../providers/ai_consent_provider.dart';
import '../providers/mix_activity_provider.dart';
import '../providers/mix_background_provider.dart';
import '../providers/music_platform_provider.dart';
import '../providers/push_provider.dart';
import '../providers/shell_providers.dart';
import '../screens/first_run/step_scaffold.dart' show FirstRunPill;
import '../screens/shell/shell_route_observer.dart' show ShellTabScope;
import 'foundation/cassette_tile.dart';
import 'foundation/haptics.dart';
import 'foundation/mixtape_popup.dart';
import 'foundation/mixtape_sheet.dart';
import 'listen_on_prompt.dart' show listenOnAskedProvider;

/// The record's copy, and the pop-up's keys.
abstract final class PushAskCopy {
  static const String title = 'Want a ping when it’s ready?';
  static const String body =
      'Mixes take up to a minute. Lock your phone, get on with your day, and '
      'we’ll tell you the moment yours is ready.';
  static const String allowLabel = 'Turn on notifications';
  static const String notNowLabel = 'Not now';

  /// The notification in the art.
  static const String pingTitle = 'Your mix is ready';
  static const String pingMix = 'Sunday kitchen soul';
  static const String pingTime = 'now';

  static const Key popupKey = Key('push-ask');
  static const Key artKey = Key('push-ask-art');
  static const Key cassetteKey = Key('push-ask-cassette');
  static const Key pingKey = Key('push-ask-ping');
  static const Key titleKey = Key('push-ask-title');
  static const Key bodyKey = Key('push-ask-body');
  static const Key allowKey = Key('push-ask-allow');
  static const Key notNowKey = Key('push-ask-not-now');
  static const Key scrollKey = Key('push-ask-scroll');
}

/// Shows the pop-up on [context]'s navigator. [onAllow] runs on the pill
/// (the system prompt, then the registration) and its answer closes the
/// pop-up; null on Not now or a tap outside.
Future<PushStatus?> showPushPermissionPopup(
  BuildContext context, {
  required Future<PushStatus> Function() onAllow,
}) => showMixtapePopup<PushStatus>(
  context,
  label: PushAskCopy.title,
  builder: (_) => PushPermissionPopup(onAllow: onAllow),
);

/// Shows the pop-up now, as the once rule's one appearance: the flag is set
/// as it appears, the pill registers this phone, and the first run and
/// Making hear about an Allow. Callers check [PushAskNotifier.eligible]
/// first.
Future<PushStatus?> presentPushAsk(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final ask = container.read(pushAskProvider.notifier);
  ask.markShown();
  try {
    final result = await OpenAsksNotifier.around(
      container,
      () => showPushPermissionPopup(
        context,
        onAllow: () => container.read(pushServiceProvider).requestAndRegister(),
      ),
    );
    if (result != null) {
      unawaited(container.read(mixBackgroundProvider.notifier).refresh());
      container.invalidate(pushSettingProvider);
    }
    return result;
  } finally {
    ask.markClosed();
  }
}

/// The pop-up's content: the art, the words and the two buttons, centred.
class PushPermissionPopup extends StatefulWidget {
  const PushPermissionPopup({super.key, required this.onAllow});

  final Future<PushStatus> Function() onAllow;

  /// At about 160 % text the notification goes (its type cannot grow with
  /// the rest) and the cassette shrinks.
  static const double largeTextScale = 1.6;

  /// `.sheet` padding and the gaps between its lines.
  static const double sidePadding = 22;
  static const double bottomPadding = 14;
  static const double artGap = 18;
  static const double titleGap = 6;
  static const double bodyGap = 18;
  static const double pillHeight = 50;
  static const double pillFontSize = 15.2;
  static const double notNowGap = 4;

  @override
  State<PushPermissionPopup> createState() => _PushPermissionPopupState();
}

class _PushPermissionPopupState extends State<PushPermissionPopup> {
  bool _asking = false;

  Future<void> _allow() async {
    if (_asking) return;
    // iOS's own prompt comes up over this; the pill shows nothing extra.
    _asking = true;
    PushStatus status;
    try {
      status = await widget.onAllow();
    } catch (_) {
      status = PushStatus.denied;
    }
    if (!mounted) return;
    Navigator.of(context).pop(status);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = MixtapeSheet.tokensOf(context);
    final large =
        MediaQuery.textScalerOf(context).scale(1) >=
        PushPermissionPopup.largeTextScale;
    final surface = MixtapeSheet.surfaceColorOf(context);

    final words = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 4),
        ExcludeSemantics(child: _PingArt(large: large)),
        const SizedBox(height: PushPermissionPopup.artGap),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: PushPermissionPopup.sidePadding,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                header: true,
                child: Text(
                  PushAskCopy.title,
                  key: PushAskCopy.titleKey,
                  textAlign: TextAlign.center,
                  style: tokens.body.copyWith(
                    fontSize: 17.9,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                    letterSpacing: -0.18,
                    color: tokens.text,
                  ),
                ),
              ),
              const SizedBox(height: PushPermissionPopup.titleGap),
              Text(
                PushAskCopy.body,
                key: PushAskCopy.bodyKey,
                textAlign: TextAlign.center,
                style: tokens.body.copyWith(
                  fontSize: 13.44,
                  height: 1.4,
                  fontWeight: FontWeight.w400,
                  color: tokens.smoke,
                ),
              ),
              const SizedBox(height: PushPermissionPopup.bodyGap),
            ],
          ),
        ),
      ],
    );

    return Column(
      key: PushAskCopy.popupKey,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Taller than the screen (200 % text): the art and words scroll,
        // and the buttons stay at the bottom, reachable without scrolling.
        Flexible(
          child: Stack(
            children: [
              SingleChildScrollView(key: PushAskCopy.scrollKey, child: words),
              if (large)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 40,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [surface.withValues(alpha: 0), surface],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
            PushPermissionPopup.sidePadding,
            large ? 8 : 0,
            PushPermissionPopup.sidePadding,
            PushPermissionPopup.bottomPadding,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              FirstRunPill(
                key: PushAskCopy.allowKey,
                label: PushAskCopy.allowLabel,
                minHeight: PushPermissionPopup.pillHeight,
                fontSize: PushPermissionPopup.pillFontSize,
                onPressed: Haptics.on(HapticKind.primary, _allow),
              ),
              const SizedBox(height: PushPermissionPopup.notNowGap),
              TextButton(
                key: PushAskCopy.notNowKey,
                onPressed: Haptics.on(
                  HapticKind.dismiss,
                  () => Navigator.of(context).pop(),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: tokens.muted,
                  minimumSize: const Size.fromHeight(44),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: const StadiumBorder(),
                ),
                child: Text(
                  PushAskCopy.notNowLabel,
                  textAlign: TextAlign.center,
                  style: tokens.body.copyWith(
                    fontSize: 14.08,
                    fontWeight: FontWeight.w600,
                    color: tokens.muted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// I1: the cassette, tilted −4° with its hubs turning, and the notification
/// rising out of it every 3.2 s. Still under reduced motion; at large text,
/// the cassette alone. Its type never scales: it is a picture.
class _PingArt extends StatefulWidget {
  const _PingArt({required this.large});

  final bool large;

  /// `.art` and `.art .tape`.
  static const double height = 126;
  static const double largeHeight = 110;
  static const double tapeWidth = 108;
  static const double largeTapeWidth = 82;
  static const double tapeDrop = 17;
  static const double tilt = -4 * math.pi / 180;

  /// `@keyframes pop`.
  static const Duration period = Duration(milliseconds: 3200);

  static const Color tapeCase = Color(0xFF3F4851);

  @override
  State<_PingArt> createState() => _PingArtState();
}

class _PingArtState extends State<_PingArt>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: _PingArt.period,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_PingArt oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final still = MediaQuery.disableAnimationsOf(context) || widget.large;
    if (still) {
      if (_pop.isAnimating) _pop.stop();
      // Reduced motion: the notification simply sits above the tape.
      _pop.value = 0.5;
    } else if (!_pop.isAnimating) {
      _pop.repeat();
    }
  }

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final large = widget.large;
    final width = large ? _PingArt.largeTapeWidth : _PingArt.tapeWidth;
    return MediaQuery.withNoTextScaling(
      child: SizedBox(
        key: PushAskCopy.artKey,
        height: large ? _PingArt.largeHeight : _PingArt.height,
        child: Stack(
          clipBehavior: Clip.hardEdge,
          alignment: Alignment.center,
          children: [
            Transform.rotate(
              angle: _PingArt.tilt,
              child: Transform.translate(
                offset: Offset(0, large ? 0 : _PingArt.tapeDrop),
                child: _ShadowedTape(width: width),
              ),
            ),
            if (!large)
              Positioned(
                top: 10,
                left: 0,
                right: 0,
                child: Center(
                  child: AnimatedBuilder(
                    animation: _pop,
                    builder: (context, child) {
                      final frame = _PopFrame.at(_pop.value);
                      return Opacity(
                        opacity: frame.opacity,
                        child: Transform.translate(
                          offset: Offset(0, frame.dy),
                          child: Transform.rotate(
                            angle: 2 * math.pi / 180,
                            child: Transform.scale(
                              scale: frame.scale,
                              child: child,
                            ),
                          ),
                        ),
                      );
                    },
                    child: const _Ping(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One moment of `@keyframes pop`: in from 26 pt below between 8 % and
/// 18 %, held to 82 %, out 6 pt up by 92 %, each leg eased in and out.
class _PopFrame {
  const _PopFrame(this.opacity, this.dy, this.scale);

  final double opacity;
  final double dy;
  final double scale;

  static const _PopFrame below = _PopFrame(0, 26, 0.92);
  static const _PopFrame up = _PopFrame(1, 0, 1);
  static const _PopFrame gone = _PopFrame(0, -6, 0.98);

  static _PopFrame _lerp(_PopFrame a, _PopFrame b, double t) {
    final e = Curves.easeInOut.transform(t.clamp(0.0, 1.0));
    return _PopFrame(
      ui.lerpDouble(a.opacity, b.opacity, e)!,
      ui.lerpDouble(a.dy, b.dy, e)!,
      ui.lerpDouble(a.scale, b.scale, e)!,
    );
  }

  static _PopFrame at(double t) {
    if (t <= 0.08) return below;
    if (t < 0.18) return _lerp(below, up, (t - 0.08) / 0.10);
    if (t <= 0.82) return up;
    if (t < 0.92) return _lerp(up, gone, (t - 0.82) / 0.10);
    return gone;
  }
}

/// The cassette with the board's `drop-shadow(0 10px 18px …)`, which the
/// painter's own shadow does not match.
class _ShadowedTape extends StatelessWidget {
  const _ShadowedTape({required this.width});

  final double width;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(9 * width / 200),
      boxShadow: const [
        BoxShadow(
          color: Color.fromRGBO(23, 22, 26, 0.28),
          offset: Offset(0, 10),
          // A CSS drop-shadow of 18 is a 9 pt standard deviation.
          blurRadius: (9 - 0.5) / 0.57735,
        ),
      ],
    ),
    child: CassetteTile(
      key: PushAskCopy.cassetteKey,
      width: width,
      caseColor: _PingArt.tapeCase,
      // At the app's own hub speed; still under reduced motion.
      spinning: true,
    ),
  );
}

/// The notification in the art (`.toast`): the reel crop of the app icon,
/// "Your mix is ready", a made-up title and "now", on the system's light or
/// dark notification glass.
class _Ping extends StatelessWidget {
  const _Ping();

  static const double width = 178;
  static const double iconSize = 20;
  static const Color iconCase = Color(0xFF544451);

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = dark ? const Color(0xFFF2EEF1) : const Color(0xFF1C1A1E);
    final radius = BorderRadius.circular(13);
    final base = TextStyle(
      color: ink,
      fontFamily: MixtapeSheet.tokensOf(context).body.fontFamily,
      decoration: TextDecoration.none,
    );
    return Container(
      key: PushAskCopy.pingKey,
      width: width,
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: dark
                ? const Color.fromRGBO(0, 0, 0, 0.45)
                : const Color.fromRGBO(30, 24, 40, 0.18),
            offset: const Offset(0, 8),
            blurRadius: (11 - 0.5) / 0.57735,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: radius,
              color: dark
                  ? const Color.fromRGBO(60, 56, 66, 0.82)
                  : const Color.fromRGBO(255, 255, 255, 0.78),
              border: Border.all(
                width: 0.5,
                color: dark
                    ? const Color.fromRGBO(255, 255, 255, 0.14)
                    : const Color.fromRGBO(255, 255, 255, 0.7),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const CassetteTile(
                  width: iconSize,
                  crop: CassetteCrop.icon,
                  caseColor: iconCase,
                  spinning: true,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        PushAskCopy.pingTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: base.copyWith(
                          fontSize: 9.5,
                          height: 1.2,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        PushAskCopy.pingMix,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: base.copyWith(
                          fontSize: 9,
                          height: 1.25,
                          fontWeight: FontWeight.w400,
                          color: ink.withValues(alpha: 0.75),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 7),
                Align(
                  alignment: Alignment.topCenter,
                  heightFactor: 1,
                  child: Text(
                    PushAskCopy.pingTime,
                    style: base.copyWith(
                      fontSize: 8.5,
                      fontWeight: FontWeight.w400,
                      color: ink.withValues(alpha: 0.6),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Where the pop-up can appear: wraps a screen and shows it, once per
/// device, at the record's moments.
///
/// - [working]: about 3 s into a turn this screen shows working (Making
///   your mix, the chat's working state, Home's starting state), if the
///   turn is still going.
/// - [onArrival]: once Home has settled, unless a turn is out (then its
///   working state asks instead, never over a just-started turn).
///
/// Either way it waits while another ask is up (the AI-consent sheet,
/// "Where do you listen?"), while this screen is covered or in another tab,
/// and while the app is in the background.
class PushAskTrigger extends ConsumerStatefulWidget {
  const PushAskTrigger({
    super.key,
    required this.child,
    this.working = false,
    this.onArrival = false,
  });

  final Widget child;
  final bool working;
  final bool onArrival;

  static const Duration workingDelay = Duration(seconds: 3);

  /// Home "has settled": the shell's first sheets have had their frame.
  static const Duration arrivalDelay = Duration(milliseconds: 1500);

  /// How often a due ask looks again while something is in its way.
  static const Duration retryDelay = Duration(seconds: 1);

  @override
  ConsumerState<PushAskTrigger> createState() => _PushAskTriggerState();
}

enum _Due { none, arrival, working }

class _PushAskTriggerState extends ConsumerState<PushAskTrigger> {
  Timer? _workTimer;
  Timer? _arrivalTimer;
  Timer? _retryTimer;
  _Due _due = _Due.none;
  bool _trying = false;

  @override
  void initState() {
    super.initState();
    if (widget.working) _armWorking();
    if (widget.onArrival) {
      _arrivalTimer = Timer(PushAskTrigger.arrivalDelay, _arrive);
    }
  }

  @override
  void didUpdateWidget(PushAskTrigger oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.working && !oldWidget.working) {
      // A turn just started here: its first seconds are never covered.
      if (_due == _Due.arrival) _due = _Due.none;
      _armWorking();
    } else if (!widget.working && oldWidget.working) {
      _workTimer?.cancel();
      if (_due == _Due.working) _due = _Due.none;
    }
  }

  @override
  void dispose() {
    _workTimer?.cancel();
    _arrivalTimer?.cancel();
    _retryTimer?.cancel();
    super.dispose();
  }

  void _armWorking() {
    _workTimer?.cancel();
    _workTimer = Timer(PushAskTrigger.workingDelay, () {
      if (!mounted || !widget.working || ref.read(pushAskProvider)) return;
      _due = _Due.working;
      unawaited(_try());
    });
  }

  void _arrive() {
    if (!mounted || ref.read(pushAskProvider)) return;
    if (_turnOut()) return;
    _due = _Due.arrival;
    unawaited(_try());
  }

  bool _turnOut() {
    final activity = ref.read(mixActivityProvider);
    return activity.pending != null || activity.working.isNotEmpty;
  }

  void _retryLater() {
    _retryTimer?.cancel();
    _retryTimer = Timer(PushAskTrigger.retryDelay, () => unawaited(_try()));
  }

  bool _onScreen() {
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) return false;
    final tab = ShellTabScope.maybeOf(context);
    if (tab != null && ref.read(selectedTabProvider) != tab) return false;
    return ref.read(appInForegroundProvider)();
  }

  /// Another ask is up or still to come first.
  Future<bool> _blocked() async {
    if (ref.read(openAsksProvider) > 0) return true;
    if (!ref.read(aiConsentSettledProvider)) return true;
    if (ref.read(aiConsentNeededProvider) &&
        !ref.read(aiConsentProvider).dismissed) {
      return true;
    }
    if (_due == _Due.arrival) {
      // "Where do you listen?" goes first on the shell.
      final platform = ref.read(musicPlatformProvider.notifier);
      await platform.ready;
      if (!mounted) return true;
      if (platform.unknown && !ref.read(listenOnAskedProvider)) return true;
    }
    return false;
  }

  Future<void> _try() async {
    if (_due == _Due.none || _trying || !mounted) return;
    _trying = true;
    try {
      if (_due == _Due.arrival && _turnOut()) {
        _due = _Due.none;
        return;
      }
      if (!_onScreen()) {
        _retryLater();
        return;
      }
      final ask = ref.read(pushAskProvider.notifier);
      if (!await ask.eligible()) {
        _due = _Due.none;
        return;
      }
      if (!mounted || _due == _Due.none) return;
      if (await _blocked() || !mounted || !_onScreen()) {
        if (mounted) _retryLater();
        return;
      }
      if (_due == _Due.none || ref.read(pushAskProvider)) return;
      _due = _Due.none;
      unawaited(presentPushAsk(context));
    } finally {
      _trying = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The board's bell (`.ping svg`, a 24-unit stroke at 1.8), scaled to the
/// size it is painted at.
class BellGlyphPainter extends CustomPainter {
  const BellGlyphPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    final bell = Path()
      ..moveTo(6, 16)
      ..lineTo(6, 11)
      ..arcToPoint(const Offset(18, 11), radius: const Radius.circular(6))
      ..lineTo(18, 16)
      ..lineTo(19.5, 18)
      ..lineTo(4.5, 18)
      ..close();
    final clapper = Path()
      ..moveTo(10, 20.5)
      ..arcToPoint(
        const Offset(14, 20.5),
        radius: const Radius.circular(2),
        clockwise: false,
      );
    canvas
      ..drawPath(bell, paint)
      ..drawPath(clapper, paint);
  }

  @override
  bool shouldRepaint(BellGlyphPainter oldDelegate) =>
      oldDelegate.color != color;
}
