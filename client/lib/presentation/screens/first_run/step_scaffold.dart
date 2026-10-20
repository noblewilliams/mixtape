/// The chrome every first-run page shares (board
/// `docs/mockups/2026-10-20-first-run-flow-states.html`, `.screen.gfx`;
/// approval `docs/mockups/approved/2026-10-20-first-run-flow.md`).
///
/// A full-bleed generated background under a dark scrim, cream text, the
/// outlined tape back button, and on path B the "STEP n OF 3" counter over a
/// 2 pt progress line. The column is anchored at the foot and scrolls when
/// the text is large, so the foot line always follows the content.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';

/// The six backgrounds, one prism hue per page (spec → Backgrounds).
enum FirstRunBackground {
  welcome('bg-welcome.jpg'),
  artists('bg-artists.jpg'),
  step1('bg-step-1.jpg'),
  step2('bg-step-2.jpg'),
  step3('bg-step-3.jpg'),
  signIn('bg-sign-in.jpg');

  const FirstRunBackground(this.file);
  final String file;

  String get asset => 'assets/first_run/$file';
}

/// The first-run palette: cream ink on the images, paper pills and fields.
abstract final class FirstRunColors {
  static const Color cream = Color(0xFFEFE6DA);
  static const Color paper = Color(0xFFE8DFCF);
  static const Color ink = Color(0xFF1C1A1E);
  static const Color paperMuted = Color(0xFF5C555C);
  static const Color chip = Color(0xFFD8CCB7);
  static const Color err = Color(0xFFF6BFCB);

  /// Behind the image while it loads, and where it does not reach.
  static const Color base = Color(0xFF140C12);

  /// The board's scrim: darker behind the counter and over the pills.
  static const LinearGradient scrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0, 0.14, 0.45, 1],
    colors: [
      Color.fromRGBO(10, 6, 10, 0.66),
      Color.fromRGBO(10, 6, 10, 0.52),
      Color.fromRGBO(10, 6, 10, 0.52),
      Color.fromRGBO(10, 6, 10, 0.62),
    ],
  );
}

/// The tokens on a graphic page: every ink is cream.
MixtapeTokens firstRunTokens(MixtapeTokens base) {
  const cream = FirstRunColors.cream;
  final muted = cream.withValues(alpha: 0.8);
  return base.copyWith(
    text: cream,
    plum: cream,
    smoke: cream,
    muted: muted,
    hairline: cream.withValues(alpha: 0.35),
    errInk: FirstRunColors.err,
    largeTitle: base.largeTitle.copyWith(color: cream),
    smallTitle: base.smallTitle.copyWith(color: cream),
    section: base.section.copyWith(color: muted),
    rowTitle: base.rowTitle.copyWith(color: cream),
    body: base.body.copyWith(color: cream),
    secondary: base.secondary.copyWith(color: cream),
    meta: base.meta.copyWith(color: muted),
    label: base.label.copyWith(color: cream),
    wordmark: base.wordmark.copyWith(color: cream),
  );
}

/// The tokens on paper (the composer and the artist fields): dark ink, no
/// hairline, no shadow.
MixtapeTokens paperTokens(MixtapeTokens base) => base.copyWith(
  text: FirstRunColors.ink,
  plum: FirstRunColors.ink,
  smoke: FirstRunColors.paperMuted,
  muted: FirstRunColors.paperMuted,
  hairline: Colors.transparent,
  field: FirstRunColors.paper,
  glassShadow: Colors.transparent,
  body: base.body.copyWith(color: FirstRunColors.ink),
  secondary: base.secondary.copyWith(color: FirstRunColors.ink),
  meta: base.meta.copyWith(color: FirstRunColors.paperMuted),
);

/// [child] under [tokens] in place of the ambient ones.
Widget withTokens(
  BuildContext context,
  MixtapeTokens Function(MixtapeTokens base) tokens,
  Widget child,
) {
  final theme = Theme.of(context);
  final base =
      theme.extension<MixtapeTokens>() ??
      (theme.brightness == Brightness.dark
          ? MixtapeTokens.dark
          : MixtapeTokens.light);
  final next = tokens(base);
  return Theme(
    data: theme.copyWith(
      extensions: [
        ...theme.extensions.values.where((e) => e is! MixtapeTokens),
        next,
      ],
      textSelectionTheme: theme.textSelectionTheme.copyWith(
        cursorColor: next.plum,
      ),
    ),
    child: DefaultTextStyle.merge(
      style: TextStyle(color: next.text),
      child: child,
    ),
  );
}

/// First-run type: the board's `.fr-h`, `.fr-line` and `.fp`.
abstract final class FirstRunType {
  static TextStyle headline(MixtapeTokens tokens) => tokens.largeTitle.copyWith(
    fontSize: 36,
    fontWeight: FontWeight.w800,
    height: 1.06,
    letterSpacing: -0.9,
    color: FirstRunColors.cream,
  );

  static TextStyle line(MixtapeTokens tokens) => tokens.body.copyWith(
    fontSize: 16,
    height: 1.4,
    color: FirstRunColors.cream,
  );

  static TextStyle pill(MixtapeTokens tokens) => tokens.body.copyWith(
    fontSize: 17,
    height: 1.2,
    fontWeight: FontWeight.w600,
  );
}

/// The two transport glyphs the flow uses: rewind for back, fast-forward
/// for Continue. Drawn from the board's `i-rw` and `i-ff` symbols; [filled]
/// false strokes the fast-forward hollow (the disabled Continue).
enum TransportKind { rewind, fastForward }

class TransportGlyph extends StatelessWidget {
  const TransportGlyph({
    super.key,
    required this.kind,
    this.size = 16,
    this.filled = true,
    this.color,
  });

  final TransportKind kind;
  final double size;
  final bool filled;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _TransportPainter(
        kind: kind,
        filled: filled,
        color:
            color ?? DefaultTextStyle.of(context).style.color ?? Colors.black,
      ),
    ),
  );
}

class _TransportPainter extends CustomPainter {
  const _TransportPainter({
    required this.kind,
    required this.filled,
    required this.color,
  });

  final TransportKind kind;
  final bool filled;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 24;
    canvas.scale(scale);
    final path = Path();
    if (kind == TransportKind.rewind) {
      // M20 6l-8 6 8 6zM12 6l-8 6 8 6z
      path
        ..moveTo(20, 6)
        ..lineTo(12, 12)
        ..lineTo(20, 18)
        ..close()
        ..moveTo(12, 6)
        ..lineTo(4, 12)
        ..lineTo(12, 18)
        ..close();
    } else {
      // m4 6 8 6-8 6zM12 6l8 6-8 6z
      path
        ..moveTo(4, 6)
        ..lineTo(12, 12)
        ..lineTo(4, 18)
        ..close()
        ..moveTo(12, 6)
        ..lineTo(20, 12)
        ..lineTo(12, 18)
        ..close();
    }
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;
    if (filled) {
      paint.style = PaintingStyle.fill;
    } else {
      paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round;
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_TransportPainter old) =>
      old.kind != kind || old.filled != filled || old.color != color;
}

/// The app's tape shape drawn as an outline: 40 pt tall, 6 pt top and 10 pt
/// bottom radii, a 1.5 pt stroke, no fill, no shadow, carrying the rewind
/// glyph. Cream on the graphic pages; [color] gives the text colour on the
/// app's gradient screens. The padded tap target exceeds 44 pt.
class TapeBackButton extends StatelessWidget {
  const TapeBackButton({super.key = defaultKey, this.onPressed, this.color});

  static const Key defaultKey = Key('first-run-back');
  static const double width = 54;

  static const BorderRadius radius = BorderRadius.only(
    topLeft: Radius.circular(MixtapeMetrics.tapeRadiusTop),
    topRight: Radius.circular(MixtapeMetrics.tapeRadiusTop),
    bottomLeft: Radius.circular(MixtapeMetrics.tapeRadiusBottom),
    bottomRight: Radius.circular(MixtapeMetrics.tapeRadiusBottom),
  );

  /// Pops the nearest navigator when null.
  final VoidCallback? onPressed;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ink = color ?? FirstRunColors.cream;
    final press = onPressed ?? () => Navigator.of(context).maybePop();
    // The label replaces the glyph's (empty) semantics, so the node must
    // carry the tap itself or VoiceOver cannot activate it.
    return Semantics(
      label: 'Back',
      button: true,
      enabled: true,
      onTap: press,
      excludeSemantics: true,
      child: TextButton(
        onPressed: press,
        style: TextButton.styleFrom(
          foregroundColor: ink,
          minimumSize: const Size(width, MixtapeMetrics.tapeButtonHeight),
          fixedSize: const Size(width, MixtapeMetrics.tapeButtonHeight),
          padding: EdgeInsets.zero,
          tapTargetSize: MaterialTapTargetSize.padded,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: BorderSide(color: ink.withValues(alpha: 0.7), width: 1.5),
          ),
        ),
        child: TransportGlyph(kind: TransportKind.rewind, size: 19, color: ink),
      ),
    );
  }
}

/// A 56 pt paper pill (the board's `.fp` on `.screen.gfx`): paper with dark
/// text and no shadow. Disabled it is translucent paper in cream at regular
/// weight; [forward] adds the fast-forward glyph after the label, solid when
/// enabled and hollow when not, so the state is never opacity alone.
class FirstRunPill extends StatelessWidget {
  const FirstRunPill({
    super.key,
    required this.label,
    required this.onPressed,
    this.emphasis = false,
    this.forward = false,
    this.leading,
    this.trailing,
    this.semanticsHint,
    this.disabledHint,
  });

  final String label;
  final VoidCallback? onPressed;

  /// The board's `.fp.go`: the bold primary action.
  final bool emphasis;
  final bool forward;
  final Widget? leading;
  final Widget? trailing;

  /// Read after the label, e.g. "opens outside Mixtape".
  final String? semanticsHint;

  /// Read after the label while disabled, e.g. "Add three artists."
  final String? disabledHint;

  static const double height = 56;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final enabled = onPressed != null;
    final ink = enabled ? FirstRunColors.ink : FirstRunColors.cream;
    final weight = !enabled
        ? FontWeight.w400
        : (emphasis || forward)
        ? FontWeight.w700
        : FontWeight.w600;
    final style = FirstRunType.pill(
      tokens,
    ).copyWith(color: ink, fontWeight: weight);
    // Merged, so the hint is read on the button rather than beside it.
    return MergeSemantics(
      child: Semantics(
        hint: enabled ? semanticsHint : (disabledHint ?? semanticsHint),
        child: TextButton(
          onPressed: onPressed,
          style: ButtonStyle(
            minimumSize: const WidgetStatePropertyAll(Size.fromHeight(height)),
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
            shape: const WidgetStatePropertyAll(StadiumBorder()),
            elevation: const WidgetStatePropertyAll(0),
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.disabled)
                  ? FirstRunColors.paper.withValues(alpha: 0.45)
                  : FirstRunColors.paper,
            ),
            foregroundColor: WidgetStatePropertyAll(ink),
            overlayColor: WidgetStatePropertyAll(
              FirstRunColors.ink.withValues(alpha: 0.08),
            ),
          ),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: ink),
            child: IconTheme.merge(
              data: IconThemeData(color: ink, size: 18),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (leading != null) ...[leading!, const SizedBox(width: 10)],
                  Flexible(
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      style: style,
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: 10),
                    trailing!,
                  ],
                  if (forward) ...[
                    const SizedBox(width: 10),
                    TransportGlyph(
                      kind: TransportKind.fastForward,
                      filled: enabled,
                      color: ink,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A text link at the foot of a page (the board's `.fr-foot`), 44 pt tall.
class FootLink extends StatelessWidget {
  const FootLink({
    super.key,
    required this.label,
    required this.onPressed,
    this.lead,
  });

  final String label;
  final VoidCallback? onPressed;

  /// Quiet words before the link, e.g. "Already have an account?".
  final String? lead;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final style = tokens.body.copyWith(
      fontSize: 15,
      height: 1.3,
      color: FirstRunColors.cream,
    );
    return Semantics(
      label: lead == null ? label : '$lead $label',
      button: true,
      enabled: onPressed != null,
      onTap: onPressed,
      excludeSemantics: true,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: FirstRunColors.cream,
          minimumSize: const Size(MixtapeMetrics.minTarget, 44),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text.rich(
          TextSpan(
            children: [
              if (lead != null) TextSpan(text: '$lead '),
              TextSpan(
                text: label,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          textAlign: TextAlign.center,
          style: style,
        ),
      ),
    );
  }
}

/// A quiet foot line that is not a link (`.fr-foot.quiet`).
class FootNote extends StatelessWidget {
  const FootNote(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 44),
    child: Center(
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: context.tokens.body.copyWith(
          fontSize: 15,
          height: 1.3,
          color: FirstRunColors.cream,
        ),
      ),
    ),
  );
}

/// One first-run page.
///
/// [top] sits at the top of the column (the wordmark, the cassette) and the
/// rest is anchored at the foot: [headline], [line], [body], [actions], then
/// [foot]. When the content is taller than the screen (200 % text) the whole
/// column scrolls and the foot follows the content.
class StepScaffold extends StatelessWidget {
  const StepScaffold({
    super.key,
    required this.background,
    required this.headline,
    this.step,
    this.showBack = true,
    this.top,
    this.line,
    this.body = const [],
    this.actions = const [],
    this.foot,
  }) : assert(step == null || (step >= 1 && step <= totalSteps));

  final FirstRunBackground background;
  final String headline;

  /// 1 to 3 on path B's counted pages; null draws no counter or progress.
  final int? step;
  final bool showBack;
  final Widget? top;
  final String? line;
  final List<Widget> body;
  final List<Widget> actions;
  final Widget? foot;

  static const int totalSteps = 3;
  static const Key counterKey = Key('first-run-counter');
  static const Key progressKey = Key('first-run-progress');
  static const Key progressFillKey = Key('first-run-progress-fill');
  static const Key headlineKey = Key('first-run-headline');
  static const Key backgroundKey = Key('first-run-background');

  static const double topBarHeight = 52;
  static const double progressHeight = 2;
  static const double footPadding = 34;

  /// The accessible page name: "Step 2 of 3, How do you want to add it?".
  static String pageName(String headline, int? step) =>
      step == null ? headline : 'Step $step of $totalSteps, $headline';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: FirstRunColors.base,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // The image is the theme on these pages, the same in light and
          // dark, and decoration only.
          Image.asset(
            background.asset,
            key: backgroundKey,
            fit: BoxFit.cover,
            excludeFromSemantics: true,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(gradient: FirstRunColors.scrim),
          ),
          withTokens(context, firstRunTokens, Builder(builder: _page)),
        ],
      ),
    );
  }

  Widget _page(BuildContext context) {
    final tokens = context.tokens;
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: topBarHeight,
            child: Stack(
              alignment: Alignment.center,
              children: [
                if (showBack)
                  const Positioned(left: 8, child: TapeBackButton()),
                if (step != null)
                  Positioned(
                    left: 70,
                    right: 70,
                    child: ExcludeSemantics(
                      child: Text(
                        'STEP $step OF $totalSteps',
                        key: counterKey,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        // The counter is decorative; it stays one line at
                        // any text size, and the headline carries the step.
                        textScaler: TextScaler.noScaling,
                        style: tokens.meta.copyWith(
                          fontSize: 12,
                          height: 1,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.92,
                          color: FirstRunColors.cream.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (step != null)
            ExcludeSemantics(
              child: Container(
                key: progressKey,
                height: progressHeight,
                color: FirstRunColors.cream.withValues(alpha: 0.35),
                alignment: Alignment.centerLeft,
                // No animation: each page draws its own fill, so the line
                // jumps between steps (and reduced motion has nothing to
                // stop).
                child: FractionallySizedBox(
                  key: progressFillKey,
                  widthFactor: step! / totalSteps,
                  heightFactor: 1,
                  child: const ColoredBox(color: FirstRunColors.cream),
                ),
              ),
            )
          else
            const SizedBox(height: progressHeight),
          Expanded(child: LayoutBuilder(builder: _scroll)),
        ],
      ),
    );
  }

  Widget _scroll(BuildContext context, BoxConstraints constraints) {
    final bottom = MediaQuery.paddingOf(context).bottom + footPadding;
    final padding = EdgeInsets.fromLTRB(
      MixtapeMetrics.screenSidePadding,
      8,
      MixtapeMetrics.screenSidePadding,
      bottom,
    );
    return SingleChildScrollView(
      padding: padding,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: math.max(0, constraints.maxHeight - padding.vertical),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: top == null
              ? MainAxisAlignment.end
              : MainAxisAlignment.spaceBetween,
          children: [
            ?top,
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (top != null) const SizedBox(height: 16),
                Semantics(
                  header: true,
                  namesRoute: true,
                  label: pageName(headline, step),
                  excludeSemantics: true,
                  child: Text(
                    headline,
                    key: headlineKey,
                    style: FirstRunType.headline(context.tokens),
                  ),
                ),
                if (line != null) ...[
                  const SizedBox(height: 12),
                  Text(line!, style: FirstRunType.line(context.tokens)),
                ],
                ...body,
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 28),
                  for (var i = 0; i < actions.length; i++) ...[
                    if (i > 0) const SizedBox(height: 12),
                    actions[i],
                  ],
                ],
                if (foot != null) ...[const SizedBox(height: 8), foot!],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
