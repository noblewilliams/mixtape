import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/foundation/haptics.dart';
import 'package:mixtape/presentation/widgets/mix_home_row.dart';
import 'package:mixtape/presentation/widgets/mix_prompt_input.dart';
import 'package:mixtape/presentation/widgets/mix_select_mode.dart';
import 'package:mixtape/presentation/widgets/now_playing_scrubber.dart';
import 'package:mixtape/presentation/widgets/playlist_inspiration.dart';
import 'package:mixtape/presentation/widgets/track_row.dart';

import '../../helpers/haptic_recorder.dart';

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    theme: MixtapeTheme.light(),
    home: Scaffold(body: Center(child: child)),
  ),
);

final _session = DjSession(
  id: 'one',
  title: 'Sunday',
  status: 'active',
  queueVersion: 1,
  updatedAt: DateTime(2026),
);

void main() {
  testWidgets('sending the prompt is the commit', (tester) async {
    final played = recordHaptics(tester);
    final controller = TextEditingController(text: 'something warm');
    addTearDown(controller.dispose);
    var sent = 0;
    await _pump(
      tester,
      MixPromptInput(
        controller: controller,
        busy: false,
        onSubmit: () => sent++,
      ),
    );

    await tester.tap(find.byKey(const Key('start-session')));

    expect(sent, 1);
    expect(played, [HapticKind.commit]);
  });

  testWidgets('a track row is an ordinary tap', (tester) async {
    final played = recordHaptics(tester);
    var opened = 0;
    await _pump(
      tester,
      SizedBox(
        width: 390,
        child: TrackRow(
          number: 1,
          track: const QueueTrack(
            position: 0,
            trackId: 't1',
            appleId: 'apple-1',
            title: 'Low Tide, Late',
            artist: 'Harbour Lights',
          ),
          expanded: false,
          onTap: () => opened++,
        ),
      ),
    );

    await tester.tap(find.text('Low Tide, Late'));

    expect(opened, 1);
    expect(played, [HapticKind.tap]);
  });

  testWidgets('ticking a mix in select mode is a select', (tester) async {
    final played = recordHaptics(tester);
    var toggled = 0;
    await _pump(
      tester,
      MixHomeRow(
        session: _session,
        onOpen: () {},
        onRename: (_) async => true,
        onArchive: () async => true,
        onRestore: () async => true,
        selecting: true,
        onToggleSelected: () => toggled++,
      ),
    );

    await tester.tap(find.byKey(MixSelect.rowKey('one')));

    expect(toggled, 1);
    expect(played, [HapticKind.select]);
  });

  testWidgets('the inspiration chip opens; its cross backs out', (
    tester,
  ) async {
    final played = recordHaptics(tester);
    var picks = 0;
    var detaches = 0;
    // No playlist yet, so the chip presents the picker rather than a menu.
    await _pump(
      tester,
      InspirationChip(
        name: null,
        onPick: () => picks++,
        onDetach: () => detaches++,
      ),
    );

    await tester.tap(find.byKey(InspirationChip.chipKey));
    await tester.tap(find.byKey(InspirationChip.detachKey));

    expect(picks, 1);
    expect(detaches, 1);
    expect(played, [HapticKind.open, HapticKind.dismiss]);
  });

  testWidgets('the scrubber picks up and sets down, silent between', (
    tester,
  ) async {
    final played = recordHaptics(tester);
    final seeks = <double>[];
    await _pump(
      tester,
      SizedBox(
        width: 300,
        child: NowPlayingScrubber(
          positionMs: 0,
          durationMs: 200000,
          onSeek: seeks.add,
        ),
      ),
    );

    final target = find.byKey(NowPlayingScrubber.targetKey);
    final gesture = await tester.startGesture(tester.getCenter(target));
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(10, 0));
      await tester.pump();
    }
    await gesture.up();
    await tester.pump();

    expect(seeks, hasLength(1));
    expect(played, [HapticKind.select, HapticKind.select]);
  });
}
