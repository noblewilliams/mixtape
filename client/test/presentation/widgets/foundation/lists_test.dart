import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/flush_row.dart';
import 'package:mixtape/presentation/widgets/foundation/inset_group.dart';
import 'package:mixtape/presentation/widgets/foundation/reason_band.dart';
import 'package:mixtape/presentation/widgets/foundation/section_word.dart';
import 'package:mixtape/presentation/widgets/foundation/square_art.dart';

Future<MixtapeTokens> _pump(
  WidgetTester tester,
  Widget child, {
  ThemeData? theme,
  double width = 390,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  MixtapeTokens? tokens;
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? MixtapeTheme.light(),
      home: Builder(
        builder: (context) {
          tokens = context.tokens;
          return MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: Scaffold(
              body: Center(
                child: SizedBox(width: width, child: child),
              ),
            ),
          );
        },
      ),
    ),
  );
  return tokens!;
}

Text _titleText(WidgetTester tester, String data) =>
    tester.widget<Text>(find.text(data));

void main() {
  group('FlushList hairlines', () {
    testWidgets('no hairline on the first row, one on the second', (
      tester,
    ) async {
      await _pump(
        tester,
        const FlushList(
          children: [
            FlushRow(leading: SquareArt(), title: 'Late nights'),
            FlushRow(leading: SquareArt(), title: 'Running, long'),
          ],
        ),
      );

      expect(find.byKey(FlushRow.hairlineKey), findsOneWidget);
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('Running, long'),
            matching: find.byType(FlushRow),
          ),
          matching: find.byKey(FlushRow.hairlineKey),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a lone row never draws one', (tester) async {
      await _pump(
        tester,
        const FlushList(
          children: [FlushRow(leading: SquareArt(), title: 'Late nights')],
        ),
      );

      expect(find.byKey(FlushRow.hairlineKey), findsNothing);
    });

    testWidgets('the hairline inset follows the leading size', (tester) async {
      await _pump(
        tester,
        const FlushList(
          children: [
            FlushRow(
              leading: SquareArt(size: 48),
              title: 'One',
              leadingSize: 48,
            ),
            FlushRow(
              leading: SquareArt(size: 48),
              title: 'Two',
              leadingSize: 48,
            ),
          ],
        ),
      );

      final row = tester.getRect(
        find.ancestor(of: find.text('Two'), matching: find.byType(FlushRow)),
      );
      final hairline = tester.getRect(find.byKey(FlushRow.hairlineKey));

      expect(hairline.left - row.left, 48 + 14);
      expect(hairline.right, row.right);
      expect(hairline.top, row.top);
      expect(hairline.height, 1);
    });

    testWidgets('a lazy list keeps hairlines between its rows', (tester) async {
      await _pump(
        tester,
        SizedBox(
          height: 400,
          child: ListView.builder(
            itemCount: 3,
            itemBuilder: (_, index) => FlushRow(
              leading: const SquareArt(),
              title: 'Mix $index',
              isFirst: index == 0,
            ),
          ),
        ),
      );

      // No FlushRowPosition reaches a builder's rows, so the builder says.
      expect(find.byKey(FlushRow.hairlineKey), findsNWidgets(2));
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('Mix 0'),
            matching: find.byType(FlushRow),
          ),
          matching: find.byKey(FlushRow.hairlineKey),
        ),
        findsNothing,
      );
    });

    testWidgets('an unplaced row draws its hairline', (tester) async {
      await _pump(
        tester,
        const FlushRow(leading: SquareArt(), title: 'Late nights'),
      );

      expect(find.byKey(FlushRow.hairlineKey), findsOneWidget);
    });

    testWidgets('inset:false runs the hairline to the left edge', (
      tester,
    ) async {
      await _pump(
        tester,
        const FlushList(
          children: [
            FlushRow(leading: SquareArt(), title: 'One'),
            FlushRow(leading: SquareArt(), title: 'Two', inset: false),
          ],
        ),
      );

      final row = tester.getRect(
        find.ancestor(of: find.text('Two'), matching: find.byType(FlushRow)),
      );

      expect(tester.getRect(find.byKey(FlushRow.hairlineKey)).left, row.left);
    });
  });

  group('FlushRow', () {
    testWidgets('the chevron appears only when the row is tappable', (
      tester,
    ) async {
      await _pump(
        tester,
        const FlushRow(leading: SquareArt(), title: 'Late nights'),
      );
      expect(find.byIcon(Icons.chevron_right), findsNothing);

      var taps = 0;
      await _pump(
        tester,
        FlushRow(
          leading: const SquareArt(),
          title: 'Late nights',
          onTap: () => taps++,
        ),
      );
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);

      await tester.tap(find.text('Late nights'));
      expect(taps, 1);
    });

    testWidgets('a supplied trailing replaces the chevron', (tester) async {
      await _pump(
        tester,
        FlushRow(
          leading: const SquareArt(),
          title: 'Late nights',
          trailing: const Icon(Icons.more_horiz),
          onTap: () {},
        ),
      );

      expect(find.byIcon(Icons.chevron_right), findsNothing);
      expect(find.byIcon(Icons.more_horiz), findsOneWidget);
    });

    testWidgets('the row keeps a 44 pt target', (tester) async {
      await _pump(
        tester,
        FlushRow(leading: const SizedBox.shrink(), title: 'x', onTap: () {}),
      );

      expect(
        tester.getSize(find.byType(FlushRow)).height,
        greaterThanOrEqualTo(44),
      );
    });

    testWidgets('subtitleWidget wins over subtitle', (tester) async {
      await _pump(
        tester,
        const FlushRow(
          leading: SquareArt(),
          title: 'Late nights',
          subtitle: '41 songs',
          subtitleWidget: Text('Ready'),
        ),
      );

      expect(find.text('41 songs'), findsNothing);
      expect(find.text('Ready'), findsOneWidget);
    });

    testWidgets('the subtitle keeps to one line unless the row asks for more', (
      tester,
    ) async {
      const long =
          'Bring your saved music with an Exportify ZIP or CSV, however long.';

      await _pump(
        tester,
        const FlushRow(leading: SquareArt(), title: 'Spotify', subtitle: long),
        width: 300,
      );
      expect(tester.widget<Text>(find.text(long)).maxLines, 1);
      final oneLine = tester.getSize(find.text(long)).height;

      await _pump(
        tester,
        const FlushRow(
          leading: SquareArt(),
          title: 'Spotify',
          subtitle: long,
          subtitleMaxLines: 2,
        ),
        width: 300,
      );
      final subtitle = tester.widget<Text>(find.text(long));
      expect(subtitle.maxLines, 2);
      expect(subtitle.overflow, TextOverflow.ellipsis);
      expect(
        tester.getSize(find.text(long)).height,
        greaterThan(oneLine),
        reason: 'the long subtitle should actually run onto a second line',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the leading mark stays centred on a two-line row', (
      tester,
    ) async {
      const long =
          'Bring your saved music with an Exportify ZIP or CSV, however long.';
      await _pump(
        tester,
        const FlushRow(
          leading: SquareArt(),
          title: 'Spotify',
          subtitle: long,
          subtitleMaxLines: 2,
        ),
        width: 300,
      );

      final row = tester.getRect(find.byType(FlushRow));
      final mark = tester.getRect(find.byType(SquareArt));
      expect(mark.center.dy, moreOrLessEquals(row.center.dy, epsilon: 0.5));
    });

    testWidgets('the title ellipsises at the default text size', (
      tester,
    ) async {
      await _pump(
        tester,
        const FlushRow(
          leading: SquareArt(),
          title: 'A very long mix title that cannot fit on one line at all',
        ),
      );

      final title = _titleText(
        tester,
        'A very long mix title that cannot fit on one line at all',
      );
      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the title wraps at 200% text without overflowing', (
      tester,
    ) async {
      const long = 'A very long mix title that cannot fit on one line at all';
      await _pump(
        tester,
        const FlushRow(leading: SquareArt(), title: long),
        width: 320,
        textScaler: const TextScaler.linear(2),
      );

      final title = _titleText(tester, long);
      expect(title.maxLines, isNull);
      expect(title.softWrap, isNot(false));
      expect(tester.takeException(), isNull);
    });
  });

  group('SquareArt', () {
    testWidgets('is a 3 pt square with the light box colour', (tester) async {
      await _pump(
        tester,
        const Align(alignment: Alignment.topLeft, child: SquareArt()),
      );

      expect(tester.getSize(find.byType(SquareArt)), const Size(60, 60));
      final clip = tester.widget<ClipRRect>(
        find
            .descendant(
              of: find.byType(SquareArt),
              matching: find.byType(ClipRRect),
            )
            .first,
      );
      expect(
        clip.borderRadius,
        BorderRadius.circular(MixtapeMetrics.tileRadius),
      );
      expect(SquareArt.boxColorFor(Brightness.light), const Color(0xFFE8E4E6));
      expect(
        SquareArt.boxColorFor(Brightness.dark),
        const Color.fromRGBO(255, 255, 255, 0.08),
      );
    });

    testWidgets('a gradient placeholder paints two colours diagonally', (
      tester,
    ) async {
      await _pump(
        tester,
        const SquareArt(
          placeholderGradient: [Color(0xFFC9687F), Color(0xFF6E5C8F)],
        ),
      );

      final gradient = tester
          .widgetList<DecoratedBox>(
            find.descendant(
              of: find.byType(SquareArt),
              matching: find.byType(DecoratedBox),
            ),
          )
          .map((box) => box.decoration)
          .whereType<BoxDecoration>()
          .map((decoration) => decoration.gradient)
          .whereType<LinearGradient>()
          .single;

      expect(gradient.colors, const [Color(0xFFC9687F), Color(0xFF6E5C8F)]);
      expect(gradient.begin, Alignment.topLeft);
      expect(gradient.end, Alignment.bottomRight);
    });

    testWidgets('a child sits centred over the placeholder', (tester) async {
      await _pump(tester, const SquareArt(size: 44, child: Text('CS')));

      expect(find.text('CS'), findsOneWidget);
      expect(
        tester.getCenter(find.text('CS')),
        tester.getCenter(find.byType(SquareArt)),
      );
    });

    testWidgets('a non-https url falls back to the placeholder', (
      tester,
    ) async {
      await _pump(tester, const SquareArt(url: 'http://example.com/a.jpg'));

      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('SectionWord', () {
    testWidgets('uses the section style with the board padding', (
      tester,
    ) async {
      final tokens = await _pump(tester, const SectionWord('Playlists'));

      expect(_titleText(tester, 'Playlists').style, tokens.section);
      expect(
        tester
            .widget<Padding>(
              find
                  .descendant(
                    of: find.byType(SectionWord),
                    matching: find.byType(Padding),
                  )
                  .first,
            )
            .padding,
        const EdgeInsets.only(top: 16, bottom: 4),
      );
    });
  });

  group('InsetGroup', () {
    testWidgets('rows are at least 52 pt and destructive rows use err ink', (
      tester,
    ) async {
      final tokens = await _pump(
        tester,
        InsetGroup(
          header: const SectionWord('Settings'),
          children: [
            const InsetRow(
              leading: Icon(Icons.person_outline),
              title: 'Account',
              subtitle: 'dev@example.com',
            ),
            InsetRow(title: 'Sign out', destructive: true, onTap: () {}),
          ],
        ),
      );

      for (final row in find.byType(InsetRow).evaluate()) {
        expect(row.size!.height, greaterThanOrEqualTo(52));
      }
      expect(_titleText(tester, 'Sign out').style?.color, tokens.errInk);
      expect(_titleText(tester, 'Account').style?.color, tokens.text);
      expect(find.byType(SectionWord), findsOneWidget);
    });

    testWidgets('the group is a 22 pt radius surface', (tester) async {
      await _pump(
        tester,
        const InsetGroup(children: [InsetRow(title: 'Account')]),
      );

      final decoration = tester
          .widgetList<DecoratedBox>(
            find.descendant(
              of: find.byType(InsetGroup),
              matching: find.byType(DecoratedBox),
            ),
          )
          .map((box) => box.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((box) => box.borderRadius != null);

      expect(
        decoration.borderRadius,
        BorderRadius.circular(MixtapeMetrics.groupRadius),
      );
      expect(decoration.color, const Color.fromRGBO(255, 255, 255, 0.62));
    });

    testWidgets('hairlines sit between rows, inset 52 pt', (tester) async {
      await _pump(
        tester,
        const InsetGroup(
          children: [
            InsetRow(title: 'One'),
            InsetRow(title: 'Two'),
            InsetRow(title: 'Three'),
          ],
        ),
      );

      expect(find.byKey(InsetGroup.hairlineKey), findsNWidgets(2));
      final group = tester.getRect(find.byType(InsetGroup));
      final hairline = tester.getRect(find.byKey(InsetGroup.hairlineKey).first);
      expect(hairline.left - group.left, 52);
      expect(hairline.height, 1);
    });

    testWidgets('a tappable row shows the chevron and fires', (tester) async {
      var taps = 0;
      await _pump(
        tester,
        InsetGroup(
          children: [
            InsetRow(title: 'Account', onTap: () => taps++),
            const InsetRow(title: 'Version'),
          ],
        ),
      );

      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
      await tester.tap(find.text('Account'));
      expect(taps, 1);
    });

    testWidgets('the leading icon is plum at 22 pt', (tester) async {
      final tokens = await _pump(
        tester,
        const InsetGroup(
          children: [
            InsetRow(leading: Icon(Icons.person_outline), title: 'Account'),
          ],
        ),
      );

      final theme = IconTheme.of(
        tester.element(find.byIcon(Icons.person_outline)),
      );
      expect(theme.size, 22);
      expect(theme.color, tokens.plum);
    });
  });

  group('ReasonBand', () {
    testWidgets('bleeds past the parent by the screen side padding', (
      tester,
    ) async {
      final tokens = await _pump(
        tester,
        const ReasonBand(text: 'Picked for the walk home'),
        width: 300,
      );

      expect(
        tester.getSize(find.byKey(ReasonBand.fillKey)).width,
        300 + 2 * MixtapeMetrics.screenSidePadding,
      );
      expect(tester.getSize(find.byType(ReasonBand)).width, 300);
      expect(
        _titleText(tester, 'Picked for the walk home').style?.color,
        tokens.smoke,
      );
      expect(
        _titleText(tester, 'Picked for the walk home').style?.fontSize,
        12.5,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('dark mode keeps the quiet white wash', (tester) async {
      await _pump(
        tester,
        const ReasonBand(text: 'Picked for the walk home'),
        theme: MixtapeTheme.dark(),
      );

      expect(
        tester.widget<ColoredBox>(find.byKey(ReasonBand.fillKey)).color,
        const Color.fromRGBO(255, 255, 255, 0.06),
      );
    });
  });
}
