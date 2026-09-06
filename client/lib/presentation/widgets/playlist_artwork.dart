import 'package:flutter/material.dart';

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
    final background =
        playlistArtworkColor(bgColor) ??
        Theme.of(context).colorScheme.surfaceContainerHighest;
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            background,
            Color.lerp(
              background,
              Theme.of(context).colorScheme.primary,
              0.34,
            )!,
          ],
        ),
      ),
      child: Center(
        child: Icon(
          Icons.music_note_rounded,
          color:
              ThemeData.estimateBrightnessForColor(background) ==
                  Brightness.dark
              ? Colors.white.withValues(alpha: 0.88)
              : Colors.black.withValues(alpha: 0.68),
          size: size * 0.34,
        ),
      ),
    );
    return Semantics(
      image: true,
      label: 'Playlist artwork',
      excludeSemantics: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: SizedBox.square(
          dimension: size,
          child: url == null
              ? fallback
              : Image.network(
                  url,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => fallback,
                ),
        ),
      ),
    );
  }
}
