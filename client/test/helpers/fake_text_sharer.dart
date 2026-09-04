import 'package:mixtape/data/share/text_sharer.dart';

/// Records what a screen handed to the share sheet instead of opening one.
/// [handedOff] is what the sheet reports back: false plays a dismissal.
class FakeTextSharer implements TextSharer {
  bool handedOff = true;
  final List<({String text, String subject})> shares = [];

  @override
  Future<bool> share(String text, {required String subject}) async {
    shares.add((text: text, subject: subject));
    return handedOff;
  }
}
