import 'package:flutter/material.dart';

const tapePalette = <(String, String)>[
  ('Rose', '#d88c9a'),
  ('Cherry', '#b84755'),
  ('Crimson', '#a32440'),
  ('Wine', '#762d44'),
  ('Coral', '#e77b6d'),
  ('Blush', '#e8b1b5'),
  ('Apricot', '#e7a269'),
  ('Tangerine', '#e98135'),
  ('Rust', '#bc5734'),
  ('Terracotta', '#a9624f'),
  ('Peach', '#efbd91'),
  ('Copper', '#b97948'),
  ('Butter', '#ead687'),
  ('Marigold', '#e6b52e'),
  ('Ochre', '#bc8c29'),
  ('Mustard', '#a89031'),
  ('Sand', '#c8b080'),
  ('Champagne', '#ddcba3'),
  ('Pistachio', '#aaba83'),
  ('Lime', '#93b53e'),
  ('Olive', '#7f883c'),
  ('Moss', '#627445'),
  ('Sage', '#8aab91'),
  ('Forest', '#33654c'),
  ('Mint', '#88c9b3'),
  ('Seafoam', '#5dab9c'),
  ('Teal', '#268b83'),
  ('Petrol', '#27626d'),
  ('Aqua', '#70bfcb'),
  ('Ice', '#accdd7'),
  ('Sky', '#87b5df'),
  ('Blue', '#477fbd'),
  ('Cobalt', '#3257ae'),
  ('Navy', '#293e6c'),
  ('Denim', '#617f9c'),
  ('Slate', '#536674'),
  ('Lilac', '#b5a0d6'),
  ('Violet', '#9564b1'),
  ('Plum', '#704674'),
  ('Orchid', '#c77fbd'),
  ('Pink', '#d786ae'),
  ('Lavender', '#c9bddb'),
  ('Cream', '#ddd5c2'),
  ('Stone', '#a6a398'),
  ('Taupe', '#948373'),
  ('Cocoa', '#715547'),
  ('Graphite', '#49464e'),
  ('Ink', '#282a35'),
];

Color? tapeColor(String? hex) {
  if (hex == null || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)) return null;
  return Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));
}

/// The palette's eight families, in palette order: six colours each. The
/// tape settings sheet picks a family first, then one of its cassettes.
const tapeFamilyNames = <String>[
  'Reds',
  'Oranges',
  'Yellows',
  'Greens',
  'Teals',
  'Blues',
  'Purples',
  'Neutrals',
];

/// The colours of family [index] (0–7), as `(name, '#hex')`.
List<(String, String)> tapeFamily(int index) =>
    tapePalette.skip(index * 6).take(6).toList(growable: false);

/// The family a palette colour belongs to, or null for a colour that is not
/// in the palette.
int? tapeFamilyOf(String hex) {
  final at = tapePalette.indexWhere(
    (entry) => entry.$2.toLowerCase() == hex.toLowerCase(),
  );
  return at < 0 ? null : at ~/ 6;
}

/// The swatch each family shows: the board draws its second colour (Cherry,
/// Tangerine, Marigold, Moss, Teal, Blue, Violet, Taupe), except where that
/// colour sits elsewhere in the family.
const _familySwatchIndex = <int>[1, 1, 1, 3, 2, 1, 1, 2];

String tapeFamilySwatch(int index) =>
    tapeFamily(index)[_familySwatchIndex[index]].$2;

/// The hex string for [color], `#rrggbb`.
String tapeHex(Color color) =>
    '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
