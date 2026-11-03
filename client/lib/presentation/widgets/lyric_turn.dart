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

/// `.loadtape`: a 56 pt cassette in the tape colour, hubs turning, then "The
/// DJ is listening…", where the DJ's next line will land. Under reduced
/// motion the hubs stand still; the status region always announces that the
/// DJ is working.
class WorkingCassette extends StatelessWidget {
  const WorkingCassette({
    super.key,
    this.caseColor,
    this.captionText,
    this.announcementText,
  });

  /// The mix's tape colour; the default case before the first mix.
  final Color? caseColor;

  /// What the line beside the cassette says; [caption] when null.
  final String? captionText;

  /// What VoiceOver hears; [announcement] when null.
  final String? announcementText;

  static const Key indicatorKey = WorkingIndicator.indicatorKey;
  static const Key cassetteKey = Key('working-cassette');
  static const Key captionKey = WorkingIndicator.captionKey;

  /// `.loadtape .cs { width: 56px }`.
  static const double cassetteWidth = 56;

  static const String announcement = WorkingIndicator.announcement;
  static const String caption = 'The DJ is listening…';

  /// An album session's line (board A1): says the catalogue check too.
  static const String albumCaption = WorkingIndicator.albumCaption;
  static const String albumAnnouncement = WorkingIndicator.albumAnnouncement;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Semantics(
      key: indicatorKey,
      container: true,
      liveRegion: true,
      label: announcementText ?? announcement,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Transform.rotate(
                angle: -0.07,
                child: CassetteTile(
                  key: cassetteKey,
                  width: cassetteWidth,
                  caseColor: caseColor ?? CassetteTile.caseColors.first,
                  spinning: true,
                  shadow: true,
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  captionText ?? caption,
                  key: captionKey,
                  style: tokens.meta.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: tokens.muted,
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
  const LyricFade({super.key, this.bottomInset = 0, super.child});

  /// How much of the viewport's bottom the floating panel covers.
  final double bottomInset;

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
      RenderLyricFade(bottomInset: bottomInset);

  @override
  void updateRenderObject(BuildContext context, RenderLyricFade renderObject) {
    renderObject.bottomInset = bottomInset;
  }
}

class RenderLyricFade extends RenderProxyBox {
  RenderLyricFade({double bottomInset = 0}) : _bottomInset = bottomInset;

  double _bottomInset;
  double get bottomInset => _bottomInset;
  set bottomInset(double value) {
    if (value == _bottomInset) return;
    _bottomInset = value;
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
    if (viewport is RenderBox && viewport.hasSize) {
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
