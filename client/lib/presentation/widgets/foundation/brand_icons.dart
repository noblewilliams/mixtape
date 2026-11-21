/// The two services' official icons, for the Library rows and Add your music
/// (approval `docs/mockups/2026-11-21-add-your-music-restyle-r4.html` and
/// `-r3.html`: "official icons").
///
/// Sources, kept beside the board in `docs/brand/`:
/// - Apple Music: `Apple_Music_Icon_RGB_sm_073120.svg`, from the Apple Music
///   Icon 2020 pack in Apple's Apple Music identity guidelines. The colour
///   tile, always in full colour.
/// - Spotify: `Primary_Logo_Black_RGB.svg` / `Primary_Logo_White_RGB.svg`,
///   from the Spotify 2024 icon pack (developer.spotify.com/documentation/
///   design). The monochrome icon: black on the light theme, white on the
///   dark one, because Spotify allows its green icon only on pure black or
///   white backgrounds and this app's gradient is neither.
///
/// Rules both brands set: the artwork is never tinted, greyed, recoloured,
/// cropped or redrawn. The path data and colours below are the official files'
/// own; only the Illustrator comment, an empty layer group and the `<style>`
/// classes (moved onto the elements as attributes, since the renderer does not
/// read class selectors) are gone. Spotify's icon is never drawn under 21 px.
///
/// These are pure Dart strings rendered by `flutter_svg`, not assets, so they
/// ride an over-the-air patch. The single-tone `AppleMusicMark` /
/// `SpotifyMark` in `service_marks.dart` stay for the other screens.
library;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// `Apple_Music_Icon_RGB_sm_073120.svg`, path data and colours verbatim.
const String appleMusicIconSvg = '''
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" width="73px" height="73px" viewBox="0 0 73 73">
<g>
	<linearGradient id="SVGID_1_" gradientUnits="userSpaceOnUse" x1="36" y1="2.2858" x2="36" y2="72.455" gradientTransform="matrix(1 0 0 -1 0 74.0068)">
		<stop offset="0" style="stop-color:#FA233B"/>
		<stop offset="1" style="stop-color:#FB5C74"/>
	</linearGradient>
	<path fill-rule="evenodd" clip-rule="evenodd" fill="url(#SVGID_1_)" d="M72,22.52c0-0.86,0-1.72,0-2.58c0-0.72-0.01-1.45-0.03-2.17c-0.04-1.58-0.14-3.17-0.42-4.73
		c-0.28-1.58-0.75-3.06-1.48-4.5c-0.72-1.41-1.66-2.71-2.78-3.83s-2.42-2.06-3.83-2.78c-1.44-0.73-2.91-1.2-4.49-1.48
		c-1.56-0.28-3.15-0.37-4.73-0.42C53.51,0.02,52.78,0.01,52.06,0c-0.86,0-1.72,0-2.58,0H22.52c-0.86,0-1.72,0-2.58,0
		c-0.72,0-1.45,0.01-2.17,0.03c-1.58,0.04-3.17,0.14-4.73,0.42C11.46,0.74,9.98,1.2,8.55,1.94C7.13,2.66,5.84,3.6,4.72,4.72
		S2.65,7.13,1.93,8.55c-0.73,1.44-1.2,2.91-1.48,4.5c-0.28,1.56-0.37,3.15-0.42,4.73C0.02,18.5,0.01,19.22,0,19.94
		c0,0.86,0,1.72,0,2.58v26.95c0,0.86,0,1.72,0,2.58c0,0.72,0.01,1.45,0.03,2.17c0.04,1.58,0.14,3.17,0.42,4.73
		c0.28,1.58,0.75,3.06,1.48,4.5c0.72,1.41,1.66,2.71,2.78,3.83c1.12,1.12,2.42,2.06,3.83,2.78c1.44,0.73,2.91,1.2,4.49,1.48
		c1.56,0.28,3.15,0.37,4.73,0.42c0.72,0.02,1.45,0.03,2.17,0.03c0.86,0.01,1.72,0,2.58,0h26.95c0.86,0,1.72,0,2.58,0
		c0.72,0,1.45-0.01,2.17-0.03c1.58-0.04,3.17-0.14,4.73-0.42c1.58-0.28,3.06-0.75,4.49-1.48c1.41-0.72,2.71-1.66,3.83-2.78
		c1.12-1.12,2.06-2.41,2.78-3.83c0.73-1.44,1.2-2.91,1.48-4.5c0.28-1.56,0.37-3.15,0.42-4.73c0.02-0.72,0.03-1.45,0.03-2.17
		c0.01-0.86,0-1.72,0-2.58L72,22.52L72,22.52z"/>
</g>
<g id="Glyph_2_">
	<g>
		<path fill-rule="evenodd" clip-rule="evenodd" fill="#FFFFFF" d="M50.9,11c-0.17,0.02-1.72,0.29-1.91,0.33l-21.4,4.32l-0.01,0c-0.56,0.12-1,0.32-1.33,0.6
			c-0.41,0.34-0.63,0.83-0.72,1.39c-0.02,0.12-0.05,0.36-0.05,0.72c0,0,0,21.86,0,26.78c0,0.63-0.05,1.23-0.47,1.75
			c-0.42,0.52-0.95,0.67-1.56,0.8c-0.47,0.09-0.93,0.19-1.4,0.28c-1.77,0.36-2.92,0.6-3.96,1c-1,0.39-1.74,0.88-2.34,1.5
			c-1.18,1.23-1.66,2.91-1.49,4.48c0.14,1.34,0.74,2.62,1.78,3.56c0.7,0.64,1.57,1.13,2.6,1.33c1.07,0.21,2.2,0.14,3.86-0.2
			c0.88-0.18,1.71-0.46,2.5-0.92c0.78-0.46,1.45-1.07,1.97-1.82c0.52-0.75,0.86-1.58,1.05-2.47c0.19-0.91,0.24-1.74,0.24-2.65V28.56
			c0-1.24,0.35-1.57,1.36-1.82c0,0,17.79-3.59,18.62-3.75c1.16-0.22,1.7,0.11,1.7,1.32v15.86c0,0.63-0.01,1.26-0.43,1.78
			c-0.42,0.52-0.95,0.67-1.56,0.8c-0.47,0.09-0.93,0.19-1.4,0.28c-1.77,0.36-2.92,0.6-3.96,1c-1,0.39-1.74,0.88-2.34,1.5
			c-1.18,1.23-1.7,2.91-1.53,4.48c0.14,1.34,0.78,2.62,1.82,3.56c0.7,0.64,1.57,1.11,2.6,1.32c1.07,0.21,2.2,0.14,3.86-0.2
			c0.88-0.18,1.71-0.44,2.5-0.91c0.78-0.46,1.45-1.07,1.97-1.82c0.52-0.75,0.86-1.58,1.05-2.47c0.19-0.91,0.2-1.74,0.2-2.65V12.89
			C52.71,11.66,52.06,10.9,50.9,11z"/>
	</g>
</g>
</svg>
''';

/// The Spotify icon's one path, shared by both official files.
const String _spotifyIconPath =
    'm122.37,3.31C61.99.91,11.1,47.91,8.71,108.29c-2.4,60.38,44.61,111.26,104.98,113.66,60.38,2.4,111.26-44.6,113.66-104.98C229.74,56.59,182.74,5.7,122.37,3.31Zm46.18,160.28c-1.36,2.4-4.01,3.6-6.59,3.24-.79-.11-1.58-.37-2.32-.79-14.46-8.23-30.22-13.59-46.84-15.93-16.62-2.34-33.25-1.53-49.42,2.4-3.51.85-7.04-1.3-7.89-4.81-.85-3.51,1.3-7.04,4.81-7.89,17.78-4.32,36.06-5.21,54.32-2.64,18.26,2.57,35.58,8.46,51.49,17.51,3.13,1.79,4.23,5.77,2.45,8.91Zm14.38-28.72c-2.23,4.12-7.39,5.66-11.51,3.43-16.92-9.15-35.24-15.16-54.45-17.86-19.21-2.7-38.47-1.97-57.26,2.16-1.02.22-2.03.26-3.01.12-3.41-.48-6.33-3.02-7.11-6.59-1.01-4.58,1.89-9.11,6.47-10.12,20.77-4.57,42.06-5.38,63.28-2.4,21.21,2.98,41.46,9.62,60.16,19.74,4.13,2.23,5.66,7.38,3.43,11.51Zm15.94-32.38c-2.1,4.04-6.47,6.13-10.73,5.53-1.15-.16-2.28-.52-3.37-1.08-19.7-10.25-40.92-17.02-63.07-20.13-22.15-3.11-44.42-2.45-66.18,1.97-5.66,1.15-11.17-2.51-12.32-8.16-1.15-5.66,2.51-11.17,8.16-12.32,24.1-4.89,48.74-5.62,73.25-2.18,24.51,3.44,47.99,10.94,69.81,22.29,5.12,2.66,7.11,8.97,4.45,14.09Z';

/// `Primary_Logo_Black_RGB.svg`: the file sets no fill, so the path draws in
/// SVG's default black.
const String spotifyIconBlackSvg =
    '<svg id="Layer_1" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 236.05 225.25">'
    '<path stroke-width="0px" d="$_spotifyIconPath"/></svg>';

/// `Primary_Logo_White_RGB.svg`: the same path, `fill:#fff`.
const String spotifyIconWhiteSvg =
    '<svg id="Layer_1" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 236.05 225.25">'
    '<path fill="#fff" stroke-width="0px" d="$_spotifyIconPath"/></svg>';

/// Apple Music's colour tile, [size] square, always in full colour.
class AppleMusicIcon extends StatelessWidget {
  const AppleMusicIcon({super.key, this.size = 22});

  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox.square(
      dimension: size,
      child: SvgPicture.string(appleMusicIconSvg, fit: BoxFit.contain),
    ),
  );
}

/// Spotify's monochrome icon, in a [size] square box: black in the light
/// theme, white in the dark one, never under [minSize].
class SpotifyIcon extends StatelessWidget {
  const SpotifyIcon({super.key, double size = 22})
    : size = size < minSize ? minSize : size;

  final double size;

  /// Spotify's own floor for the icon on screen.
  static const double minSize = 21;

  /// Which official file the theme draws, for tests.
  static String svgFor(Brightness brightness) =>
      brightness == Brightness.dark ? spotifyIconWhiteSvg : spotifyIconBlackSvg;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    // The artwork is wider than tall; it sits centred in the square.
    child: SizedBox.square(
      dimension: size,
      child: SvgPicture.string(
        svgFor(Theme.of(context).brightness),
        fit: BoxFit.contain,
      ),
    ),
  );
}
