import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/shell/mini_player_state.dart';
import 'package:mixtape/data/shell/shell_channel.dart';

TestDefaultBinaryMessenger get messenger =>
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(ShellChannel.channelName);
  late List<MethodCall> calls;

  void answer(Future<Object?>? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  Future<void> fromNative(String method, [Object? arguments]) =>
      messenger.handlePlatformMessage(
        ShellChannel.channelName,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall(method, arguments),
        ),
        (_) {},
      );

  setUp(() {
    calls = [];
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    answer((_) async => null);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('Flutter to native', () {
    test('every command sends its method and arguments', () async {
      final shell = ShellChannel.forTesting();

      await shell.setTab(2);
      await shell.show();
      await shell.hide();
      await shell.setMinimized(true);
      await shell.setAppearance(isDark: true);

      expect(calls.map((c) => c.method).toList(), [
        'setTab',
        'show',
        'hide',
        'setMinimized',
        'setAppearance',
      ]);
      expect(calls[0].arguments, 2);
      expect(calls[1].arguments, isNull);
      expect(calls[3].arguments, true);
      expect(calls[4].arguments, true);
    });

    test('setMiniPlayer sends the state as a map', () async {
      final shell = ShellChannel.forTesting();

      await shell.setMiniPlayer(
        const MiniPlayerState(
          visible: true,
          title: 'Late kitchen',
          artist: 'Khruangbin',
          artworkUrl: 'https://art.example/1.jpg',
          playing: true,
        ),
      );

      expect(calls.single.method, 'setMiniPlayer');
      expect(calls.single.arguments, {
        'visible': true,
        'title': 'Late kitchen',
        'artist': 'Khruangbin',
        'artworkUrl': 'https://art.example/1.jpg',
        'playing': true,
        'unavailable': false,
      });
    });

    test('hidden state carries empty text and no artwork', () {
      const hidden = MiniPlayerState.hidden();

      expect(hidden.toMap(), {
        'visible': false,
        'title': '',
        'artist': '',
        'artworkUrl': null,
        'playing': false,
        'unavailable': false,
      });
      expect(hidden, const MiniPlayerState(visible: false));
      expect(
        hidden.hashCode,
        const MiniPlayerState(visible: false).hashCode,
      );
      expect(hidden, isNot(const MiniPlayerState(visible: true)));
    });

    test('a native error leaves the caller unharmed', () async {
      answer((_) async => throw PlatformException(code: 'INVALID_INDEX'));
      final shell = ShellChannel.forTesting();

      await expectLater(shell.setTab(9), completes);
      await expectLater(shell.setMinimized(true), completes);
      await expectLater(
        shell.setMiniPlayer(const MiniPlayerState.hidden()),
        completes,
      );
    });

    test('nothing is sent off iOS', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final shell = ShellChannel.forTesting();

      await shell.setTab(1);
      await shell.show();

      expect(calls, isEmpty);
      expect(await shell.isAvailable, isFalse);
      expect(await shell.reduceTransparency, isFalse);
    });
  });

  group('availability', () {
    test('true when the dock answers, and cached', () async {
      answer((call) async => call.method == 'isAvailable' ? true : null);
      final shell = ShellChannel.forTesting();

      expect(await shell.isAvailable, isTrue);
      expect(await shell.isAvailable, isTrue);
      expect(calls.where((c) => c.method == 'isAvailable'), hasLength(1));
    });

    test('false when the channel is unregistered', () async {
      answer((_) async => throw MissingPluginException('no dock'));
      final shell = ShellChannel.forTesting();

      expect(await shell.isAvailable, isFalse);
    });

    test('false when the dock reports an error', () async {
      answer((_) async => throw PlatformException(code: 'boom'));
      final shell = ShellChannel.forTesting();

      expect(await shell.isAvailable, isFalse);
    });

    test('reduce transparency is read live, not cached', () async {
      var reduced = true;
      answer(
        (call) async => call.method == 'getReduceTransparency' ? reduced : null,
      );
      final shell = ShellChannel.forTesting();

      expect(await shell.reduceTransparency, isTrue);
      reduced = false;
      expect(await shell.reduceTransparency, isFalse);
      expect(
        calls.where((c) => c.method == 'getReduceTransparency'),
        hasLength(2),
      );
    });
  });

  group('native to Flutter', () {
    test('every callback surfaces on its stream', () async {
      final shell = ShellChannel.forTesting()..init();
      addTearDown(shell.dispose);

      final tabs = <int>[];
      final transparency = <bool>[];
      var taps = 0;
      var playPauses = 0;
      var nexts = 0;
      shell.onTabChanged.listen(tabs.add);
      shell.onMiniPlayerTapped.listen((_) => taps++);
      shell.onMiniPlayerPlayPause.listen((_) => playPauses++);
      shell.onMiniPlayerNext.listen((_) => nexts++);
      shell.onReduceTransparencyChanged.listen(transparency.add);

      await fromNative('tabChanged', 3);
      await fromNative('miniPlayerTapped');
      await fromNative('miniPlayerPlayPause');
      await fromNative('miniPlayerNext');
      await fromNative('reduceTransparencyChanged', true);
      await pumpEventQueue();

      expect(tabs, [3]);
      expect(taps, 1);
      expect(playPauses, 1);
      expect(nexts, 1);
      expect(transparency, [true]);
    });

    test('init is idempotent and an unknown call is ignored', () async {
      final shell = ShellChannel.forTesting()
        ..init()
        ..init();
      addTearDown(shell.dispose);

      final tabs = <int>[];
      shell.onTabChanged.listen(tabs.add);

      await fromNative('tabChanged', 1);
      await fromNative('somethingElse');
      await pumpEventQueue();

      expect(tabs, [1]);
    });
  });
}
