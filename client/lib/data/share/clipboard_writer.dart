// The clipboard behind "Play on Spotify": the mix's song list is copied, then
// TuneMyMusic's paste-a-list page opens to build the Spotify playlist.
// Wrapped so screen tests read what was copied instead of the platform
// clipboard.
import 'package:flutter/services.dart';

abstract class ClipboardWriter {
  Future<void> copy(String text);
}

class SystemClipboardWriter implements ClipboardWriter {
  const SystemClipboardWriter();

  @override
  Future<void> copy(String text) =>
      Clipboard.setData(ClipboardData(text: text));
}
