import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/widgets/foundation/haptics.dart';

/// Answers the `mixtape/haptics` channel the way the native bridge would and
/// records which [HapticKind]s were played, in order.
///
/// Turns the debounce off for the test so two quick taps both count; the
/// debounce itself is covered in `haptics_test.dart`.
List<HapticKind> recordHaptics(WidgetTester tester) {
  final played = <HapticKind>[];
  Haptics.debugReset(debounce: Duration.zero);
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel(Haptics.channelName),
    (call) async {
      final args = call.arguments as Map<Object?, Object?>;
      played.add(HapticKind.values.byName(args['kind']! as String));
      return null;
    },
  );
  addTearDown(() {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(Haptics.channelName),
      null,
    );
    Haptics.debugReset();
  });
  return played;
}
