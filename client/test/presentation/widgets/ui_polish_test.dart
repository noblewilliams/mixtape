import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/cassette_tile.dart';
import 'package:mixtape/presentation/widgets/foundation/mixtape_feedback.dart';
import 'package:mixtape/presentation/widgets/foundation/empty_state.dart';
import 'package:mixtape/presentation/widgets/mix_handoff.dart';
import 'package:mixtape/presentation/widgets/tape_settings_dialog.dart';

void main() {
  testWidgets('Undo runs once even before its dismissal animation completes', (
    tester,
  ) async {
    var actions = 0;
    final messenger = GlobalKey<ScaffoldMessengerState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        scaffoldMessengerKey: messenger,
        home: const Scaffold(body: SizedBox()),
      ),
    );
    messenger.currentState!.showSnackBar(
      mixtapeSnackBar(
        message: 'Mix archived',
        actionLabel: 'Undo',
        onAction: () => actions++,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Undo'));
    await tester.tap(find.text('Undo'));
    expect(actions, 1);
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsNothing);
  });

  testWidgets('long feedback stays in the 44 point band at normal text size', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MixtapeTheme.light(),
        home: const Scaffold(
          body: Center(
            child: SizedBox(
              width: 280,
              child: MixtapeFeedback(
                key: Key('long-feedback'),
                message:
                    'Could not refresh this mix. Your saved tracks are still available. Please try again later.',
                kind: FeedbackKind.error,
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.getSize(find.byKey(const Key('long-feedback'))).height, 44);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty playlist name disables submission until nonblank input', (
    tester,
  ) async {
    var saves = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MixSaveDialog(
            keys: MixHandoffKeys.arrangement,
            defaultName: ' ',
            defaultAuthor: '',
            onConfirm: (_, _) async {
              saves++;
            },
          ),
        ),
      ),
    );
    final button = find.byKey(MixHandoffKeys.arrangement.saveConfirm);
    expect(tester.widget<CupertinoDialogAction>(button).onPressed, isNull);
    await tester.enterText(
      find.byKey(MixHandoffKeys.arrangement.nameField),
      '   ',
    );
    await tester.pump();
    expect(tester.widget<CupertinoDialogAction>(button).onPressed, isNull);
    await tester.enterText(
      find.byKey(MixHandoffKeys.arrangement.nameField),
      'Sunday',
    );
    await tester.pump();
    await tester.tap(button);
    await tester.pump();
    expect(saves, 1);
  });

  testWidgets(
    'toast Undo keeps the same height as success and no overflow at 200%',
    (tester) async {
      for (final scale in [1.0, 2.0]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: MixtapeTheme.light(),
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: Column(
                  children: [
                    const MixtapeFeedback(
                      key: Key('plain'),
                      message: 'Mix archived',
                      kind: FeedbackKind.success,
                    ),
                    MixtapeFeedback(
                      key: const Key('undo'),
                      message: 'Mix archived',
                      kind: FeedbackKind.success,
                      actionLabel: 'Undo',
                      onAction: () {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        if (scale == 1) {
          expect(
            tester.getSize(find.byKey(const Key('plain'))).height,
            tester.getSize(find.byKey(const Key('undo'))).height,
          );
        }
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('render approved native states for light dark and large text', (
    tester,
  ) async {
    if (Platform.isMacOS) {
      await tester.runAsync(() async {
        final bytes = await File(
          '/System/Library/Fonts/SFNS.ttf',
        ).readAsBytes();
        final loader = FontLoader('Roboto')
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
        final hand = await File(
          '/System/Library/Fonts/Noteworthy.ttc',
        ).readAsBytes();
        await (FontLoader(
          'Noteworthy',
        )..addFont(Future.value(ByteData.sublistView(hand)))).load();
      });
    }
    await tester.binding.setSurfaceSize(const Size(420, 1050));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final mode in ['light', 'dark', 'large']) {
      final capture = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: mode == 'dark' ? MixtapeTheme.dark() : MixtapeTheme.light(),
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(420, 1050),
              textScaler: TextScaler.linear(mode == 'large' ? 2 : 1),
            ),
            child: RepaintBoundary(
              key: capture,
              child: Scaffold(
                backgroundColor: mode == 'dark'
                    ? const Color(0xff19171d)
                    : const Color(0xfff5f3f7),
                body: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        const SizedBox(height: 20),
                        const Row(
                          children: [
                            CassetteTile(
                              width: 80,
                              title: 'A slow Sunday',
                              caseColor: Color(0xff88c9b3),
                              shadow: true,
                            ),
                            SizedBox(width: 14),
                            Expanded(child: Text('A slow Sunday')),
                          ],
                        ),
                        const SizedBox(height: 18),
                        for (final kind in FeedbackKind.values)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: MixtapeFeedback(
                              message: kind == FeedbackKind.error
                                  ? 'Couldn’t rename mix'
                                  : kind == FeedbackKind.success
                                  ? 'Mix archived'
                                  : 'Already in your library',
                              kind: kind,
                              actionLabel: kind == FeedbackKind.success
                                  ? 'Undo'
                                  : null,
                              onAction: kind == FeedbackKind.success
                                  ? () {}
                                  : null,
                            ),
                          ),
                        const SizedBox(height: 20),
                        const EmptyState(
                          title: 'No saved preferences',
                          body: 'The DJ remembers what matters to you.',
                          artwork: EmptyStateArtwork.memory,
                        ),
                        const SizedBox(height: 20),
                        TapeSettingsDialog(
                          title: 'A slow Sunday',
                          initialColor: '#88c9b3',
                          onSave: (_) async => true,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final boundary =
          capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '/tmp/mixtape-native-$mode.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
