/// Design tokens for the approved native shell
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md`).
///
/// Widgets read these through `context.tokens` rather than reaching for
/// Material's colour scheme, so the visual language stays in one place.
library;

import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;

/// One radial tint in the background gradient.
///
/// [center] is the CSS percentage pair mapped to an [Alignment] (0% → -1,
/// 50% → 0, 100% → 1, 108% → 1.16); [radiusX] and [radiusY] are fractions of
/// the painted box's width and height.
@immutable
class GlowTint {
  const GlowTint({
    required this.color,
    required this.center,
    required this.radiusX,
    required this.radiusY,
  });

  final Color color;
  final Alignment center;
  final double radiusX;
  final double radiusY;

  static GlowTint lerp(GlowTint a, GlowTint b, double t) => GlowTint(
    color: Color.lerp(a.color, b.color, t)!,
    center: Alignment.lerp(a.center, b.center, t)!,
    radiusX: lerpDouble(a.radiusX, b.radiusX, t)!,
    radiusY: lerpDouble(a.radiusY, b.radiusY, t)!,
  );

  @override
  bool operator ==(Object other) =>
      other is GlowTint &&
      other.color == color &&
      other.center == center &&
      other.radiusX == radiusX &&
      other.radiusY == radiusY;

  @override
  int get hashCode => Object.hash(color, center, radiusX, radiusY);
}

/// Shape and size constants. Fixed geometry, so they never interpolate.
abstract final class MixtapeMetrics {
  // Radii.
  static const double tileRadius = 3;
  static const double tapeRadiusTop = 6;
  static const double tapeRadiusBottom = 10;
  static const double composerRadiusTop = 12;
  static const double composerRadiusBottom = 16;
  static const double pillRadius = 999;
  static const double groupRadius = 22;

  // Targets and control heights.
  static const double minTarget = 44;
  static const double tapeButtonHeight = 40;
  static const double chipHeight = 36;
  static const double composerHeight = 48;
  static const double pillHeight = 34;

  // Dock.
  static const double miniPlayerHeight = 52;
  static const double miniArt = 38;
  static const double tabBarHeight = 56;
  static const double tabIcon = 22;
  static const double dockSideMargin = 22;
  static const double dockGap = 7;

  // Page layout.
  static const double largeTitleTopPadding = 30;
  static const double screenSidePadding = 20;
}

/// The approved colour and type tokens, carried on [ThemeData.extensions].
@immutable
class MixtapeTokens extends ThemeExtension<MixtapeTokens> {
  const MixtapeTokens({
    required this.text,
    required this.plum,
    required this.smoke,
    required this.muted,
    required this.hairline,
    required this.tapeFill,
    required this.tapeEdge,
    required this.tapeShadow,
    required this.tapeInk,
    required this.prism,
    required this.glass,
    required this.glassHighlight,
    required this.panel,
    required this.field,
    required this.glassShadow,
    required this.scrimBase,
    required this.okInk,
    required this.warnInk,
    required this.errInk,
    required this.gradientTop,
    required this.gradientMid,
    required this.gradientBottom,
    required this.violetGlow,
    required this.pinkGlow,
    required this.blueGlow,
    required this.largeTitle,
    required this.smallTitle,
    required this.section,
    required this.rowTitle,
    required this.body,
    required this.secondary,
    required this.meta,
    required this.label,
    required this.wordmark,
  });

  // Ink.
  final Color text;

  /// Accent and interactive ink.
  final Color plum;
  final Color smoke;
  final Color muted;
  final Color hairline;

  // Tape button.
  final Color tapeFill;
  final Color tapeEdge;
  final Color tapeShadow;
  final Color tapeInk;

  /// The cassette prism, in order. The one decorative motif.
  final List<Color> prism;

  // Glass and panels.
  final Color glass;
  final Color glassHighlight;
  final Color panel;
  final Color field;

  /// Drop shadow under floating glass (dock, clusters).
  final Color glassShadow;

  /// Opaque ground the collapsing title bar's fade resolves to.
  final Color scrimBase;

  // Status ink — a coloured word, never a box.
  final Color okInk;
  final Color warnInk;
  final Color errInk;

  // Background gradient, top → bottom at 0% / 45% / 100%.
  final Color gradientTop;
  final Color gradientMid;
  final Color gradientBottom;

  // Glow tints painted over the base fall (the widget lands in task 1.2).
  final GlowTint violetGlow;
  final GlowTint pinkGlow;
  final GlowTint blueGlow;

  // Type. System font only, so iOS renders SF.
  final TextStyle largeTitle;
  final TextStyle smallTitle;
  final TextStyle section;
  final TextStyle rowTitle;
  final TextStyle body;
  final TextStyle secondary;

  /// The 12 pt floor; nothing smaller except [label].
  final TextStyle meta;
  final TextStyle label;

  /// The product name in the web welcome page's handwritten marker.
  ///
  /// The one departure from SF, and only for the wordmark and the "last used"
  /// pencil note under the remembered sign-in method
  /// (`docs/decisions.md` → 2026-09-18). Noteworthy is an Apple system face,
  /// so no font asset ships; it is deliberately absent from [textStyles],
  /// which is the SF-only scale.
  final TextStyle wordmark;

  /// Every exposed style, for scale assertions and gallery screens.
  List<TextStyle> get textStyles => [
    largeTitle,
    smallTitle,
    section,
    rowTitle,
    body,
    secondary,
    meta,
    label,
  ];

  /// The base vertical fall behind every screen.
  LinearGradient get backgroundGradient => LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [gradientTop, gradientMid, gradientBottom],
    stops: const [0.0, 0.45, 1.0],
  );

  /// The full six-stop prism, top-left → bottom-right by default.
  LinearGradient prismGradient({
    Alignment begin = Alignment.topLeft,
    Alignment end = Alignment.bottomRight,
  }) =>
      LinearGradient(begin: begin, end: end, colors: prism, stops: prismStops);

  /// The board's uneven prism spacing.
  static const List<double> prismStops = [0, 0.22, 0.42, 0.62, 0.82, 1];

  /// The first five prism stops, top → bottom (composer stripe, scrubber).
  LinearGradient get prismVertical => LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: prism.take(5).toList(growable: false),
  );

  static const List<Color> _prism = [
    Color(0xFFC9687F),
    Color(0xFFD18A65),
    Color(0xFFD2C76F),
    Color(0xFF709778),
    Color(0xFF688FA8),
    Color(0xFF6E5C8F),
  ];

  /// The web's `.auth-wordmark`: `italic 500 28px var(--marker)` at
  /// `letter-spacing: -0.045em`, scaled to 34 pt for the phone.
  ///
  /// Noteworthy ships Light and Bold faces only, so the browser's weight 500
  /// resolves to Light — [FontWeight.w300] is what the web actually draws.
  /// Nothing is bundled: Noteworthy is an Apple system font, and the fallbacks
  /// carry the other platforms.
  static const TextStyle _lightWordmark = TextStyle(
    fontFamily: 'Noteworthy',
    fontFamilyFallback: ['Bradley Hand', 'cursive'],
    fontSize: 34,
    fontWeight: FontWeight.w300,
    fontStyle: FontStyle.italic,
    letterSpacing: -1.53,
    height: 1.2,
    color: Color(0xFF42515E),
  );

  /// The same hand, in a slate light enough for the dark gradient.
  static const TextStyle _darkWordmark = TextStyle(
    fontFamily: 'Noteworthy',
    fontFamilyFallback: ['Bradley Hand', 'cursive'],
    fontSize: 34,
    fontWeight: FontWeight.w300,
    fontStyle: FontStyle.italic,
    letterSpacing: -1.53,
    height: 1.2,
    color: Color(0xFFD5DFE7),
  );

  static const Color _lightText = Color(0xFF1C1A1E);
  static const Color _lightSmoke = Color(0xFF696269);
  static const Color _lightMuted = Color(0xFF857E86);

  static const Color _darkText = Color(0xFFF2EEF1);
  static const Color _darkSmoke = Color(0xFFB0A9B1);
  static const Color _darkMuted = Color(0xFF98929A);

  static const MixtapeTokens light = MixtapeTokens(
    text: _lightText,
    plum: Color(0xFF544451),
    smoke: _lightSmoke,
    muted: _lightMuted,
    hairline: Color.fromRGBO(50, 44, 50, 0.14),
    tapeFill: Color(0xFF4D404B),
    tapeEdge: Color(0xFF3B3039),
    tapeShadow: Color(0xFF2D272E),
    tapeInk: Color(0xFFF5F0F2),
    prism: _prism,
    glass: Color.fromRGBO(255, 255, 255, 0.62),
    glassHighlight: Color.fromRGBO(255, 255, 255, 0.90),
    panel: Color.fromRGBO(255, 255, 255, 0.55),
    field: Color.fromRGBO(255, 255, 255, 0.75),
    glassShadow: Color.fromRGBO(30, 24, 30, 0.16),
    scrimBase: Color.fromRGBO(248, 246, 243, 1),
    okInk: Color(0xFF1F543A),
    warnInk: Color(0xFF7A4D12),
    errInk: Color(0xFF7E2F46),
    gradientTop: Color(0xFFF9F7F4),
    gradientMid: Color(0xFFF1EEEE),
    gradientBottom: Color(0xFFE6E0EA),
    violetGlow: GlowTint(
      color: Color.fromRGBO(110, 92, 143, 0.55),
      center: Alignment(0, 1.16),
      radiusX: 0.9,
      radiusY: 0.45,
    ),
    pinkGlow: GlowTint(
      color: Color.fromRGBO(201, 104, 127, 0.28),
      center: Alignment(-1, 0.84),
      radiusX: 0.6,
      radiusY: 0.35,
    ),
    blueGlow: GlowTint(
      color: Color.fromRGBO(104, 143, 168, 0.32),
      center: Alignment(1, 0.6),
      radiusX: 0.6,
      radiusY: 0.35,
    ),
    largeTitle: TextStyle(
      fontSize: 34,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.68,
      height: 1.05,
      color: _lightText,
    ),
    smallTitle: TextStyle(
      fontSize: 17,
      fontWeight: FontWeight.w600,
      height: 1.2,
      color: _lightText,
    ),
    section: TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
      color: _lightText,
    ),
    rowTitle: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w500,
      height: 1.3,
      color: _lightText,
    ),
    body: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w400,
      height: 1.4,
      color: _lightText,
    ),
    secondary: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      height: 1.4,
      color: _lightSmoke,
    ),
    meta: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w400,
      color: _lightMuted,
    ),
    label: TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w600,
      color: _lightText,
    ),
    wordmark: _lightWordmark,
  );

  static const MixtapeTokens dark = MixtapeTokens(
    text: _darkText,
    plum: Color(0xFFF0EBEF),
    smoke: _darkSmoke,
    muted: _darkMuted,
    hairline: Color.fromRGBO(255, 255, 255, 0.13),
    tapeFill: Color(0xFF5A4957),
    tapeEdge: Color(0xFF3B3039),
    tapeShadow: Color(0xFF17131A),
    tapeInk: Color(0xFFF5F0F2),
    prism: _prism,
    glass: Color.fromRGBO(60, 56, 66, 0.50),
    glassHighlight: Color.fromRGBO(255, 255, 255, 0.20),
    panel: Color.fromRGBO(40, 36, 54, 0.55),
    field: Color.fromRGBO(255, 255, 255, 0.10),
    glassShadow: Color.fromRGBO(0, 0, 0, 0.5),
    scrimBase: Color.fromRGBO(8, 8, 12, 1),
    okInk: Color(0xFFA7C7AE),
    warnInk: Color(0xFFE6C98F),
    errInk: Color(0xFFEFB2C0),
    gradientTop: Color(0xFF050507),
    gradientMid: Color(0xFF0C0B12),
    gradientBottom: Color(0xFF1A1530),
    violetGlow: GlowTint(
      color: Color.fromRGBO(96, 78, 170, 0.85),
      center: Alignment(0, 1.16),
      radiusX: 0.9,
      radiusY: 0.45,
    ),
    pinkGlow: GlowTint(
      color: Color.fromRGBO(201, 104, 127, 0.35),
      center: Alignment(-1, 0.76),
      radiusX: 0.6,
      radiusY: 0.35,
    ),
    blueGlow: GlowTint(
      color: Color.fromRGBO(80, 120, 170, 0.40),
      center: Alignment(1, 0.56),
      radiusX: 0.6,
      radiusY: 0.35,
    ),
    largeTitle: TextStyle(
      fontSize: 34,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.68,
      height: 1.05,
      color: _darkText,
    ),
    smallTitle: TextStyle(
      fontSize: 17,
      fontWeight: FontWeight.w600,
      height: 1.2,
      color: _darkText,
    ),
    section: TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
      color: _darkText,
    ),
    rowTitle: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w500,
      height: 1.3,
      color: _darkText,
    ),
    body: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w400,
      height: 1.4,
      color: _darkText,
    ),
    secondary: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w400,
      height: 1.4,
      color: _darkSmoke,
    ),
    meta: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w400,
      color: _darkMuted,
    ),
    label: TextStyle(
      fontSize: 10,
      fontWeight: FontWeight.w600,
      color: _darkText,
    ),
    wordmark: _darkWordmark,
  );

  @override
  MixtapeTokens copyWith({
    Color? text,
    Color? plum,
    Color? smoke,
    Color? muted,
    Color? hairline,
    Color? tapeFill,
    Color? tapeEdge,
    Color? tapeShadow,
    Color? tapeInk,
    List<Color>? prism,
    Color? glass,
    Color? glassHighlight,
    Color? panel,
    Color? field,
    Color? glassShadow,
    Color? scrimBase,
    Color? okInk,
    Color? warnInk,
    Color? errInk,
    Color? gradientTop,
    Color? gradientMid,
    Color? gradientBottom,
    GlowTint? violetGlow,
    GlowTint? pinkGlow,
    GlowTint? blueGlow,
    TextStyle? largeTitle,
    TextStyle? smallTitle,
    TextStyle? section,
    TextStyle? rowTitle,
    TextStyle? body,
    TextStyle? secondary,
    TextStyle? meta,
    TextStyle? label,
    TextStyle? wordmark,
  }) => MixtapeTokens(
    text: text ?? this.text,
    plum: plum ?? this.plum,
    smoke: smoke ?? this.smoke,
    muted: muted ?? this.muted,
    hairline: hairline ?? this.hairline,
    tapeFill: tapeFill ?? this.tapeFill,
    tapeEdge: tapeEdge ?? this.tapeEdge,
    tapeShadow: tapeShadow ?? this.tapeShadow,
    tapeInk: tapeInk ?? this.tapeInk,
    prism: prism ?? this.prism,
    glass: glass ?? this.glass,
    glassHighlight: glassHighlight ?? this.glassHighlight,
    panel: panel ?? this.panel,
    field: field ?? this.field,
    glassShadow: glassShadow ?? this.glassShadow,
    scrimBase: scrimBase ?? this.scrimBase,
    okInk: okInk ?? this.okInk,
    warnInk: warnInk ?? this.warnInk,
    errInk: errInk ?? this.errInk,
    gradientTop: gradientTop ?? this.gradientTop,
    gradientMid: gradientMid ?? this.gradientMid,
    gradientBottom: gradientBottom ?? this.gradientBottom,
    violetGlow: violetGlow ?? this.violetGlow,
    pinkGlow: pinkGlow ?? this.pinkGlow,
    blueGlow: blueGlow ?? this.blueGlow,
    largeTitle: largeTitle ?? this.largeTitle,
    smallTitle: smallTitle ?? this.smallTitle,
    section: section ?? this.section,
    rowTitle: rowTitle ?? this.rowTitle,
    body: body ?? this.body,
    secondary: secondary ?? this.secondary,
    meta: meta ?? this.meta,
    label: label ?? this.label,
    wordmark: wordmark ?? this.wordmark,
  );

  @override
  MixtapeTokens lerp(ThemeExtension<MixtapeTokens>? other, double t) {
    if (other is! MixtapeTokens) return this;
    return MixtapeTokens(
      text: Color.lerp(text, other.text, t)!,
      plum: Color.lerp(plum, other.plum, t)!,
      smoke: Color.lerp(smoke, other.smoke, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      tapeFill: Color.lerp(tapeFill, other.tapeFill, t)!,
      tapeEdge: Color.lerp(tapeEdge, other.tapeEdge, t)!,
      tapeShadow: Color.lerp(tapeShadow, other.tapeShadow, t)!,
      tapeInk: Color.lerp(tapeInk, other.tapeInk, t)!,
      prism: [
        for (var i = 0; i < prism.length; i++)
          Color.lerp(prism[i], other.prism[i], t)!,
      ],
      glass: Color.lerp(glass, other.glass, t)!,
      glassHighlight: Color.lerp(glassHighlight, other.glassHighlight, t)!,
      panel: Color.lerp(panel, other.panel, t)!,
      field: Color.lerp(field, other.field, t)!,
      glassShadow: Color.lerp(glassShadow, other.glassShadow, t)!,
      scrimBase: Color.lerp(scrimBase, other.scrimBase, t)!,
      okInk: Color.lerp(okInk, other.okInk, t)!,
      warnInk: Color.lerp(warnInk, other.warnInk, t)!,
      errInk: Color.lerp(errInk, other.errInk, t)!,
      gradientTop: Color.lerp(gradientTop, other.gradientTop, t)!,
      gradientMid: Color.lerp(gradientMid, other.gradientMid, t)!,
      gradientBottom: Color.lerp(gradientBottom, other.gradientBottom, t)!,
      violetGlow: GlowTint.lerp(violetGlow, other.violetGlow, t),
      pinkGlow: GlowTint.lerp(pinkGlow, other.pinkGlow, t),
      blueGlow: GlowTint.lerp(blueGlow, other.blueGlow, t),
      largeTitle: TextStyle.lerp(largeTitle, other.largeTitle, t)!,
      smallTitle: TextStyle.lerp(smallTitle, other.smallTitle, t)!,
      section: TextStyle.lerp(section, other.section, t)!,
      rowTitle: TextStyle.lerp(rowTitle, other.rowTitle, t)!,
      body: TextStyle.lerp(body, other.body, t)!,
      secondary: TextStyle.lerp(secondary, other.secondary, t)!,
      meta: TextStyle.lerp(meta, other.meta, t)!,
      label: TextStyle.lerp(label, other.label, t)!,
      wordmark: TextStyle.lerp(wordmark, other.wordmark, t)!,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MixtapeTokens &&
      other.text == text &&
      other.plum == plum &&
      other.smoke == smoke &&
      other.muted == muted &&
      other.hairline == hairline &&
      other.tapeFill == tapeFill &&
      other.tapeEdge == tapeEdge &&
      other.tapeShadow == tapeShadow &&
      other.tapeInk == tapeInk &&
      listEquals(other.prism, prism) &&
      other.glass == glass &&
      other.glassHighlight == glassHighlight &&
      other.panel == panel &&
      other.field == field &&
      other.glassShadow == glassShadow &&
      other.scrimBase == scrimBase &&
      other.okInk == okInk &&
      other.warnInk == warnInk &&
      other.errInk == errInk &&
      other.gradientTop == gradientTop &&
      other.gradientMid == gradientMid &&
      other.gradientBottom == gradientBottom &&
      other.violetGlow == violetGlow &&
      other.pinkGlow == pinkGlow &&
      other.blueGlow == blueGlow &&
      other.largeTitle == largeTitle &&
      other.smallTitle == smallTitle &&
      other.section == section &&
      other.rowTitle == rowTitle &&
      other.body == body &&
      other.secondary == secondary &&
      other.meta == meta &&
      other.label == label &&
      other.wordmark == wordmark;

  @override
  int get hashCode => Object.hashAll([
    text,
    plum,
    smoke,
    muted,
    hairline,
    tapeFill,
    tapeEdge,
    tapeShadow,
    tapeInk,
    ...prism,
    glass,
    glassHighlight,
    panel,
    field,
    glassShadow,
    scrimBase,
    okInk,
    warnInk,
    errInk,
    gradientTop,
    gradientMid,
    gradientBottom,
    violetGlow,
    pinkGlow,
    blueGlow,
    largeTitle,
    smallTitle,
    section,
    rowTitle,
    body,
    secondary,
    meta,
    label,
    wordmark,
  ]);
}

/// Reads the design tokens off the ambient theme.
extension MixtapeTokensX on BuildContext {
  MixtapeTokens get tokens {
    final tokens = Theme.of(this).extension<MixtapeTokens>();
    assert(
      tokens != null,
      'No MixtapeTokens on the ambient theme. Build the theme with '
      'MixtapeTheme.light() or MixtapeTheme.dark() instead of a bare '
      'ThemeData, or attach MixtapeTokens to ThemeData.extensions.',
    );
    return tokens!;
  }
}

/// Builds the app themes from [MixtapeTokens].
///
/// Material components are kept quiet — no elevation tints, no surface tint —
/// because the gradient (task 1.2) paints behind everything.
abstract final class MixtapeTheme {
  static ThemeData light() => _build(Brightness.light, MixtapeTokens.light);

  static ThemeData dark() => _build(Brightness.dark, MixtapeTokens.dark);

  /// Ink on a light role colour — dark mode's primary, secondary and error
  /// are all light, so their `on` colours cannot be [MixtapeTokens.tapeInk].
  static const Color _onLightRole = Color(0xFF1C1A1E);

  static ThemeData _build(Brightness brightness, MixtapeTokens t) {
    final isDark = brightness == Brightness.dark;
    final onRole = isDark ? _onLightRole : t.tapeInk;
    final primaryContainer = isDark
        ? const Color(0xFF2A2533)
        : const Color(0xFFEAE3E9);
    final secondaryContainer = isDark
        ? const Color(0xFF26242E)
        : const Color(0xFFE9E6E9);
    final errorContainer = isDark
        ? const Color(0xFF3A2230)
        : const Color(0xFFF4E3E8);
    final onContainer = isDark ? t.text : _onLightRole;

    final scheme = ColorScheme(
      brightness: brightness,
      primary: t.plum,
      onPrimary: onRole,
      primaryContainer: primaryContainer,
      onPrimaryContainer: onContainer,
      secondary: t.smoke,
      onSecondary: onRole,
      secondaryContainer: secondaryContainer,
      onSecondaryContainer: onContainer,
      error: t.errInk,
      onError: onRole,
      errorContainer: errorContainer,
      onErrorContainer: onContainer,
      surface: t.gradientTop,
      onSurface: t.text,
      onSurfaceVariant: t.smoke,
      outline: t.muted,
      outlineVariant: t.hairline,
      surfaceTint: Colors.transparent,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: Colors.transparent,
      canvasColor: Colors.transparent,
      dividerColor: t.hairline,
      extensions: [t],
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        foregroundColor: t.text,
        titleTextStyle: t.smallTitle,
        // Status bar glyphs follow the theme, not the (transparent) app bar.
        systemOverlayStyle: brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
      ),
      cardTheme: const CardThemeData(
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      dialogTheme: const DialogThemeData(
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      dividerTheme: DividerThemeData(color: t.hairline),
      textTheme: TextTheme(
        headlineMedium: t.largeTitle,
        titleLarge: t.section,
        titleMedium: t.rowTitle,
        bodyLarge: t.body,
        bodyMedium: t.body,
        bodySmall: t.secondary,
        labelSmall: t.label,
      ),
    );
  }
}
