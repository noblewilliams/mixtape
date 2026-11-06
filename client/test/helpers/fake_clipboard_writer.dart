import 'package:mixtape/data/share/clipboard_writer.dart';

/// Records what a screen copied instead of touching the system clipboard.
class FakeClipboardWriter implements ClipboardWriter {
  final List<String> copies = [];

  @override
  Future<void> copy(String text) async => copies.add(text);
}
