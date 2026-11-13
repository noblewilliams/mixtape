/// One turn of the mix conversation, set as lyrics rather than bubbles, and
/// the cassette that stands in for the DJ's next line while it works
/// (`docs/mockups/approved/2026-11-03-mix-conversation-redesign.md` →
/// Transcript, Working, Failed turn; `.l-dj`, `.l-me`, `.l-err`, `.past` and
/// `.loadtape` on `docs/mockups/2026-11-03-mix-conversation-redesign.html`).
///
/// No container at all: the DJ's lines are large ink on the left, yours are
/// smaller smoke on the right, and older turns fade as they scroll away
/// ([LyricFade]) — a paint-only fade, so VoiceOver always reads every line.
///
/// The playlist-edit conversation keeps the bubble turns of
/// `conversation_turn.dart`; the redesign covers the mix conversation only.
/// The keys are shared with those widgets, so tests find a turn by the same
/// key on either surface.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../theme/mixtape_theme.dart';
import 'conversation_turn.dart' show ConversationTurn, ConversationTurnKind, WorkingIndicator;
import 'foundation/cassette_tile.dart';

export 'conversation_turn.dart' show ConversationTurnKind;

class LyricTurn extends StatelessWidget {
  const LyricTurn({
    super.key,
    required this.text,
    required this.kind,
    this.onResend,
    this.resendEnabled = true,
  });

  final String text;
  final ConversationTurnKind kind;

  /// Error turns only: resends the user turn this one answers. Null hides the
  /// link entirely (a turn with no preceding user text to resend).
  final VoidCallback? onResend;

  /// Whether an already-drawn Resend is actionable: false while another send
  /// or an arrangement edit is in flight. The link stays visible and dimmed
  /// rather than disappearing.
  final bool resendEnabled;

  /// `.l-me { max-width: 84% }`.
  static const double userMaxWidthFraction = 0.84;

  /// `.l-dj { max-width: 94% }`.
  static const double djMaxWidthFraction = 0.94;

  /// `.l-dj { font: 650 1.1em }` on the board's 16 pt body: about 17 pt.
  static const double djFontSize = 17;

  /// `.l-me { font: 650 .92em }`: about 15 pt.
  static const double userFontSize = 15;

  /// The DJ's lines grow less than body text at the largest sizes, so a long
  /// answer still fits the screen (board, largest text frame).
  static const double djMaxTextScale = 1.6;

  static const Key userKey = ConversationTurn.userKey;
  static const Key djKey = ConversationTurn.djKey;
  static const Key errorKey = ConversationTurn.errorKey;
  static const Key resendKey = ConversationTurn.resendKey;

  /// Weight 650: between semibold and bold, as the board sets both voices.
  static const List<FontVariation> _w650 = [FontVariation('wght', 650)];

  static TextStyle djStyle(MixtapeTokens tokens) => TextStyle(
    fontSize: djFontSize,
    height: 1.32,
    letterSpacing: -0.2,
    fontWeight: FontWeight.w600,
    fontVariations: _w650,
    color: tokens.text,
  );

  static TextStyle userStyle(MixtapeTokens tokens) => TextStyle(
    fontSize: userFontSize,
    height: 1.38,
    fontWeight: FontWeight.w600,
    fontVariations: _w650,
    color: tokens.smoke,
  );

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return switch (kind) {
      ConversationTurnKind.dj => Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: djMaxWidthFraction,
          alignment: Alignment.centerLeft,
          child: Text(
            text,
            key: djKey,
            style: djStyle(tokens),
            textScaler: MediaQuery.textScalerOf(
              context,
            ).clamp(maxScaleFactor: djMaxTextScale),
          ),
        ),
      ),
      ConversationTurnKind.user => Align(
        alignment: Alignment.centerRight,
        child: FractionallySizedBox(
          widthFactor: userMaxWidthFraction,
          alignment: Alignment.centerRight,
          child: Text(
            text,
            key: userKey,
            textAlign: TextAlign.right,
            style: userStyle(tokens),
          ),
        ),
      ),
      ConversationTurnKind.error => _FailedLine(
        text: text,
        onResend: onResend,
        resendEnabled: resendEnabled,
      ),
    };
  }
}

/// `.l-err`: one line in error ink under the message it answers, with a
/// Resend link on a 44 pt target.
class _FailedLine extends StatelessWidget {
  const _FailedLine({
    required this.text,
    required this.onResend,
    required this.resendEnabled,
  });

  final String text;
  final VoidCallback? onResend;
  final bool resendEnabled;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final style = tokens.meta.copyWith(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: tokens.errInk,
    );
    final enabled = resendEnabled && onResend != null;
    return Align(
      key: LyricTurn.errorKey,
      alignment: Alignment.centerRight,
      child: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: MixtapeMetrics.minTarget,
            ),
            child: Align(
              alignment: Alignment.centerRight,
              widthFactor: 1,
              child: Text(text, textAlign: TextAlign.right, style: style),
            ),
          ),
          if (onResend != null)
            Semantics(
              button: true,
              enabled: enabled,
              label: 'Resend',
              onTap: enabled ? onResend : null,
              excludeSemantics: true,
              child: GestureDetector(
                key: LyricTurn.resendKey,
                behavior: HitTestBehavior.opaque,
                onTap: enabled ? onResend : null,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: MixtapeMetrics.minTarget,
                    minHeight: MixtapeMetrics.minTarget,
                  ),
                  child: Center(
                    widthFactor: 1,
                    child: Text(
                      'Resend',
                      style: style.copyWith(
                        fontWeight: FontWeight.w700,
                        color: enabled
                            ? tokens.plum
                            : tokens.plum.withValues(alpha: 0.4),
                        decoration: TextDecoration.underline,
                        decorationColor: enabled
                            ? tokens.plum
                            : tokens.plum.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One step of the DJ's job, as the working caption tells it: from [from]
/// into the turn, one of [lines].
class DjWorkingPhase {
  const DjWorkingPhase(this.from, this.lines);

  final Duration from;
  final List<String> lines;
}

/// What the working caption says as a turn goes on (device smoke,
/// 2026-11-13: "The DJ is listening…" alone undersold everything the DJ
/// does).
///
/// The phases follow the order a turn's work actually runs in — the ask is
/// read, the library searched, records pulled, the order set, the tape
/// written — on a clock, since a turn reports nothing until it is done. The
/// first line is always the same; each later phase picks one of its lines
/// by seed, so a turn reads differently from the last one but never changes
/// its mind about a phase it is in.
class DjWorkingPhrases {
  const DjWorkingPhrases(this.phases);

  final List<DjWorkingPhase> phases;

  static const DjWorkingPhrases mix = DjWorkingPhrases([
    DjWorkingPhase(Duration.zero, ['The DJ is listening…']),
    DjWorkingPhase(Duration(seconds: 4), [
      'Digging through the crates…',
      'Flipping through your records…',
      'Thumbing through the stacks…',
    ]),
    DjWorkingPhase(Duration(seconds: 11), [
      'Pulling records that fit…',
      'Checking the tempos…',
      'Cueing up contenders…',
    ]),
    DjWorkingPhase(Duration(seconds: 20), [
      'Sequencing the tracklist…',
      'Working the crossfader…',
      'Lining up the transitions…',
    ]),
    DjWorkingPhase(Duration(seconds: 32), [
      'Pressing the tape…',
      'Labelling the cassette…',
      'Spooling it up…',
    ]),
    DjWorkingPhase(Duration(seconds: 50), [
      'Still at the decks. Worth the wait…',
    ]),
  ]);

  /// An album session's (board A1's line first: it says the catalogue check
  /// too).
  static const DjWorkingPhrases album = DjWorkingPhrases([
    DjWorkingPhase(Duration.zero, [WorkingIndicator.albumCaption]),
    DjWorkingPhase(Duration(seconds: 6), [
      'Flipping through the record bins…',
      'Pulling sleeves off the shelf…',
    ]),
    DjWorkingPhase(Duration(seconds: 16), [
      'Reading the liner notes…',
      'Checking the pressing…',
    ]),
    DjWorkingPhase(Duration(seconds: 30), ['Dropping the needle…']),
  ]);

  int _phaseAt(Duration elapsed) {
    var index = 0;
    for (var i = 0; i < phases.length; i++) {
      if (elapsed >= phases[i].from) index = i;
    }
    return index;
  }

  /// The line [elapsed] into a turn.
  String lineAt(Duration elapsed, {required int seed}) {
    final index = _phaseAt(elapsed);
    final lines = phases[index].lines;
    return lines[(seed + index) % lines.length];
  }

  /// How long after [elapsed] the line next changes; null once it holds.
  Duration? untilNext(Duration elapsed) {
    final index = _phaseAt(elapsed);
    if (index + 1 >= phases.length) return null;
    return phases[index + 1].from - elapsed;
  }
}

/// `.loadtape`: a small cassette in the tape colour, hubs turning, then a
/// line of what the DJ is doing ([DjWorkingPhrases]), where the DJ's next
/// line will land. Under reduced motion the hubs stand still and the line
/// changes without a fade; the status region always announces one steady
/// line, so VoiceOver is not read every step.
class WorkingCassette extends StatefulWidget {
  const WorkingCassette({
    super.key,
    this.caseColor,
    this.phrases = DjWorkingPhrases.mix,
    this.announcementText,
    this.startedAt,
    this.seed,
  });

  /// The mix's tape colour; the default case before the first mix.
  final Color? caseColor;

  /// What the line beside the cassette says as the turn goes on.
  final DjWorkingPhrases phrases;

  /// What VoiceOver hears; [announcement] when null.
  final String? announcementText;

  /// When the turn went out. A conversation reopened mid-turn passes it so
  /// the line picks up where it had got to; null starts from the first.
  final DateTime? startedAt;

  /// Which line each phase picks. Null takes one from [startedAt], or at
  /// random; tests pass their own.
  final int? seed;

  static const Key indicatorKey = WorkingIndicator.indicatorKey;
  static const Key cassetteKey = Key('working-cassette');
  static const Key captionKey = WorkingIndicator.captionKey;

  /// Down from the board's 56, which read too large beside one line of
  /// caption (device smoke, 2026-11-13).
  static const double cassetteWidth = 44;

  static const String announcement = WorkingIndicator.announcement;
  static const String caption = 'The DJ is listening…';

  /// An album session's first line (board A1): says the catalogue check too.
  static const String albumCaption = WorkingIndicator.albumCaption;
  static const String albumAnnouncement = WorkingIndicator.albumAnnouncement;

  @override
  State<WorkingCassette> createState() => _WorkingCassetteState();
}

class _WorkingCassetteState extends State<WorkingCassette> {
  late final int _seed =
      widget.seed ??
      widget.startedAt?.millisecondsSinceEpoch ??
      math.Random().nextInt(1 << 16);

  /// How far into the turn this widget came in, and the clock since.
  late final Duration _offset = widget.startedAt == null
      ? Duration.zero
      : DateTime.now().difference(widget.startedAt!);
  Duration _sinceMount = Duration.zero;
  Timer? _timer;

  Duration get _elapsed => _offset + _sinceMount;

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  /// One timer per change of line, rather than a tick: nothing runs while
  /// the line holds.
  void _schedule() {
    final wait = widget.phrases.untilNext(_elapsed);
    if (wait == null) return;
    _timer = Timer(wait, () {
      if (!mounted) return;
      setState(() => _sinceMount += wait);
      _schedule();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final line = widget.phrases.lineAt(_elapsed, seed: _seed);
    return Semantics(
      key: WorkingCassette.indicatorKey,
      container: true,
      liveRegion: true,
      label: widget.announcementText ?? WorkingCassette.announcement,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              Transform.rotate(
                angle: -0.07,
                child: CassetteTile(
                  key: WorkingCassette.cassetteKey,
                  width: WorkingCassette.cassetteWidth,
                  caseColor: widget.caseColor ?? CassetteTile.caseColors.first,
                  spinning: true,
                  shadow: true,
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: KeyedSubtree(
                  key: WorkingCassette.captionKey,
                  child: AnimatedSwitcher(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 280),
                    layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.centerLeft,
                      children: [...previous, ?current],
                    ),
                    child: Text(
                      line,
                      key: ValueKey(line),
                      style: tokens.meta.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: tokens.muted,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The transcript's scroll-driven fade: a turn whose bottom edge sits above
/// the lower half of the visible transcript paints at [fadedOpacity], and
/// comes back to full ink as it scrolls into that lower part, as lyrics do.
///
/// Paint-only — opacity is applied as a layer, never as an [Opacity] widget —
/// so semantics, hit testing and layout are untouched. The list it lives in
/// must not add repaint boundaries per item, or scrolling would not repaint
/// it.
class LyricFade extends SingleChildRenderObjectWidget {
  const LyricFade({
    super.key,
    this.bottomInset = 0,
    this.pinned = false,
    super.child,
  });

  /// How much of the viewport's bottom the floating panel covers.
  final double bottomInset;

  /// Always full ink, wherever it sits: the latest exchange (the last thing
  /// the listener said, and everything after it) never fades, so a short
  /// conversation is not half grey before it has scrolled at all.
  final bool pinned;

  /// `.past { opacity: .34 }`.
  static const double fadedOpacity = 0.34;

  /// The lower part of the visible transcript where turns are at full ink.
  static const double brightFraction = 0.5;

  /// The distance over which a turn eases between faded and full.
  static const double ramp = 56;

  /// The opacity of a turn whose bottom edge is at [itemBottom], in a
  /// visible transcript spanning [visibleTop]–[visibleBottom].
  static double opacityFor({
    required double itemBottom,
    required double visibleTop,
    required double visibleBottom,
  }) {
    final height = visibleBottom - visibleTop;
    if (height <= 0) return 1;
    final line = visibleBottom - height * brightFraction;
    if (itemBottom >= line) return 1;
    if (itemBottom <= line - ramp) return fadedOpacity;
    final t = (itemBottom - (line - ramp)) / ramp;
    return fadedOpacity + (1 - fadedOpacity) * t;
  }

  @override
  RenderLyricFade createRenderObject(BuildContext context) =>
      RenderLyricFade(bottomInset: bottomInset, pinned: pinned);

  @override
  void updateRenderObject(BuildContext context, RenderLyricFade renderObject) {
    renderObject
      ..bottomInset = bottomInset
      ..pinned = pinned;
  }
}

class RenderLyricFade extends RenderProxyBox {
  RenderLyricFade({double bottomInset = 0, bool pinned = false})
    : _bottomInset = bottomInset,
      _pinned = pinned;

  double _bottomInset;
  double get bottomInset => _bottomInset;
  set bottomInset(double value) {
    if (value == _bottomInset) return;
    _bottomInset = value;
    markNeedsPaint();
  }

  bool _pinned;
  bool get pinned => _pinned;
  set pinned(bool value) {
    if (value == _pinned) return;
    _pinned = value;
    markNeedsPaint();
  }

  /// The opacity of the last paint, for tests.
  double get lastOpacity => _lastOpacity;
  double _lastOpacity = 1;

  // Always on a layer of its own, so a viewport clip above it knows to clip
  // with a layer too whether or not this turn is faded right now.
  @override
  bool get alwaysNeedsCompositing => child != null;

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    var opacity = 1.0;
    final RenderObject? viewport = RenderAbstractViewport.maybeOf(this);
    if (!_pinned && viewport is RenderBox && viewport.hasSize) {
      final top = localToGlobal(Offset.zero, ancestor: viewport).dy;
      opacity = LyricFade.opacityFor(
        itemBottom: top + size.height,
        visibleTop: 0,
        visibleBottom: viewport.size.height - _bottomInset,
      );
    }
    _lastOpacity = opacity;
    layer = context.pushOpacity(
      offset,
      (opacity * 255).round(),
      super.paint,
      oldLayer: layer as OpacityLayer?,
    );
  }
}
