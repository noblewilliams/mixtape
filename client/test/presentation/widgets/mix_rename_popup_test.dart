// Rename in the app's pop-up (founder, 2026-11-22), like Save as playlist:
// the mix's cassette at the top wears the name as it is typed.
import 'package:flutter/cupertino.dart' show CupertinoAlertDialog, CupertinoTextField;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/screens/first_run/step_scaffold.dart'
    show FirstRunPill;
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/cassette_tile.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_popup.dart';
import 'package:mixtape/presentation/widgets/mix_popup_art.dart';
import 'package:mixtape/presentation/widgets/mix_rename_popup.dart';

const _field = Key('test-rename-field');
const _confirm = Key('test-rename-confirm');

Future<String?> Function() _open(WidgetTester tester) {
  String? answer;
  var done = false;
  return () async {
    final context = tester.element(find.text('open'));
    showMixRenamePopup(
      context,
      title: 'Sunday',
      heading: 'Rename mix',
      caseColor: const Color(0xFFE2B33C),
      fieldKey: _field,
      confirmKey: _confirm,
    ).then((value) {
      answer = value;
      done = true;
    });
    await tester.pumpAndSettle();
    return done ? answer : null;
  };
}

Widget _app() => MaterialApp(
  theme: MixtapeTheme.light(),
  home: const Scaffold(body: Center(child: Text('open'))),
);

void main() {
  testWidgets('opens as the app pop-up, the title selected, the tape wearing it', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    await _open(tester)();

    expect(find.byKey(MixtapePopup.surfaceKey), findsOneWidget);
    expect(find.byType(CupertinoAlertDialog), findsNothing);
    expect(find.text('Rename mix'), findsOneWidget);
    expect(find.byKey(MixPopupArt.artKey), findsOneWidget);

    final field = tester.widget<CupertinoTextField>(find.byKey(_field));
    expect(field.controller!.text, 'Sunday');
    expect(field.controller!.selection.baseOffset, 0);
    expect(field.controller!.selection.extentOffset, 'Sunday'.length);
    expect(field.maxLines, 3);
    expect(
      tester.widget<CassetteTile>(
        find.descendant(
          of: find.byKey(MixPopupArt.artKey),
          matching: find.byType(CassetteTile),
        ),
      ).title,
      'Sunday',
    );

    await tester.enterText(find.byKey(_field), 'A softer Sunday');
    await tester.pump();
    expect(
      tester.widget<CassetteTile>(
        find.descendant(
          of: find.byKey(MixPopupArt.artKey),
          matching: find.byType(CassetteTile),
        ),
      ).title,
      'A softer Sunday',
    );
  });

  testWidgets('Save answers the new name; a blank name cannot be saved', (
    tester,
  ) async {
    await tester.pumpWidget(_app());
    String? answer;
    showMixRenamePopup(
      tester.element(find.text('open')),
      title: 'Sunday',
      heading: 'Rename mix',
      fieldKey: _field,
      confirmKey: _confirm,
    ).then((value) => answer = value);
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(_field), '   ');
    await tester.pump();
    expect(tester.widget<FirstRunPill>(find.byKey(_confirm)).onPressed, isNull);

    await tester.enterText(find.byKey(_field), 'Late light');
    await tester.pump();
    await tester.tap(find.byKey(_confirm));
    await tester.pumpAndSettle();
    expect(answer, 'Late light');
    expect(find.byKey(MixtapePopup.surfaceKey), findsNothing);
  });

  testWidgets('Cancel answers nothing', (tester) async {
    await tester.pumpWidget(_app());
    var answered = false;
    String? answer = 'x';
    showMixRenamePopup(
      tester.element(find.text('open')),
      title: 'Sunday',
      heading: 'Rename',
      fieldKey: _field,
      confirmKey: _confirm,
    ).then((value) {
      answered = true;
      answer = value;
    });
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(MixRenamePopup.cancelKey));
    await tester.pumpAndSettle();
    expect(answered, isTrue);
    expect(answer, isNull);
  });
}
