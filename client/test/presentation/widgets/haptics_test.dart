import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/widgets/foundation/haptics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const native = MethodChannel(Haptics.channelName);

  late List<MethodCall> nativeCalls;
  late List<String> fallbackCalls;

  setUp(() {
    nativeCalls = [];
    fallbackCalls = [];
    Haptics.debugReset(debounce: Duration.zero);
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        fallbackCalls.add(call.arguments as String);
      }
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(native, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    Haptics.debugReset();
  });

  void answerNatively() {
    messenger.setMockMethodCallHandler(native, (call) async {
      nativeCalls.add(call);
      return null;
    });
  }

  test('every kind has a native pattern and a built-in fallback', () {
    for (final kind in HapticKind.values) {
      expect(Haptics.patternOf(kind), isNotNull, reason: '$kind');
    }
  });

  test('the vocabulary is varied, not one buzz for everything', () {
    final native = HapticKind.values
        .map(
          (k) =>
              '${Haptics.patternOf(k).style}@${Haptics.patternOf(k).intensity}',
        )
        .toSet();
    final fallback = HapticKind.values
        .map((k) => Haptics.patternOf(k).fallback)
        .toSet();
    // Each kind feels different natively; the built-in set has fewer
    // patterns, so some kinds share one there.
    expect(native, hasLength(HapticKind.values.length));
    expect(fallback.length, greaterThanOrEqualTo(6));
  });

  test('plays the native pattern with its style and intensity', () async {
    answerNatively();
    await Haptics.play(HapticKind.open);

    expect(nativeCalls.single.method, 'play');
    expect(nativeCalls.single.arguments, {
      'kind': 'open',
      'style': 'soft',
      'intensity': Haptics.patternOf(HapticKind.open).intensity,
    });
    expect(fallbackCalls, isEmpty);
  });

  test(
    'falls back to the built-in pattern on a binary without the bridge',
    () async {
      await Haptics.play(HapticKind.primary);
      await Haptics.play(HapticKind.select);
      await Haptics.play(HapticKind.destructive);

      expect(fallbackCalls, [
        'HapticFeedbackType.mediumImpact',
        'HapticFeedbackType.selectionClick',
        'HapticFeedbackType.warningNotification',
      ]);
    },
  );

  test('a second haptic inside the debounce window is dropped', () async {
    var now = DateTime(2026, 11, 21);
    Haptics.debugReset(clock: () => now);
    answerNatively();

    await Haptics.play(HapticKind.primary);
    now = now.add(const Duration(milliseconds: 30));
    await Haptics.play(HapticKind.open);
    now = now.add(const Duration(milliseconds: 200));
    await Haptics.play(HapticKind.tap);

    expect(nativeCalls.map((c) => (c.arguments as Map)['kind']), [
      'primary',
      'tap',
    ]);
  });

  test('on() keeps null callbacks null so disabled controls stay disabled', () {
    expect(Haptics.on(HapticKind.tap, null), isNull);
  });

  test('on() plays before running the callback', () async {
    answerNatively();
    final order = <String>[];
    messenger.setMockMethodCallHandler(native, (call) async {
      order.add('haptic');
      return null;
    });
    Haptics.on(HapticKind.tap, () => order.add('action'))!();
    await Future<void>.delayed(Duration.zero);
    expect(order, ['haptic', 'action']);
  });
}
