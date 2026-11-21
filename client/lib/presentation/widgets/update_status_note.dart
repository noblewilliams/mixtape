import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter, lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_update_provider.dart';
import '../theme/mixtape_theme.dart';
import 'foundation/status_word.dart' show statusOkGlyph;

/// The over-the-air update note at the end of the Home and You title rows
/// (approval `docs/mockups/approved/2026-11-20-ota-update-states.md`, revised
/// 2026-11-21 by `docs/mockups/2026-11-21-ota-restart-orb-r3.html`).
///
/// - A patch is downloaded: "Update" (13 pt semibold) with "(restart
///   required)" (7 pt italic) hanging under it, and a flat green dot that
///   breathes. The whole note is the tap target.
/// - After the tap: the words slide left and blur out, and the dot itself
///   stretches into the level bars. Only the bars stay; the app closes.
/// - The start that boots the patch: the bars, then they gather into one
///   point, the check draws out of it, and "Updated" blurs in. Then it fades.
///
/// One glyph throughout: the same three rounded bars are the dot, the loader
/// and the gathered point of the tick. Everything is drawn in code, because an
/// over-the-air patch cannot add icon-font glyphs the release never used.
class UpdateStatusNote extends ConsumerStatefulWidget {
  const UpdateStatusNote({super.key, this.lineHeight});

  /// The title's line height when the note sits beside it, so the note
  /// centres on the title; null on a line of its own.
  final double? lineHeight;

  /// For [LargeTitleScaffold.titleNote].
  static Widget inTitle(BuildContext context, double? lineHeight) =>
      UpdateStatusNote(lineHeight: lineHeight);

  static const String availableLabel = 'Update';
  static const String restartLabel = '(restart required)';
  static const String updatedLabel = 'Updated';

  static const String availableSemantics =
      'Update, restart required. Double-tap to restart mixtape.';
  static const String closingSemantics =
      'Restarting mixtape. Open it again to finish.';
  static const String updatingSemantics = 'Updating mixtape.';
  static const String updatedSemantics = 'mixtape updated.';

  static const Key noteKey = Key('update-note');
  static const Key dotKey = Key('update-note-dot');
  static const Key barsKey = Key('update-note-bars');
  static const Key checkKey = Key('update-note-check');

  /// The words leaving or arriving: a 10 pt slide with a blur.
  static const Duration swapFor = Duration(milliseconds: 280);

  /// The dot stretching into the bars.
  static const Duration morphFor = Duration(milliseconds: 320);

  /// The bars gathering and the check drawing out of them.
  static const Duration tickFor = Duration(milliseconds: 480);

  /// "Updated" fading away once its time is up.
  static const Duration fadeFor = Duration(milliseconds: 320);

  /// One rise and fall of the level bars.
  static const Duration barsLoop = Duration(milliseconds: 900);

  /// One breath of the dot.
  static const Duration breathFor = Duration(milliseconds: 2400);

  static const double minTarget = 44;
  static const double gap = 7;
  static const double fontSize = 13;
  static const double restartFontSize = 7;
  static const double glyphBox = 14;
  static const double largestGlyphBox = 20;

  /// How far the words travel as they leave or arrive.
  static const double slide = 10;

  /// The words grow with text size up to 1.5×.
  static TextScaler labelScaler(BuildContext context) =>
      MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.5);

  static double glyphBoxOf(BuildContext context) => MediaQuery.textScalerOf(
    context,
  ).scale(glyphBox).clamp(glyphBox, largestGlyphBox);

  static TextStyle labelStyle(BuildContext context) =>
      context.tokens.meta.copyWith(
        fontSize: fontSize,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
        height: 1.2,
        color: context.tokens.text,
      );

  static TextStyle restartStyle(BuildContext context) =>
      context.tokens.meta.copyWith(
        fontSize: restartFontSize,
        fontWeight: FontWeight.w400,
        fontStyle: FontStyle.italic,
        letterSpacing: 0,
        height: 1.1,
        color: context.tokens.smoke,
      );

  static double _textWidth(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textScaler: labelScaler(context),
      textDirection: Directionality.of(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  /// The note at its widest, for the title row's fit: "Update", the gap and
  /// the glyph, or the small line under it if that runs wider.
  static double widestWidth(BuildContext context) {
    final word = _textWidth(context, availableLabel, labelStyle(context));
    final small = _textWidth(context, restartLabel, restartStyle(context));
    return math.max(word + gap + glyphBoxOf(context), small);
  }

  @override
  ConsumerState<UpdateStatusNote> createState() => _UpdateStatusNoteState();
}

enum _Shown { available, closing, updating, updated }

_Shown? _shownFor(AppUpdatePhase? phase) => switch (phase) {
  AppUpdatePhase.ready => _Shown.available,
  AppUpdatePhase.closing => _Shown.closing,
  AppUpdatePhase.applied => _Shown.updating,
  AppUpdatePhase.updated => _Shown.updated,
  _ => null,
};

enum _Glyph { dot, bars, tick }

class _UpdateStatusNoteState extends ConsumerState<UpdateStatusNote> {
  /// "Updated" stays drawn while it fades after its time is up.
  bool _fadingOut = false;

  @override
  Widget build(BuildContext context) {
    final phase = ref.watch(appUpdateProvider.select((s) => s.phase));
    ref.listen(appUpdateProvider.select((s) => s.phase), (previous, next) {
      if (_shownFor(previous) == _Shown.updated &&
          _shownFor(next) == null &&
          !MediaQuery.disableAnimationsOf(context)) {
        setState(() => _fadingOut = true);
      }
    });
    final now = _shownFor(phase);
    final shown = now ?? (_fadingOut ? _Shown.updated : null);
    if (shown == null) return const SizedBox.shrink();

    final still = MediaQuery.disableAnimationsOf(context);
    final box = UpdateStatusNote.glyphBoxOf(context);
    final available = shown == _Shown.available;
    final line = widget.lineHeight;
    final glyph = switch (shown) {
      _Shown.available => _Glyph.dot,
      _Shown.closing || _Shown.updating => _Glyph.bars,
      _Shown.updated => _Glyph.tick,
    };
    final semantics = switch (shown) {
      _Shown.available => UpdateStatusNote.availableSemantics,
      _Shown.closing => UpdateStatusNote.closingSemantics,
      _Shown.updating => UpdateStatusNote.updatingSemantics,
      _Shown.updated => UpdateStatusNote.updatedSemantics,
    };

    final words = switch (shown) {
      _Shown.available => const _AvailableWords(key: ValueKey('available')),
      _Shown.closing ||
      _Shown.updating => const SizedBox.shrink(key: ValueKey('none')),
      _Shown.updated => Text(
        UpdateStatusNote.updatedLabel,
        key: const ValueKey('updated'),
        maxLines: 1,
        softWrap: false,
        textScaler: UpdateStatusNote.labelScaler(context),
        style: UpdateStatusNote.labelStyle(
          context,
        ).copyWith(color: context.tokens.okInk),
      ),
    };

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSwitcher(
          duration: still ? Duration.zero : UpdateStatusNote.swapFor,
          // Out first, then in: the incoming words wait for the old ones.
          switchInCurve: const Interval(0.5, 1, curve: Curves.easeOut),
          switchOutCurve: const Interval(0.5, 1, curve: Curves.easeIn),
          // The words' right edge stays put beside the pinned glyph.
          layoutBuilder: (current, previous) => Stack(
            clipBehavior: Clip.none,
            alignment: AlignmentDirectional.centerEnd,
            children: [...previous, ?current],
          ),
          transitionBuilder: (child, animation) => _SlideBlur(
            animation: animation,
            incoming: child.key == words.key,
            child: child,
          ),
          child: words,
        ),
        // The gap closes with the words, so the bars sit alone at the edge.
        AnimatedContainer(
          duration: still ? Duration.zero : UpdateStatusNote.swapFor,
          width: glyph == _Glyph.bars ? 0 : UpdateStatusNote.gap,
        ),
        SizedBox.square(
          dimension: box,
          child: Stack(
            children: [
              Positioned.fill(
                child: _MorphGlyph(glyph: glyph, still: still),
              ),
              // Markers for tests and tools: which shape the glyph is in.
              switch (glyph) {
                _Glyph.dot => const SizedBox.shrink(
                  key: UpdateStatusNote.dotKey,
                ),
                _Glyph.bars => const SizedBox.shrink(
                  key: UpdateStatusNote.barsKey,
                ),
                _Glyph.tick => const SizedBox.shrink(
                  key: UpdateStatusNote.checkKey,
                ),
              },
            ],
          ),
        ),
      ],
    );

    return AnimatedOpacity(
      opacity: now == null ? 0 : 1,
      duration: UpdateStatusNote.fadeFor,
      curve: Curves.easeOut,
      onEnd: () {
        if (_fadingOut && mounted) setState(() => _fadingOut = false);
      },
      child: Semantics(
        key: UpdateStatusNote.noteKey,
        container: true,
        button: available,
        liveRegion: !available,
        label: semantics,
        onTap: available ? _restart : null,
        child: ExcludeSemantics(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: available ? _restart : null,
            child: SizedBox(
              height: math.max(UpdateStatusNote.minTarget, line ?? 0),
              child: Align(
                widthFactor: 1,
                alignment: line == null
                    ? AlignmentDirectional.centerEnd
                    : AlignmentDirectional.bottomEnd,
                // Beside the title, the drawn note centres on the title's
                // line; the rest of the 44 pt target rises above it.
                child: SizedBox(
                  height: line,
                  child: Center(
                    widthFactor: 1,
                    child: FittedBox(fit: BoxFit.scaleDown, child: content),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _restart() => unawaited(ref.read(appUpdateProvider.notifier).restart());
}

/// "Update", with "(restart required)" hanging under it. The small line is
/// positioned on its own, so it never pushes the title row or the glyph.
class _AvailableWords extends StatelessWidget {
  const _AvailableWords({super.key});

  @override
  Widget build(BuildContext context) {
    final scaler = UpdateStatusNote.labelScaler(context);
    final wordLine = scaler.scale(UpdateStatusNote.fontSize) * 1.2;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Text(
          UpdateStatusNote.availableLabel,
          maxLines: 1,
          softWrap: false,
          textScaler: scaler,
          style: UpdateStatusNote.labelStyle(context),
        ),
        Positioned(
          left: 0,
          top: wordLine,
          child: Text(
            UpdateStatusNote.restartLabel,
            maxLines: 1,
            softWrap: false,
            textScaler: scaler,
            style: UpdateStatusNote.restartStyle(context),
          ),
        ),
      ],
    );
  }
}

/// Words leaving slide left and blur out; words arriving come in from the
/// right, blurred, and settle sharp. Reduced motion skips straight to the end.
class _SlideBlur extends StatelessWidget {
  const _SlideBlur({
    required this.animation,
    required this.incoming,
    required this.child,
  });

  final Animation<double> animation;
  final bool incoming;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    child: child,
    builder: (context, child) {
      final t = animation.value;
      final away = 1 - t;
      final dx = (incoming ? 1 : -1) * UpdateStatusNote.slide * away;
      final sigma = 3 * away;
      return Opacity(
        opacity: t.clamp(0, 1),
        child: Transform.translate(
          offset: Offset(dx, 0),
          child: sigma < 0.05
              ? child
              : ImageFiltered(
                  imageFilter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                  child: child,
                ),
        ),
      );
    },
  );
}

/// The one glyph: three rounded bars that are a dot, the loader, or the
/// gathered point the check draws out of.
class _MorphGlyph extends StatefulWidget {
  const _MorphGlyph({required this.glyph, required this.still});

  final _Glyph glyph;
  final bool still;

  @override
  State<_MorphGlyph> createState() => _MorphGlyphState();
}

class _MorphGlyphState extends State<_MorphGlyph>
    with TickerProviderStateMixin {
  late final AnimationController _morph = AnimationController(
    vsync: this,
    duration: UpdateStatusNote.morphFor,
    value: widget.glyph == _Glyph.dot ? 0 : 1,
  );
  late final AnimationController _tick = AnimationController(
    vsync: this,
    duration: UpdateStatusNote.tickFor,
    value: widget.glyph == _Glyph.tick ? 1 : 0,
  );
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: UpdateStatusNote.barsLoop,
  );
  late final AnimationController _breath = AnimationController(
    vsync: this,
    duration: UpdateStatusNote.breathFor,
  );

  @override
  void initState() {
    super.initState();
    _syncLoops();
  }

  @override
  void didUpdateWidget(_MorphGlyph old) {
    super.didUpdateWidget(old);
    if (old.glyph != widget.glyph || old.still != widget.still) {
      final morphTo = widget.glyph == _Glyph.dot ? 0.0 : 1.0;
      final tickTo = widget.glyph == _Glyph.tick ? 1.0 : 0.0;
      if (widget.still) {
        _morph.value = morphTo;
        _tick.value = tickTo;
      } else {
        unawaited(_morph.animateTo(morphTo, curve: Curves.easeInOutCubic));
        unawaited(_tick.animateTo(tickTo, curve: Curves.easeInOut));
      }
      _syncLoops();
    }
  }

  /// The dot breathes, the bars rise and fall; nothing moves under reduced
  /// motion or once the tick is drawn.
  void _syncLoops() {
    final breathe = !widget.still && widget.glyph == _Glyph.dot;
    final bounce = !widget.still && widget.glyph == _Glyph.bars;
    if (breathe && !_breath.isAnimating) {
      unawaited(_breath.repeat());
    } else if (!breathe) {
      _breath.stop();
    }
    if (bounce && !_loop.isAnimating) {
      unawaited(_loop.repeat());
    } else if (!bounce) {
      _loop.stop();
    }
  }

  @override
  void dispose() {
    _morph.dispose();
    _tick.dispose();
    _loop.dispose();
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return RepaintBoundary(
      child: CustomPaint(
        painter: _MorphPainter(
          morph: _morph,
          tick: _tick,
          loop: _loop,
          breath: _breath,
          dotColor: statusOkGlyph(context),
          barColor: tokens.plum,
          okColor: tokens.okInk,
        ),
      ),
    );
  }
}

class _MorphPainter extends CustomPainter {
  _MorphPainter({
    required this.morph,
    required this.tick,
    required this.loop,
    required this.breath,
    required this.dotColor,
    required this.barColor,
    required this.okColor,
  }) : super(repaint: Listenable.merge([morph, tick, loop, breath]));

  final Animation<double> morph;
  final Animation<double> tick;
  final AnimationController loop;
  final AnimationController breath;
  final Color dotColor;
  final Color barColor;
  final Color okColor;

  /// The loader's resting heights and offsets, out of the 14 pt box.
  static const List<double> _rest = [7, 12, 9];
  static const List<double> _offset = [-4.5, 0, 4.5];
  static const double _bar = 2.5;
  static const double _dot = 8;

  /// 0.4 → 1 → 0.4 over the loop, eased each way, each bar a third ahead.
  double _bounce(int i) {
    if (!loop.isAnimating) return 1;
    final t = (loop.value + i / 3) % 1;
    final rise = t < 0.5 ? t * 2 : (1 - t) * 2;
    return 0.4 + 0.6 * Curves.easeInOut.transform(rise);
  }

  /// A slow breath: 1 → 0.82 → 1.
  double get _breathScale {
    if (!breath.isAnimating) return 1;
    final rise = breath.value < 0.5 ? breath.value * 2 : (1 - breath.value) * 2;
    return 1 - 0.18 * Curves.easeInOut.transform(rise);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.shortestSide / UpdateStatusNote.glyphBox;
    canvas.scale(k);
    const centre = Offset(7, 7);
    final m = morph.value;
    final t = tick.value;
    // The tick: the bars gather (first 45%), then the check draws.
    final gather = (t / 0.45).clamp(0.0, 1.0);
    final draw = ((t - 0.45) / 0.55).clamp(0.0, 1.0);
    final paint = Paint()..isAntiAlias = true;

    for (var i = 0; i < 3; i++) {
      final middle = i == 1;
      double width;
      double height;
      double dx;
      double opacity;
      Color color;
      if (middle) {
        final dot = _dot * (m == 0 ? _breathScale : 1);
        width = lerpDouble(dot, _bar, m)!;
        height = lerpDouble(dot, _rest[i] * _bounce(i), m)!;
        dx = 0;
        opacity = 1;
        color = Color.lerp(dotColor, barColor, m)!;
      } else {
        // The side bars grow out of the dot's centre as it stretches.
        width = _bar;
        height = lerpDouble(_bar, _rest[i] * _bounce(i), m)!;
        dx = _offset[i] * m;
        opacity = m;
        color = barColor;
      }
      if (gather > 0) {
        height = lerpDouble(height, _bar, gather)!;
        dx = lerpDouble(dx, 0, gather)!;
        color = Color.lerp(color, okColor, gather)!;
        opacity *= 1 - draw;
      }
      if (opacity <= 0) continue;
      paint.color = color.withValues(alpha: color.a * opacity);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: centre.translate(dx, 0),
            width: width,
            height: height,
          ),
          Radius.circular(math.min(width, height) / 2),
        ),
        paint,
      );
    }

    if (draw > 0) {
      final check = Path()
        ..moveTo(3, 7.4)
        ..lineTo(5.9, 10.2)
        ..lineTo(11, 4.2);
      final metric = check.computeMetrics().first;
      canvas.drawPath(
        metric.extractPath(0, metric.length * draw),
        Paint()
          ..color = okColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true,
      );
    }
  }

  @override
  bool shouldRepaint(_MorphPainter old) =>
      old.dotColor != dotColor ||
      old.barColor != barColor ||
      old.okColor != okColor;
}
