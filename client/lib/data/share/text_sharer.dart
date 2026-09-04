// The system share sheet behind "Send to a transfer tool" (plan: Outputs).
// Wrapped so the queue screen's tests hand text to a fake instead of the
// share_plus platform channel.
import 'package:share_plus/share_plus.dart';

abstract class TextSharer {
  /// Offers [text] to the share sheet under [subject]. Resolves true once
  /// the listener picked a destination (or the platform cannot say which),
  /// false when they dismissed the sheet without one.
  Future<bool> share(String text, {required String subject});
}

class SharePlusTextSharer implements TextSharer {
  const SharePlusTextSharer();

  @override
  Future<bool> share(String text, {required String subject}) async {
    final result = await SharePlus.instance.share(ShareParams(text: text, subject: subject));
    return result.status != ShareResultStatus.dismissed;
  }
}
