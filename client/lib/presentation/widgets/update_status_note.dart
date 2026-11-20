import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_update_provider.dart';
import '../theme/mixtape_theme.dart';

/// The over-the-air update note at the end of the Home and You title rows
/// (`docs/mockups/approved/2026-11-20-ota-update-states.md`): one 12 pt line
/// and a 14 pt glyph, 26 pt drawn and 44 pt to touch. "Update available" with
/// a still record dot once a patch is downloaded; "Updating" with three level
/// bars after the tap and on the start that boots the patch; "Updated" with a
/// check, then it fades. Nothing at all otherwise.
class UpdateStatusNote extends ConsumerStatefulWidget {
  const UpdateStatusNote({super.key, this.lineHeight});

  /// The title's line height when the note sits beside it, so the note
  /// centres on the title; null on a line of its own.
  final double? lineHeight;

  /// For [LargeTitleScaffold.titleNote].
  static Widget inTitle(BuildContext context, double? lineHeight) =>
      UpdateStatusNote(lineHeight: lineHeight);

  static const String availableLabel = 'Update available';
  static const String updatingLabel = 'Updating';
  static const String updatedLabel = 'Updated';

  static const String availableSemantics =
      'Update available. Double-tap to restart mixtape and finish the update.';
  static const String closingSemantics =
      'Updating. mixtape will close. Open it again to finish.';
  static const String updatedSemantics = 'mixtape updated.';

  static const Key noteKey = Key('update-note');
  static const Key dotKey = Key('update-note-dot');
  static const Key barsKey = Key('update-note-bars');
  static const Key checkKey = Key('update-note-check');

  /// The word and glyph changing: out, then in.
  static const Duration swapFor = Duration(milliseconds: 280);

  /// "Updated" fading away once its time is up.
  static const Duration fadeFor = Duration(milliseconds: 320);

  /// One rise and fall of the level bars.
  static const Duration barsLoop = Duration(milliseconds: 900);

  static const double minTarget = 44;
  static const double gap = 6;
  static const double fontSize = 12;
  static const double glyphBox = 14;
  static const double largestGlyphBox = 20;

  /// The label grows with text size up to 18 pt, as on the board's 200%.
  static TextScaler labelScaler(BuildContext context) =>
      MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.5);

  static double glyphBoxOf(BuildContext context) => MediaQuery.textScalerOf(
    context,
  ).scale(glyphBox).clamp(glyphBox, largestGlyphBox);

  static TextStyle labelStyle(BuildContext context) =>
      context.tokens.meta.copyWith(
        fontSize: fontSize,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
        height: 1.2,
      );

  /// The note at its widest ("Update available"), for the title row's fit.
  static double widestWidth(BuildContext context) {
    final painter = TextPainter(
      text: TextSpan(text: availableLabel, style: labelStyle(context)),
      textScaler: labelScaler(context),
      textDirection: Directionality.of(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width + gap + glyphBoxOf(context);
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

const Curve _fadeThrough = Interval(0.5, 1, curve: Curves.easeOut);

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

    final tokens = context.tokens;
    final ink = shown == _Shown.updated ? tokens.okInk : tokens.plum;
    final box = UpdateStatusNote.glyphBoxOf(context);
    final label = switch (shown) {
      _Shown.available => UpdateStatusNote.availableLabel,
      _Shown.closing || _Shown.updating => UpdateStatusNote.updatingLabel,
      _Shown.updated => UpdateStatusNote.updatedLabel,
    };
    final semantics = switch (shown) {
      _Shown.available => UpdateStatusNote.availableSemantics,
      _Shown.closing => UpdateStatusNote.closingSemantics,
      _Shown.updating => UpdateStatusNote.updatingLabel,
      _Shown.updated => UpdateStatusNote.updatedSemantics,
    };
    final glyph = switch (shown) {
      _Shown.available => Center(
        key: UpdateStatusNote.dotKey,
        child: Container(
          width: box / 2,
          height: box / 2,
          decoration: BoxDecoration(shape: BoxShape.circle, color: ink),
        ),
      ),
      _Shown.closing || _Shown.updating => _LevelBars(
        key: UpdateStatusNote.barsKey,
        size: box,
        color: ink,
      ),
      _Shown.updated => Icon(
        CupertinoIcons.checkmark,
        key: UpdateStatusNote.checkKey,
        size: box,
        color: ink,
      ),
    };
    final available = shown == _Shown.available;
    final line = widget.lineHeight;

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSwitcher(
          duration: UpdateStatusNote.swapFor,
          switchInCurve: _fadeThrough,
          switchOutCurve: _fadeThrough,
          // The word's right edge stays put beside the pinned glyph.
          layoutBuilder: (current, previous) => Stack(
            alignment: AlignmentDirectional.centerEnd,
            children: [...previous, ?current],
          ),
          child: Text(
            label,
            key: ValueKey(label),
            maxLines: 1,
            softWrap: false,
            textScaler: UpdateStatusNote.labelScaler(context),
            style: UpdateStatusNote.labelStyle(context).copyWith(color: ink),
          ),
        ),
        const SizedBox(width: UpdateStatusNote.gap),
        SizedBox.square(
          dimension: box,
          child: AnimatedSwitcher(
            duration: UpdateStatusNote.swapFor,
            switchInCurve: _fadeThrough,
            switchOutCurve: _fadeThrough,
            child: KeyedSubtree(key: ValueKey(shown), child: glyph),
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
                  // A safety net only: on its own line the note always fits
                  // at real text sizes, and it never wraps or truncates.
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

/// Three level bars rising and falling a third apart, as the composer's voice
/// meter does, in plain ink. Still at their resting heights under reduced
/// motion.
class _LevelBars extends StatefulWidget {
  const _LevelBars({super.key, required this.size, required this.color});

  final double size;
  final Color color;

  @override
  State<_LevelBars> createState() => _LevelBarsState();
}

class _LevelBarsState extends State<_LevelBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: UpdateStatusNote.barsLoop,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _loop.stop();
    } else if (!_loop.isAnimating) {
      unawaited(_loop.repeat());
    }
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  /// The board's resting heights, out of a 12 pt tall meter in a 14 pt box.
  static const List<double> _rest = [7, 12, 9];

  @override
  Widget build(BuildContext context) {
    final k = widget.size / UpdateStatusNote.glyphBox;
    final still = MediaQuery.disableAnimationsOf(context);
    return Center(
      child: AnimatedBuilder(
        animation: _loop,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < _rest.length; i++) ...[
              if (i > 0) SizedBox(width: 2 * k),
              Container(
                width: 2.5 * k,
                height: _rest[i] * k * (still ? 1 : _scale(i)),
                decoration: BoxDecoration(
                  color: widget.color,
                  borderRadius: BorderRadius.circular(1.25 * k),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 0.4 → 1 → 0.4 over the loop, eased each way, each bar a third ahead.
  double _scale(int i) {
    final t = (_loop.value + i / 3) % 1;
    final rise = t < 0.5 ? t * 2 : (1 - t) * 2;
    return 0.4 + 0.6 * Curves.easeInOut.transform(rise);
  }
}
