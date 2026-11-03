// The native Liquid Glass switch (`glass_switch.dart`): a hosted UISwitch
// where the iOS 26 dock is, Flutter's adaptive switch everywhere else.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/shell/shell_channel.dart';
import 'package:mixtape/presentation/widgets/foundation/glass_switch.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  setUp(GlassSwitch.resetAvailabilityForTests);
  tearDown(GlassSwitch.resetAvailabilityForTests);

  testWidgets('off iOS it is the adaptive switch, and taps reach onChanged', (
    tester,
  ) async {
    final changes = <bool>[];
    await tester.pumpWidget(
      _host(GlassSwitch(value: false, onChanged: changes.add)),
    );
    expect(find.byType(UiKitView), findsNothing);
    await tester.tap(find.byType(Switch));
    expect(changes, [true]);
  });

  group('with the iOS 26 dock', () {
    const shell = MethodChannel('glass-switch-test-shell');
    final creations = <Map<Object?, Object?>>[];
    final nativeCalls = <MethodCall>[];

    setUp(() {
      creations.clear();
      nativeCalls.clear();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(shell, (call) async => true);
      messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
        call,
      ) async {
        if (call.method == 'create') {
          final args = call.arguments as Map<Object?, Object?>;
          creations.add(args);
          messenger.setMockMethodCallHandler(
            MethodChannel('${GlassSwitch.viewType}_${args['id']}'),
            (call) async => nativeCalls.add(call),
          );
        }
        return null;
      });
    });

    final ios = TargetPlatformVariant.only(TargetPlatform.iOS);

    Future<void> pumpSwitch(
      WidgetTester tester, {
      required bool value,
      ValueChanged<bool>? onChanged,
    }) async {
      await tester.pumpWidget(
        _host(
          GlassSwitch(
            value: value,
            onChanged: onChanged,
            channel: ShellChannel.forTesting(channel: shell),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> nativeFlip(WidgetTester tester, bool value) async {
      final id = creations.single['id'];
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            '${GlassSwitch.viewType}_$id',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('valueChanged', {'value': value}),
            ),
            (_) {},
          );
      await tester.pumpAndSettle();
    }

    testWidgets('hosts the native switch at the iOS 26 size', (tester) async {
      await pumpSwitch(tester, value: true, onChanged: (_) {});
      expect(find.byType(Switch), findsNothing);
      expect(tester.getSize(find.byType(GlassSwitch)), GlassSwitch.switchSize);
      expect(creations.single['viewType'], GlassSwitch.viewType);
    }, variant: ios);

    testWidgets('a native flip reaches onChanged', (tester) async {
      final changes = <bool>[];
      await pumpSwitch(tester, value: false, onChanged: changes.add);
      await nativeFlip(tester, true);
      expect(changes, [true]);
      // The parent did not rebuild with the new value, so the switch is put
      // back to what the parent holds.
      expect(nativeCalls.single.method, 'setValue');
      expect((nativeCalls.single.arguments as Map)['value'], isFalse);
    }, variant: ios);

    testWidgets('a new value and a disabled state are pushed to the switch', (
      tester,
    ) async {
      await pumpSwitch(tester, value: false, onChanged: (_) {});
      await pumpSwitch(tester, value: true);
      expect(nativeCalls.map((c) => c.method), ['setEnabled', 'setValue']);
      expect((nativeCalls.first.arguments as Map)['enabled'], isFalse);
      expect((nativeCalls.last.arguments as Map)['value'], isTrue);
    }, variant: ios);
  });
}
