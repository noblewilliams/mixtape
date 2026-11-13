/// A text field's height inside a Cupertino alert.
///
/// `CupertinoAlertDialog` sizes its content from intrinsic heights, and a
/// `CupertinoTextField` reports about 31 pt less than it draws: the alert came
/// out short and scrolled its own content for a single field (device smoke,
/// 2026-11-13). This box gives the field the height it actually takes — one
/// line of the alert's text style at the current text size, plus the field's
/// default 7 pt padding and hairline border — so the alert measures it right.
library;

import 'package:flutter/cupertino.dart';

class AlertFieldBox extends StatelessWidget {
  const AlertFieldBox({super.key, required this.child});

  /// The `CupertinoTextField`, with its default padding.
  final Widget child;

  /// `CupertinoTextField`'s default padding, top and bottom, and room for its
  /// border.
  static const double chrome = 7 * 2 + 2;

  @override
  Widget build(BuildContext context) {
    final painter = TextPainter(
      text: TextSpan(
        text: 'Ag',
        style: CupertinoTheme.of(context).textTheme.textStyle,
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final height = painter.height + chrome;
    painter.dispose();
    return SizedBox(height: height, child: child);
  }
}
