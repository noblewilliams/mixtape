// The system share sheet behind a mix's Share (spec 2026-11-13
// shared-mixes → Sender). Wrapped so screen tests read what was shared
// instead of opening the platform sheet.
import 'dart:ui' show Rect;

import 'package:share_plus/share_plus.dart';

abstract class ShareSheet {
  /// Opens the sheet with [text] and [url]. [origin] anchors the popover on
  /// iPad; phones ignore it.
  Future<void> share({required String text, required String url, Rect? origin});
}

class SystemShareSheet implements ShareSheet {
  const SystemShareSheet();

  // share_plus takes a text or a uri, not both: the link goes on its own
  // line under the text, where Messages and the rest still find it and
  // draw the preview card.
  @override
  Future<void> share({
    required String text,
    required String url,
    Rect? origin,
  }) => SharePlus.instance.share(
    ShareParams(text: '$text\n$url', sharePositionOrigin: origin),
  );
}
