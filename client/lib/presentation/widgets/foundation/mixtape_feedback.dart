import 'package:flutter/material.dart';
import '../../theme/mixtape_theme.dart';
import 'prism_stripe.dart';

enum FeedbackKind { success, error, info }

/// Keeps actions inside the feedback band, with assistive text allowed to grow.
SnackBar mixtapeSnackBar({
  required String message,
  FeedbackKind kind = FeedbackKind.info,
  String? actionLabel,
  VoidCallback? onAction,
  Duration duration = const Duration(seconds: 4),
}) {
  var used = false;
  return SnackBar(
    duration:
        onAction != null &&
            WidgetsBinding
                .instance
                .platformDispatcher
                .accessibilityFeatures
                .accessibleNavigation
        ? const Duration(days: 1)
        : duration,
    behavior: SnackBarBehavior.floating,
    backgroundColor: Colors.transparent,
    elevation: 0,
    padding: EdgeInsets.zero,
    // Keep action feedback available under assistive navigation. The visual
    // action lives in content so adding Undo cannot change its layout.
    content: MixtapeFeedback(
      message: message,
      kind: kind,
      actionLabel: actionLabel,
      onAction: onAction == null
          ? null
          : () {
              if (used) return;
              used = true;
              onAction();
            },
    ),
  );
}

class MixtapeFeedback extends StatelessWidget {
  const MixtapeFeedback({
    super.key,
    required this.message,
    this.kind = FeedbackKind.info,
    this.actionLabel,
    this.onAction,
  });
  final String message;
  final FeedbackKind kind;
  final String? actionLabel;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) {
    final tokens =
        Theme.of(context).extension<MixtapeTokens>() ?? MixtapeTokens.light;
    final ink = kind == FeedbackKind.error
        ? tokens.errInk
        : kind == FeedbackKind.success
        ? tokens.okInk
        : const Color(0xFF617F9C);
    final scale = MediaQuery.textScalerOf(context).scale(12) / 12;
    return Align(
      alignment: Alignment.center,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: IntrinsicWidth(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(11),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border.all(color: tokens.hairline),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: scale > 1.3 ? 85 : 41,
                      maxHeight: scale > 1.3 ? double.infinity : 41,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CustomPaint(
                            size: const Size(22, 22),
                            painter: FeedbackGlyphPainter(kind, ink),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Semantics(
                              liveRegion: true,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 4,
                                ),
                                child: Text(
                                  message,
                                  maxLines: scale > 1.3 ? null : 2,
                                  overflow: scale > 1.3
                                      ? null
                                      : TextOverflow.ellipsis,
                                  style: tokens.meta.copyWith(
                                    fontSize: 12,
                                    height: 1.3,
                                    color: tokens.text,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (actionLabel != null && onAction != null)
                            TextButton(
                              style: TextButton.styleFrom(
                                minimumSize: const Size(44, 41),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () {
                                ScaffoldMessenger.maybeOf(
                                  context,
                                )?.hideCurrentSnackBar();
                                onAction!();
                              },
                              child: Text(
                                actionLabel!,
                                maxLines: 1,
                                softWrap: false,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: tokens.text,
                                  decoration: TextDecoration.none,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const PrismStripe(
                    height: 3,
                    width: double.infinity,
                    horizontal: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The approved split chamfered frames, in their original 24-unit geometry.
class FeedbackGlyphPainter extends CustomPainter {
  const FeedbackGlyphPainter(this.kind, this.color);
  final FeedbackKind kind;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final fill = Paint()..color = color;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final frame = Path()
      ..moveTo(8, 3)
      ..lineTo(16, 3)
      ..lineTo(21, 8)
      ..lineTo(21, 16)
      ..lineTo(16, 21)
      ..lineTo(8, 21)
      ..lineTo(3, 16)
      ..lineTo(3, 8)
      ..close();
    canvas.drawPath(frame, Paint()..color = color.withValues(alpha: .13));
    if (kind == FeedbackKind.success) {
      canvas.drawPath(
        Path()
          ..moveTo(13, 3)
          ..lineTo(8, 3)
          ..lineTo(3, 8)
          ..lineTo(3, 16)
          ..lineTo(8, 21)
          ..lineTo(16, 21)
          ..lineTo(21, 16)
          ..lineTo(21, 13),
        stroke,
      );
      canvas.drawPath(
        Path()
          ..moveTo(7.5, 11.5)
          ..lineTo(11.5, 15.5)
          ..lineTo(21, 5),
        stroke..strokeWidth = 2.5,
      );
    } else {
      canvas.drawPath(
        Path()
          ..moveTo(10, 3)
          ..lineTo(8, 3)
          ..lineTo(3, 8)
          ..lineTo(3, 16)
          ..lineTo(8, 21)
          ..lineTo(10, 21)
          ..moveTo(14, 3)
          ..lineTo(16, 3)
          ..lineTo(21, 8)
          ..lineTo(21, 16)
          ..lineTo(16, 21)
          ..lineTo(14, 21),
        stroke,
      );
      if (kind == FeedbackKind.error) {
        canvas.drawPath(
          Path()
            ..moveTo(10.6, 6.8)
            ..lineTo(13.4, 6.8)
            ..lineTo(12.8, 14)
            ..lineTo(11.2, 14)
            ..close(),
          fill,
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(10.7, 16, 2.6, 2.6),
            const Radius.circular(.6),
          ),
          fill,
        );
      } else {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            const Rect.fromLTWH(10.8, 6.4, 2.4, 2.4),
            const Radius.circular(.7),
          ),
          fill,
        );
        canvas.drawPath(
          Path()
            ..moveTo(10, 11)
            ..lineTo(12, 11)
            ..lineTo(12, 17)
            ..moveTo(10, 17)
            ..lineTo(14, 17),
          stroke..strokeWidth = 2,
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(FeedbackGlyphPainter oldDelegate) =>
      oldDelegate.kind != kind || oldDelegate.color != color;
}
