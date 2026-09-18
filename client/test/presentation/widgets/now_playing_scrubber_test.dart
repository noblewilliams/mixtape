import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/theme/mixtape_theme.dart';
import 'package:mixtape/presentation/widgets/now_playing_scrubber.dart';

Future<void> _pump(
  WidgetTester tester, {
  required double positionMs,
  required int durationMs,
  ValueChanged<double>? onSeek,
  double textScale = 1,
  double width = 390,
}) async {
  tester.view.physicalSize = Size(width, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: MixtapeTheme.dark(),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: Scaffold(
            body: Center(
              child: NowPlayingScrubber(
                positionMs: positionMs,
                durationMs: durationMs,
                onSeek: onSeek,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

double _widthFactor(WidgetTester tester) => tester
    .widget<FractionallySizedBox>(find.byKey(NowPlayingScrubber.fillKey))
    .widthFactor!;

/// A scrubber whose position and seek support can change under a live drag,
/// the way the player screen's own selector feeds it.
class _Host extends StatefulWidget {
  const _Host({super.key});
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  double positionMs = 0;
  bool seekable = true;

  void tick(double ms) => setState(() => positionMs = ms);
  void freeze() => setState(() => seekable = false);

  @override
  Widget build(BuildContext context) => NowPlayingScrubber(
    positionMs: positionMs,
    durationMs: 240000,
    onSeek: seekable ? (_) {} : null,
  );
}

final _host = GlobalKey<_HostState>();

Future<void> _pumpHost(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: MixtapeTheme.dark(),
      home: Scaffold(body: Center(child: _Host(key: _host))),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('the fill is the played fraction of the song', (tester) async {
    await _pump(tester, positionMs: 84000, durationMs: 235000);
    expect(_widthFactor(tester), closeTo(84000 / 235000, 0.0001));
  });

  testWidgets('elapsed and remaining read as clock times', (tester) async {
    await _pump(tester, positionMs: 84000, durationMs: 235000);
    expect(find.text('1:24'), findsOneWidget);
    expect(find.text('-2:31'), findsOneWidget);
  });

  testWidgets('an unknown duration is an empty, quiet bar', (tester) async {
    await _pump(tester, positionMs: 84000, durationMs: 0);
    expect(_widthFactor(tester), 0);
    expect(find.text('0:00'), findsOneWidget);
    expect(find.text('-0:00'), findsOneWidget);
  });

  testWidgets('a position past the end never overfills the bar', (
    tester,
  ) async {
    await _pump(tester, positionMs: 300000, durationMs: 235000);
    expect(_widthFactor(tester), 1);
    expect(find.text('-0:00'), findsOneWidget);
  });

  testWidgets('a drag seeks to where the finger let go', (tester) async {
    final seeks = <double>[];
    await _pump(
      tester,
      positionMs: 0,
      durationMs: 240000,
      onSeek: seeks.add,
    );
    final bar = tester.getRect(find.byKey(NowPlayingScrubber.barKey));
    await tester.dragFrom(
      Offset(bar.left + 1, bar.center.dy),
      Offset(bar.width / 2, 0),
    );
    await tester.pump();
    expect(seeks, hasLength(1));
    // Half the bar of a four-minute song is two minutes in.
    expect(seeks.single, closeTo(120, 3));
  });

  testWidgets('the label follows the finger before the seek lands', (
    tester,
  ) async {
    await _pump(tester, positionMs: 0, durationMs: 240000, onSeek: (_) {});
    final bar = tester.getRect(find.byKey(NowPlayingScrubber.barKey));
    final gesture = await tester.startGesture(
      Offset(bar.left + 1, bar.center.dy),
    );
    await gesture.moveBy(Offset(bar.width / 2, 0));
    await tester.pump();
    expect(_widthFactor(tester), closeTo(0.5, 0.02));
    expect(find.text('2:00'), findsOneWidget);
    await gesture.up();
    await tester.pump();
  });

  testWidgets('the position ticking on does not move the finger', (
    tester,
  ) async {
    await _pumpHost(tester);
    final bar = tester.getRect(find.byKey(NowPlayingScrubber.barKey));
    final gesture = await tester.startGesture(
      Offset(bar.left + 1, bar.center.dy),
    );
    await gesture.moveBy(Offset(bar.width / 2, 0));
    await tester.pump();
    expect(find.text('2:00'), findsOneWidget);

    // The player keeps reporting its own position while the finger is down.
    _host.currentState!.tick(30000);
    await tester.pump();
    expect(_widthFactor(tester), closeTo(0.5, 0.02));
    expect(find.text('2:00'), findsOneWidget);

    await gesture.up();
    await tester.pump();
  });

  testWidgets('seeking going away mid-drag drops the draft', (tester) async {
    await _pumpHost(tester);
    final bar = tester.getRect(find.byKey(NowPlayingScrubber.barKey));
    final gesture = await tester.startGesture(
      Offset(bar.left + 1, bar.center.dy),
    );
    await gesture.moveBy(Offset(bar.width / 2, 0));
    await tester.pump();
    expect(_widthFactor(tester), closeTo(0.5, 0.02));

    // A command went in flight: the scrubber can no longer seek.
    _host.currentState!.freeze();
    await tester.pump();
    expect(_widthFactor(tester), 0);
    expect(find.text('0:00'), findsOneWidget);

    await gesture.up();
    await tester.pump();
  });

  testWidgets('without seek support the bar ignores gestures', (tester) async {
    await _pump(tester, positionMs: 60000, durationMs: 240000);
    final bar = tester.getRect(find.byKey(NowPlayingScrubber.barKey));
    await tester.dragFrom(
      Offset(bar.left + 1, bar.center.dy),
      Offset(bar.width / 2, 0),
    );
    await tester.pump();
    expect(_widthFactor(tester), closeTo(0.25, 0.0001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the bar keeps a 44 pt target and survives 200% text at 320', (
    tester,
  ) async {
    await _pump(
      tester,
      positionMs: 84000,
      durationMs: 235000,
      onSeek: (_) {},
      textScale: 2,
      width: 320,
    );
    expect(tester.takeException(), isNull);
    final target = tester.getRect(find.byKey(NowPlayingScrubber.targetKey));
    expect(target.height, greaterThanOrEqualTo(MixtapeMetrics.minTarget));
    expect(
      tester.getRect(find.byKey(NowPlayingScrubber.barKey)).height,
      NowPlayingScrubber.barHeight,
    );
  });
}
