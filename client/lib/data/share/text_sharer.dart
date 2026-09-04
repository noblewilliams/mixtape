// The system share sheet behind "Send to a transfer tool" (plan: Outputs).
// Wrapped so the queue screen's tests hand text to a fake instead of the
// share_plus platform channel.
import 'dart:ui';

import 'package:share_plus/share_plus.dart';

abstract class TextSharer {
  /// Offers [text] to the share sheet under [subject]. Resolves true once
  /// the listener picked a destination (or the platform cannot say which),
  /// false when they dismissed the sheet without one.
  ///
  /// [origin] is the rect, in global (logical) coordinates, the sheet points
  /// at: on iPad it is a popover, and UIKit needs a source rect or it throws.
  /// The caller passes the button the listener actually tapped.
  Future<bool> share(String text, {required String subject, required Rect origin});
}

class SharePlusTextSharer implements TextSharer {
  const SharePlusTextSharer();

  @override
  Future<bool> share(String text, {required String subject, required Rect origin}) async {
    final result = await SharePlus.instance.share(
      ShareParams(text: text, subject: subject, sharePositionOrigin: origin),
    );
    return result.status != ShareResultStatus.dismissed;
  }
}
