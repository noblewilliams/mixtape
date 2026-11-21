// The official service icons (add your music board r3/r4, "official icons"):
// the files' own artwork, never tinted, decoration only.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/brand_icons.dart';

Future<void> _pump(WidgetTester tester, Widget child, {bool dark = false}) =>
    tester.pumpWidget(
      MaterialApp(
        theme: dark ? MixtapeTheme.dark() : MixtapeTheme.light(),
        home: Scaffold(body: Center(child: child)),
      ),
    );

/// Every `d="…"` in an SVG, in order.
List<String> _paths(String svg) => [
  for (final m in RegExp(r' d="([^"]+)"').allMatches(svg)) m.group(1)!,
];

void main() {
  test('the path data is the official files\' own', () {
    // `flutter test` runs from client/; the packs live in docs/brand.
    String brand(String path) => File('../docs/brand/$path').readAsStringSync();
    expect(
      _paths(appleMusicIconSvg),
      _paths(brand('apple-music/Apple_Music_Icon_RGB_sm_073120.svg')),
    );
    expect(appleMusicIconSvg, contains('stop-color:#FA233B'));
    expect(appleMusicIconSvg, contains('stop-color:#FB5C74'));
    expect(
      _paths(spotifyIconBlackSvg),
      _paths(brand('spotify/Primary_Logo_Black_RGB.svg')),
    );
    expect(
      _paths(spotifyIconWhiteSvg),
      _paths(brand('spotify/Primary_Logo_White_RGB.svg')),
    );
    expect(spotifyIconWhiteSvg, contains('fill="#fff"'));
    expect(spotifyIconBlackSvg, isNot(contains('fill=')));
  });

  testWidgets('all three files parse and draw', (tester) async {
    await tester.runAsync(() async {
      for (final svg in [
        appleMusicIconSvg,
        spotifyIconBlackSvg,
        spotifyIconWhiteSvg,
      ]) {
        final info = await vg.loadPicture(SvgStringLoader(svg), null);
        expect(info.size.isEmpty, isFalse);
        info.picture.dispose();
      }
    });
  });

  testWidgets('Apple Music is the colour tile at the asked size, untinted', (
    tester,
  ) async {
    await _pump(tester, const AppleMusicIcon(size: 32));
    final picture = find.byType(SvgPicture);
    expect(tester.getSize(find.byType(AppleMusicIcon)), const Size(32, 32));
    expect(tester.widget<SvgPicture>(picture).colorFilter, isNull);
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets('Spotify is the ${dark ? 'white' : 'black'} icon in '
        '${dark ? 'dark' : 'light'}', (tester) async {
      await _pump(tester, const SpotifyIcon(size: 22), dark: dark);
      final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
      expect(svg.colorFilter, isNull);
      expect(
        SpotifyIcon.svgFor(dark ? Brightness.dark : Brightness.light),
        dark ? spotifyIconWhiteSvg : spotifyIconBlackSvg,
      );
      expect(tester.getSize(find.byType(SpotifyIcon)), const Size(22, 22));
    });
  }

  testWidgets('Spotify never draws under its 21 px floor', (tester) async {
    await _pump(tester, const SpotifyIcon(size: 14));
    expect(tester.getSize(find.byType(SpotifyIcon)), const Size(21, 21));
  });

  testWidgets('both icons are decoration, out of the semantics tree', (
    tester,
  ) async {
    await _pump(
      tester,
      const Row(
        mainAxisSize: MainAxisSize.min,
        children: [AppleMusicIcon(), SpotifyIcon()],
      ),
    );
    expect(find.byType(ExcludeSemantics), findsWidgets);
    for (final type in [AppleMusicIcon, SpotifyIcon]) {
      expect(
        find.descendant(
          of: find.byType(type),
          matching: find.byType(ExcludeSemantics),
        ),
        findsOneWidget,
      );
    }
  });
}
