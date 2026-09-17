import 'package:flutter/material.dart';

import 'foundation/square_art.dart';

String? playlistArtworkUrl(String? template, {int size = 320}) {
  if (template == null || template.isEmpty) return null;
  final value = template
      .replaceAll('{w}', '$size')
      .replaceAll('{h}', '$size')
      .replaceAll('{f}', 'jpg');
  final uri = Uri.tryParse(value);
  return uri != null && uri.scheme == 'https' ? value : null;
}

Color? playlistArtworkColor(String? hex) {
  if (hex == null || !RegExp(r'^[0-9a-f]{6}$').hasMatch(hex)) return null;
  return Color(int.parse('ff$hex', radix: 16));
}

class PlaylistArtwork extends StatelessWidget {
  const PlaylistArtwork({
    super.key,
    required this.urlTemplate,
    required this.bgColor,
    this.size = 72,
    this.borderRadius = 12,
  });

  final String? urlTemplate;
  final String? bgColor;
  final double size;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final url = playlistArtworkUrl(urlTemplate, size: (size * 3).round());
    final scheme = Theme.of(context).colorScheme;
    final background =
        playlistArtworkColor(bgColor) ??
        SquareArt.boxColorFor(Theme.of(context).brightness);
    final tint = Color.lerp(background, scheme.primary, 0.34)!;
    // The placeholder box is translucent, so the glyph's contrast has to be
    // judged against what it actually lands on, not the wash's own alpha.
    final onSurface = Color.alphaBlend(background, scheme.surface);
    return Semantics(
      image: true,
      label: 'Playlist artwork',
      excludeSemantics: true,
      child: SquareArt(
        url: url,
        size: size,
        radius: borderRadius,
        placeholderGradient: [background, tint],
        child: Icon(
          Icons.music_note_rounded,
          color:
              ThemeData.estimateBrightnessForColor(onSurface) == Brightness.dark
              ? Colors.white.withValues(alpha: 0.88)
              : Colors.black.withValues(alpha: 0.68),
          size: size * 0.34,
        ),
      ),
    );
  }
}
