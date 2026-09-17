import 'package:flutter/material.dart';

import '../../theme/mixtape_theme.dart';

/// The board's square motif: artwork at a 3 pt radius, or a quiet gradient
/// placeholder when there is no picture yet.
///
/// `docs/mockups/2026-09-17-mobile-shell-r3.html` → `.row .art`.
class SquareArt extends StatelessWidget {
  const SquareArt({
    super.key,
    this.url,
    this.placeholder,
    this.placeholderGradient,
    this.size = 60,
    this.radius = MixtapeMetrics.tileRadius,
    this.child,
  });

  /// Only https artwork is loaded; anything else falls back to the placeholder.
  final String? url;

  /// A flat placeholder colour, used when [placeholderGradient] is absent.
  final Color? placeholder;

  /// Two colours painted top-left → bottom-right.
  final List<Color>? placeholderGradient;

  final double size;

  /// The square motif is 3 pt everywhere; screens still carrying older radii
  /// pass their own until they are restyled.
  final double radius;

  /// Centred over the artwork or placeholder (a cassette, a glyph, initials).
  final Widget? child;

  /// The board's empty-art box: light `#E8E4E6`, dark white at 8%.
  static Color boxColorFor(Brightness brightness) =>
      brightness == Brightness.dark
      ? const Color.fromRGBO(255, 255, 255, 0.08)
      : const Color(0xFFE8E4E6);

  bool get _hasNetworkArtwork {
    final value = url;
    if (value == null || value.isEmpty) return false;
    return Uri.tryParse(value)?.scheme == 'https';
  }

  @override
  Widget build(BuildContext context) {
    final gradient = placeholderGradient;
    final fill = placeholder ?? boxColorFor(Theme.of(context).brightness);
    // The child belongs to the placeholder: artwork, once it loads, covers it.
    Widget layer = DecoratedBox(
      decoration: BoxDecoration(
        color: gradient == null ? fill : null,
        gradient: gradient == null
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: gradient,
              ),
      ),
      child: SizedBox.expand(
        child: child == null ? null : Center(child: child),
      ),
    );

    if (_hasNetworkArtwork) {
      layer = Stack(
        fit: StackFit.expand,
        children: [
          layer,
          Image.network(
            url!,
            fit: BoxFit.cover,
            frameBuilder: (_, image, frame, wasSynchronouslyLoaded) {
              if (wasSynchronouslyLoaded) return image;
              return AnimatedOpacity(
                opacity: frame == null ? 0 : 1,
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                child: image,
              );
            },
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        ],
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(dimension: size, child: layer),
    );
  }
}
