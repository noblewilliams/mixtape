/// One turn of the DJ conversation, and the working indicator that stands in
/// for the turn still being written
/// (`docs/mockups/approved/2026-09-17-mobile-conversation-states.md`; `.turn`,
/// `.turn.me`, `.turn.dj`, `.turn.err` and `.dots` on
/// `docs/mockups/2026-09-17-mobile-conversation-states.html`).
///
/// Flush on the gradient — no card, no container, and (the board's deliberate
/// departure from the shipped screen) no decorative accent bar on the DJ's
/// side.
library;

import 'package:flutter/material.dart';

import '../theme/mixtape_theme.dart';

enum ConversationTurnKind { user, dj, error }

class ConversationTurn extends StatelessWidget {
  const ConversationTurn({
    super.key,
    required this.text,
    required this.kind,
    this.onResend,
    this.resendEnabled = true,
  });

  final String text;
  final ConversationTurnKind kind;

  /// Error turns only: resends the user turn this one answers. Null hides the
  /// button entirely (a turn with no preceding user text to resend).
  final VoidCallback? onResend;

  /// Whether an already-drawn Resend is actionable: false while another send
  /// or an arrangement edit is in flight, per the approved record. The button
  /// stays visible and dimmed rather than disappearing.
  final bool resendEnabled;

  /// `.turn { max-width: 86% }`.
  static const double maxWidthFraction = 0.86;

  /// `.turn.me { border-radius: 18px 18px 4px 18px }`.
  static const BorderRadius userRadius = BorderRadius.only(
    topLeft: Radius.circular(18),
    topRight: Radius.circular(18),
    bottomRight: Radius.circular(4),
    bottomLeft: Radius.circular(18),
  );

  /// `.turn.dj` and `.turn.err`: `4px 18px 18px 18px`.
  static const BorderRadius djRadius = BorderRadius.only(
    topLeft: Radius.circular(4),
    topRight: Radius.circular(18),
    bottomRight: Radius.circular(18),
    bottomLeft: Radius.circular(18),
  );

  /// `rgba(255,255,255,.62)` — glass without a blur behind it, so the gradient
  /// reads through the way the board draws it.
  static const Color djFillLight = Color.fromRGBO(255, 255, 255, 0.62);

  /// `.phone.dark .turn.dj`.
  static const Color djFillDark = Color.fromRGBO(255, 255, 255, 0.10);

  /// `--err-bg`.
  static const Color errorFill = Color.fromRGBO(201, 104, 127, 0.14);

  /// `.turn.err .icobtn { width: 36px; height: 36px }`.
  static const double resendSize = 36;

  static const Key userKey = Key('turn-user');
  static const Key djKey = Key('turn-dj');

  /// Keyed as the shipped error bubble was, so history-bearing behaviour tests
  /// keep pointing at the same thing.
  static const Key errorKey = Key('error-bubble');
  static const Key resendKey = Key('retry-message');

  static Color fillFor(BuildContext context, ConversationTurnKind kind) =>
      switch (kind) {
        ConversationTurnKind.user => context.tokens.tapeFill,
        ConversationTurnKind.dj =>
          Theme.of(context).brightness == Brightness.dark
              ? djFillDark
              : djFillLight,
        ConversationTurnKind.error => errorFill,
      };

  static Color inkFor(BuildContext context, ConversationTurnKind kind) =>
      switch (kind) {
        ConversationTurnKind.user => context.tokens.tapeInk,
        ConversationTurnKind.dj => context.tokens.text,
        ConversationTurnKind.error => context.tokens.errInk,
      };

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final isUser = kind == ConversationTurnKind.user;
    final ink = inkFor(context, kind);

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxWidth = constraints.maxWidth.isFinite
              ? constraints.maxWidth * maxWidthFraction
              : MediaQuery.sizeOf(context).width * maxWidthFraction;
          return Container(
            key: switch (kind) {
              ConversationTurnKind.user => userKey,
              ConversationTurnKind.dj => djKey,
              ConversationTurnKind.error => errorKey,
            },
            margin: const EdgeInsets.symmetric(vertical: 5),
            padding: EdgeInsets.fromLTRB(
              14,
              10,
              kind == ConversationTurnKind.error && onResend != null ? 6 : 14,
              10,
            ),
            constraints: BoxConstraints(maxWidth: maxWidth),
            decoration: BoxDecoration(
              color: fillFor(context, kind),
              borderRadius: isUser ? userRadius : djRadius,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: Text(text, style: tokens.body.copyWith(color: ink))),
                if (kind == ConversationTurnKind.error && onResend != null) ...[
                  const SizedBox(width: 6),
                  SizedBox.square(
                    dimension: resendSize,
                    child: IconButton(
                      key: resendKey,
                      tooltip: 'Resend',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: resendSize,
                        minHeight: resendSize,
                      ),
                      onPressed: resendEnabled ? onResend : null,
                      icon: Semantics(
                        label: 'Resend',
                        child: Icon(
                          Icons.sync,
                          size: 18,
                          color: resendEnabled ? ink : ink.withValues(alpha: 0.4),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// `.dots`: three dots in a DJ bubble, with the caption arriving after the
/// screen's delay so a quick reply never flashes it.
///
/// The three dots are drawn at once and at their board opacities, so the
/// indicator reads the same whether it animates or not; the shimmer is a
/// refinement on top and never starts under reduced motion.
class WorkingIndicator extends StatefulWidget {
  const WorkingIndicator({super.key, required this.showCaption});

  final bool showCaption;

  static const Key indicatorKey = Key('typing-indicator');
  static const Key dotsKey = Key('working-dots');
  static const Key captionKey = Key('listening-caption');

  static const int dotCount = 3;
  static const double dotSize = 8;

  /// The board's staggered dot opacities, drawn all at once.
  static const List<double> dotOpacities = [0.5, 0.75, 1.0];

  static const String announcement = 'The DJ is working';
  static const String caption = 'the DJ is listening…';

  @override
  WorkingIndicatorState createState() => WorkingIndicatorState();
}

/// Public so tests can assert the dots never animate under reduced motion.
class WorkingIndicatorState extends State<WorkingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  /// Whether the shimmer is actually running.
  bool get isAnimating => _pulse.isAnimating;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse.stop();
      _pulse.value = 0;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Semantics(
      key: WorkingIndicator.indicatorKey,
      container: true,
      liveRegion: true,
      label: WorkingIndicator.announcement,
      child: ExcludeSemantics(
        child: Align(
          alignment: Alignment.centerLeft,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                key: WorkingIndicator.dotsKey,
                margin: const EdgeInsets.symmetric(vertical: 5),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: isDark
                      ? ConversationTurn.djFillDark
                      : ConversationTurn.djFillLight,
                  borderRadius: ConversationTurn.djRadius,
                ),
                child: AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, _) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < WorkingIndicator.dotCount; i++) ...[
                        if (i > 0) const SizedBox(width: 5),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: tokens.muted.withValues(
                              alpha: _alphaFor(i),
                            ),
                          ),
                          child: const SizedBox.square(
                            dimension: WorkingIndicator.dotSize,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (widget.showCaption)
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 2),
                  child: Text(
                    WorkingIndicator.caption,
                    key: WorkingIndicator.captionKey,
                    style: tokens.meta.copyWith(color: tokens.muted),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The board's fixed opacity per dot, shifted around the three of them while
  /// the shimmer runs. Still (`_pulse.value == 0`) it is exactly the board.
  double _alphaFor(int index) {
    final shift = (_pulse.value * WorkingIndicator.dotCount).floor();
    final at = (index - shift) % WorkingIndicator.dotCount;
    return WorkingIndicator.dotOpacities[at];
  }
}
