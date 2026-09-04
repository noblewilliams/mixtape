import 'dart:ui';

import 'package:mixtape/data/share/text_sharer.dart';

/// Records what a screen handed to the share sheet instead of opening one.
/// [handedOff] is what the sheet reports back: false plays a dismissal.
/// [origin] is the iPad popover anchor the screen computed.
class FakeTextSharer implements TextSharer {
  bool handedOff = true;
  final List<({String text, String subject, Rect origin})> shares = [];

  @override
  Future<bool> share(String text, {required String subject, required Rect origin}) async {
    shares.add((text: text, subject: subject, origin: origin));
    return handedOff;
  }
}
