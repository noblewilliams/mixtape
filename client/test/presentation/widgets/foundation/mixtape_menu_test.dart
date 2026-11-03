import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/frosted_surface.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_menu.dart';

const _anchorKey = Key('anchor');

/// A button at [alignment] that opens a menu of [actions] and records what it
/// answered.
Future<List<Object?>> _host(
  WidgetTester tester, {
  required List<MixtapeMenuAction<String>> actions,
  Alignment alignment = Alignment.topLeft,
  bool dark = false,
  bool reduceTransparency = false,
  String? title,
  WidgetBuilder? lifted,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final answers = <Object?>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? MixtapeTheme.dark() : MixtapeTheme.light(),
      builder: (context, child) => FrostedSurfaceMode(
        reduceTransparency: reduceTransparency,
        child: child!,
      ),
      home: Scaffold(
        body: SafeArea(
          child: Align(
            alignment: alignment,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Builder(
                builder: (anchor) => SizedBox(
                  key: _anchorKey,
                  width: 60,
                  height: 44,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () async => answers.add(
                      await showMixtapeMenu<String>(
                        anchor,
                        actions: actions,
                        title: title,
                        lifted: lifted,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return answers;
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(_anchorKey));
  await tester.pumpAndSettle();
}

const _plain = [
  MixtapeMenuAction(value: 'rename', label: 'Rename', key: Key('rename')),
  MixtapeMenuAction(
    value: 'settings',
    label: 'Tape settings',
    key: Key('settings'),
  ),
  MixtapeMenuAction(
    value: 'archive',
    label: 'Archive',
    key: Key('archive'),
    isDestructive: true,
    separatorBefore: true,
  ),
];

void main() {
  testWidgets('anchors below the control and returns the chosen value', (
    tester,
  ) async {
    final answers = await _host(tester, actions: _plain);
    await _open(tester);

    final menu = tester.getRect(find.byKey(mixtapeMenuKey));
    final anchor = tester.getRect(find.byKey(_anchorKey));
    expect(menu.top, greaterThanOrEqualTo(anchor.bottom));
    expect(menu.top - anchor.bottom, lessThan(16));
    expect(menu.left, closeTo(anchor.left, 0.5));
    expect(menu.width, greaterThanOrEqualTo(232));

    await tester.tap(find.byKey(const Key('settings')));
    await tester.pumpAndSettle();
    expect(answers, ['settings']);
    expect(find.byKey(mixtapeMenuKey), findsNothing);
  });

  testWidgets('has no Cancel row; tapping outside answers null', (
    tester,
  ) async {
    final answers = await _host(tester, actions: _plain);
    await _open(tester);
    expect(find.text('Cancel'), findsNothing);

    expect(find.byKey(mixtapeMenuBarrierKey), findsOneWidget);
    await tester.tapAt(const Offset(380, 830));
    await tester.pumpAndSettle();
    expect(answers, [null]);
    expect(find.byKey(mixtapeMenuKey), findsNothing);
  });

  testWidgets('opens above a control near the bottom, inside the margins', (
    tester,
  ) async {
    await _host(tester, actions: _plain, alignment: Alignment.bottomRight);
    await _open(tester);

    final menu = tester.getRect(find.byKey(mixtapeMenuKey));
    final anchor = tester.getRect(find.byKey(_anchorKey));
    expect(menu.bottom, lessThanOrEqualTo(anchor.top));
    // Right-aligned to a right-hand control, never past the 14 pt margin.
    expect(menu.right, lessThanOrEqualTo(390 - 14));
    expect(menu.right, closeTo(anchor.right, 0.5));
  });

  testWidgets('rows are 44 pt with subtitle, tick, icon and leading', (
    tester,
  ) async {
    await _host(
      tester,
      actions: const [
        MixtapeMenuAction(
          value: 'a',
          label: 'Play here',
          key: Key('a'),
          isSelected: true,
        ),
        MixtapeMenuAction(
          value: 'b',
          label: 'Play in Apple Music',
          key: Key('b'),
          subtitle: 'Opens Music',
          icon: Icons.music_note,
          leading: SizedBox(key: Key('lead'), width: 10, height: 10),
        ),
      ],
    );
    await _open(tester);

    expect(tester.getSize(find.byKey(const Key('a'))).height, 44);
    expect(
      tester.getSize(find.byKey(const Key('b'))).height,
      greaterThanOrEqualTo(44),
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('a')),
        matching: find.byKey(MixtapeMenuItem.tickKey),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('b')),
        matching: find.byKey(MixtapeMenuItem.tickKey),
      ),
      findsNothing,
    );
    expect(find.text('Opens Music'), findsOneWidget);
    expect(find.byIcon(Icons.music_note), findsOneWidget);
    // Leading sits before the label.
    expect(
      tester.getCenter(find.byKey(const Key('lead'))).dx,
      lessThan(tester.getTopLeft(find.text('Play in Apple Music')).dx),
    );
    expect(
      tester.getSemantics(find.byKey(const Key('a'))),
      matchesSemantics(
        label: 'Play here',
        isButton: true,
        hasTapAction: true,
        isSelected: true,
        hasSelectedState: true,
        hasEnabledState: true,
        isEnabled: true,
      ),
    );
  });

  testWidgets('destructive is red and sits behind a 6 pt gap', (tester) async {
    await _host(tester, actions: _plain);
    await _open(tester);

    final archive = tester.widget<Text>(find.text('Archive'));
    final rename = tester.widget<Text>(find.text('Rename'));
    expect(archive.style?.color, MixtapeMenuItem.destructiveLight);
    expect(rename.style?.color, MixtapeTokens.light.text);

    final settings = tester.getRect(find.byKey(const Key('settings')));
    final archiveRow = tester.getRect(find.byKey(const Key('archive')));
    expect(archiveRow.top - settings.bottom, closeTo(6, 0.5));
  });

  testWidgets('a disabled entry does nothing', (tester) async {
    final answers = await _host(
      tester,
      actions: const [
        MixtapeMenuAction(
          value: 'x',
          label: 'Off',
          key: Key('x'),
          enabled: false,
        ),
        MixtapeMenuAction(value: 'y', label: 'On', key: Key('y')),
      ],
    );
    await _open(tester);
    await tester.tap(find.byKey(const Key('x')));
    await tester.pumpAndSettle();
    expect(answers, isEmpty);
    expect(find.byKey(mixtapeMenuKey), findsOneWidget);
  });

  testWidgets(
    'is translucent sheet surface, opaque under reduced transparency',
    (tester) async {
      await _host(tester, actions: _plain);
      await _open(tester);
      Color fill() =>
          ((tester
                      .widget<DecoratedBox>(
                        find
                            .descendant(
                              of: find.byKey(mixtapeMenuKey),
                              matching: find.byType(DecoratedBox),
                            )
                            .first,
                      )
                      .decoration
                  as BoxDecoration)
              .color)!;
      expect(fill().a, lessThan(1));
      expect(fill().withValues(alpha: 1), MixtapeTokens.light.sheetSurface);

      await tester.tapAt(const Offset(380, 830));
      await tester.pumpAndSettle();
      await _host(tester, actions: _plain, reduceTransparency: true);
      await _open(tester);
      expect(fill(), MixtapeTokens.light.sheetSurface);
    },
  );

  testWidgets('a title sits above the entries', (tester) async {
    await _host(tester, actions: _plain, title: 'Set all files');
    await _open(tester);
    expect(
      tester.getCenter(find.text('Set all files')).dy,
      lessThan(tester.getCenter(find.text('Rename')).dy),
    );
  });

  testWidgets('a lifted copy of the anchor rides above the dim', (
    tester,
  ) async {
    await _host(
      tester,
      actions: _plain,
      lifted: (_) => const Text('Lifted row'),
    );
    await _open(tester);
    final lifted = tester.getRect(find.byKey(mixtapeMenuLiftKey));
    final anchor = tester.getRect(find.byKey(_anchorKey));
    expect(lifted.center, anchor.center);
    expect(find.text('Lifted row'), findsOneWidget);
    final menu = tester.getRect(find.byKey(mixtapeMenuKey));
    expect(menu.top, greaterThanOrEqualTo(lifted.bottom));
  });

  testWidgets('a full-screen anchor clamps inside the margins', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late BuildContext outer;
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: Builder(
          builder: (context) {
            outer = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    // The page itself is the anchor here: it fills the screen, so there is
    // no room below or above and the menu clamps inside the margins.
    showMixtapeMenu<String>(outer, actions: _plain);
    await tester.pumpAndSettle();
    final menu = tester.getRect(find.byKey(mixtapeMenuKey));
    expect(menu.left, greaterThanOrEqualTo(14));
    expect(menu.right, lessThanOrEqualTo(390 - 14));
    expect(menu.top, greaterThanOrEqualTo(14));
    expect(menu.bottom, lessThanOrEqualTo(844 - 14));
  });
}
