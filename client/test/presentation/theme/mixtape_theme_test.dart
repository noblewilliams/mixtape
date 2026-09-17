import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';

/// WCAG 2.1 relative luminance of an opaque colour.
double _luminance(Color color) {
  double channel(double component) => component <= 0.03928
      ? component / 12.92
      : math.pow((component + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

/// WCAG 2.1 contrast ratio between two opaque colours (1.0 – 21.0).
double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

Future<MixtapeTokens> _pumpAndReadTokens(
  WidgetTester tester,
  ThemeData theme,
) async {
  MixtapeTokens? seen;
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Builder(
        builder: (context) {
          seen = context.tokens;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return seen!;
}

void main() {
  group('tokens are attached to the theme', () {
    testWidgets('light tokens read through context.tokens', (tester) async {
      final theme = MixtapeTheme.light();
      expect(theme.extension<MixtapeTokens>(), MixtapeTokens.light);

      final tokens = await _pumpAndReadTokens(tester, theme);
      expect(tokens, MixtapeTokens.light);
      expect(tokens.text, const Color(0xFF1C1A1E));
      expect(tokens.plum, const Color(0xFF544451));
      expect(tokens.gradientTop, const Color(0xFFF9F7F4));
    });

    testWidgets('dark tokens read through context.tokens', (tester) async {
      final theme = MixtapeTheme.dark();
      expect(theme.extension<MixtapeTokens>(), MixtapeTokens.dark);

      final tokens = await _pumpAndReadTokens(tester, theme);
      expect(tokens, MixtapeTokens.dark);
      expect(tokens.text, const Color(0xFFF2EEF1));
      expect(tokens.gradientTop, const Color(0xFF050507));
    });

    test('the colour scheme is derived from the tokens', () {
      final light = MixtapeTheme.light();
      expect(light.colorScheme.primary, MixtapeTokens.light.plum);
      expect(light.colorScheme.surface, MixtapeTokens.light.gradientTop);
      expect(light.colorScheme.onSurface, MixtapeTokens.light.text);
      expect(light.colorScheme.error, MixtapeTokens.light.errInk);
      expect(light.scaffoldBackgroundColor, const Color(0x00000000));
      expect(light.dividerColor, MixtapeTokens.light.hairline);

      final dark = MixtapeTheme.dark();
      expect(dark.colorScheme.brightness, Brightness.dark);
      expect(dark.colorScheme.primary, MixtapeTokens.dark.plum);
      expect(dark.scaffoldBackgroundColor, const Color(0x00000000));
    });
  });

  group('contrast on the background gradient', () {
    for (final entry in {
      'light': MixtapeTokens.light,
      'dark': MixtapeTokens.dark,
    }.entries) {
      final name = entry.key;
      final tokens = entry.value;
      // Both ends of the fall: the bottom is the worst case.
      final grounds = {
        'top': tokens.gradientTop,
        'bottom': tokens.gradientBottom,
      };

      for (final ground in grounds.entries) {
        final where = '$name on the gradient ${ground.key}';
        final base = ground.value;

        test('$where: text and smoke clear 4.5:1', () {
          expect(_contrast(tokens.text, base), greaterThanOrEqualTo(4.5));
          expect(_contrast(tokens.smoke, base), greaterThanOrEqualTo(4.5));
        });

        test('$where: muted clears 3.0:1', () {
          expect(_contrast(tokens.muted, base), greaterThanOrEqualTo(3.0));
        });

        test('$where: status ink clears 3.0:1', () {
          expect(_contrast(tokens.okInk, base), greaterThanOrEqualTo(3.0));
          expect(_contrast(tokens.warnInk, base), greaterThanOrEqualTo(3.0));
          expect(_contrast(tokens.errInk, base), greaterThanOrEqualTo(3.0));
        });
      }
    }
  });

  group('colour scheme roles stay legible', () {
    for (final entry in {
      'light': MixtapeTheme.light(),
      'dark': MixtapeTheme.dark(),
    }.entries) {
      final name = entry.key;
      final scheme = entry.value.colorScheme;

      test('$name on-role ink clears 4.5:1 against its role', () {
        final pairs = {
          'onPrimary': (scheme.onPrimary, scheme.primary),
          'onSecondary': (scheme.onSecondary, scheme.secondary),
          'onError': (scheme.onError, scheme.error),
          'onSurface': (scheme.onSurface, scheme.surface),
        };
        pairs.forEach((label, pair) {
          expect(
            _contrast(pair.$1, pair.$2),
            greaterThanOrEqualTo(4.5),
            reason: '$name $label',
          );
        });
      });

      test('$name container ink clears 4.5:1 against its container', () {
        final pairs = {
          'onPrimaryContainer': (
            scheme.onPrimaryContainer,
            scheme.primaryContainer,
          ),
          'onSecondaryContainer': (
            scheme.onSecondaryContainer,
            scheme.secondaryContainer,
          ),
          'onErrorContainer': (
            scheme.onErrorContainer,
            scheme.errorContainer,
          ),
        };
        pairs.forEach((label, pair) {
          expect(
            _contrast(pair.$1, pair.$2),
            greaterThanOrEqualTo(4.5),
            reason: '$name $label',
          );
        });
      });
    }
  });

  group('type scale', () {
    test('meta is the 12 pt floor and labels are 10 pt', () {
      for (final tokens in [MixtapeTokens.light, MixtapeTokens.dark]) {
        expect(tokens.meta.fontSize, 12);
        expect(tokens.label.fontSize, 10);
        expect(tokens.largeTitle.fontSize, 34);
        expect(tokens.largeTitle.fontWeight, FontWeight.w800);
        expect(tokens.body.fontSize, 16);
        expect(tokens.secondary.fontSize, 13);
      }
    });

    test('nothing in the exposed styles is smaller than 10', () {
      for (final tokens in [MixtapeTokens.light, MixtapeTokens.dark]) {
        expect(tokens.textStyles, isNotEmpty);
        for (final style in tokens.textStyles) {
          expect(style.fontSize, isNotNull);
          expect(style.fontSize, greaterThanOrEqualTo(10));
          expect(style.fontFamily, isNull, reason: 'system font only');
        }
      }
    });

    test('secondary and meta carry their own inks', () {
      expect(MixtapeTokens.light.secondary.color, MixtapeTokens.light.smoke);
      expect(MixtapeTokens.light.meta.color, MixtapeTokens.light.muted);
      expect(MixtapeTokens.light.body.color, MixtapeTokens.light.text);
    });
  });

  group('prism', () {
    test('has six stops in the approved order', () {
      const expected = [
        Color(0xFFC9687F),
        Color(0xFFD18A65),
        Color(0xFFD2C76F),
        Color(0xFF709778),
        Color(0xFF688FA8),
        Color(0xFF6E5C8F),
      ];
      expect(MixtapeTokens.light.prism, expected);
      expect(MixtapeTokens.dark.prism, expected);
    });

    test('prismGradient runs top-left to bottom-right by default', () {
      final gradient = MixtapeTokens.light.prismGradient();
      expect(gradient.colors, MixtapeTokens.light.prism);
      expect(gradient.begin, Alignment.topLeft);
      expect(gradient.end, Alignment.bottomRight);
      expect(gradient.stops, const [0.0, 0.22, 0.42, 0.62, 0.82, 1.0]);
    });

    test('prismVertical uses the first five stops top to bottom', () {
      final gradient = MixtapeTokens.light.prismVertical;
      expect(gradient.colors, MixtapeTokens.light.prism.take(5).toList());
      expect(gradient.colors.length, 5);
      expect(gradient.begin, Alignment.topCenter);
      expect(gradient.end, Alignment.bottomCenter);
      expect(gradient.stops, isNull, reason: 'evenly spaced');
    });
  });

  group('background gradient and glows', () {
    test('light base falls warm white to lilac grey', () {
      final gradient = MixtapeTokens.light.backgroundGradient;
      expect(gradient.colors, const [
        Color(0xFFF9F7F4),
        Color(0xFFF1EEEE),
        Color(0xFFE6E0EA),
      ]);
      expect(gradient.stops, const [0.0, 0.45, 1.0]);
      expect(gradient.begin, Alignment.topCenter);
      expect(gradient.end, Alignment.bottomCenter);
    });

    test('the violet glow sits below the bottom edge', () {
      final glow = MixtapeTokens.light.violetGlow;
      expect(glow.center, const Alignment(0, 1.16));
      expect(glow.radiusX, 0.9);
      expect(glow.radiusY, 0.45);
      expect(MixtapeTokens.light.pinkGlow.center, const Alignment(-1, 0.84));
      expect(MixtapeTokens.light.blueGlow.center, const Alignment(1, 0.6));
    });
  });

  group('glass shadow and scrim base', () {
    test('carry the approved values', () {
      expect(
        MixtapeTokens.light.glassShadow,
        const Color.fromRGBO(30, 24, 30, 0.16),
      );
      expect(MixtapeTokens.light.scrimBase, const Color(0xFFF8F6F3));
      expect(MixtapeTokens.dark.glassShadow, const Color.fromRGBO(0, 0, 0, 0.5));
      expect(MixtapeTokens.dark.scrimBase, const Color(0xFF08080C));
    });
  });

  group('context.tokens', () {
    testWidgets('fails loudly when the extension is missing', (tester) async {
      Object? caught;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: Builder(
            builder: (context) {
              try {
                context.tokens;
              } catch (error) {
                caught = error;
              }
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(caught, isA<AssertionError>());
      expect('$caught', contains('MixtapeTokens'));
    });
  });

  group('lerp', () {
    test('t=0 is light and t=1 is dark', () {
      final atZero = MixtapeTokens.light.lerp(MixtapeTokens.dark, 0);
      final atOne = MixtapeTokens.light.lerp(MixtapeTokens.dark, 1);
      expect(atZero, MixtapeTokens.light);
      expect(atOne, MixtapeTokens.dark);
    });

    test('halfway lands between the two texts', () {
      final mid = MixtapeTokens.light.lerp(MixtapeTokens.dark, 0.5);
      expect(mid.text, isNot(MixtapeTokens.light.text));
      expect(mid.text, isNot(MixtapeTokens.dark.text));
      expect(mid.prism, MixtapeTokens.light.prism);
      expect(mid.meta.fontSize, 12);
    });
  });

  group('metrics', () {
    test('targets and dock geometry match the board', () {
      expect(MixtapeMetrics.minTarget, 44);
      expect(MixtapeMetrics.tileRadius, 3);
      expect(MixtapeMetrics.tapeRadiusTop, 6);
      expect(MixtapeMetrics.tapeRadiusBottom, 10);
      expect(MixtapeMetrics.tapeButtonHeight, 40);
      expect(MixtapeMetrics.chipHeight, 36);
      expect(MixtapeMetrics.composerHeight, 48);
      expect(MixtapeMetrics.pillHeight, 34);
      expect(MixtapeMetrics.miniPlayerHeight, 52);
      expect(MixtapeMetrics.miniArt, 38);
      expect(MixtapeMetrics.tabBarHeight, 56);
      expect(MixtapeMetrics.tabIcon, 22);
      expect(MixtapeMetrics.dockSideMargin, 22);
      expect(MixtapeMetrics.dockGap, 7);
      expect(MixtapeMetrics.largeTitleTopPadding, 30);
      expect(MixtapeMetrics.screenSidePadding, 20);
    });
  });
}
