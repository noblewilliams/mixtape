import 'package:flutter/material.dart';

/// A settings-style glyph: a white symbol on a small rounded square of colour,
/// lit from the top, as the iOS Settings lists draw theirs (founder,
/// 2026-11-03: the bare outline icons on You read as basic).
///
/// Sized for an [InsetRow]'s leading slot; a group of them sets
/// `InsetGroup.dividerInset` to [rowDividerInset] so the hairlines start
/// under the titles.
class IconTile extends StatelessWidget {
  const IconTile({super.key, required this.icon, required this.color});

  final IconData icon;

  /// The tile's base hue; the top edge is drawn a little lighter.
  final Color color;

  static const double size = 30;
  static const double glyphSize = 18;
  static const double radius = 8;

  /// The row's side padding, the tile, and the gap before the title.
  static const double rowDividerInset = 16 + size + 12;

  /// The palette, kept to the app's own glow hues rather than Settings'
  /// primaries.
  static const Color plum = Color(0xFF7A5CC2);
  static const Color rose = Color(0xFFD9506F);
  static const Color amber = Color(0xFFE08A2E);
  static const Color sky = Color(0xFF3B82D6);
  static const Color slate = Color(0xFF6B7385);
  static const Color red = Color(0xFFD64545);

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: ShapeDecoration(
      shape: RoundedSuperellipseBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color.lerp(color, Colors.white, 0.18)!, color],
      ),
    ),
    child: SizedBox.square(
      dimension: size,
      child: Icon(icon, size: glyphSize, color: Colors.white),
    ),
  );
}
