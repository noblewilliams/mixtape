/// Dart's side of the native shell dock
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md` → Platform
/// differences).
///
/// The dock — a real `UITabBar` and a `UIGlassEffect` mini-player — is hosted
/// in the iOS window by `ios/Runner/ShellDock.swift` and only exists on
/// iOS 26. Everywhere else [isAvailable] is false and the Flutter
/// `FrostedDock` draws the same geometry, so every call here is a safe no-op
/// rather than an error to handle at each call site.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'mini_player_state.dart';

class ShellChannel {
  ShellChannel._(this._channel);

  /// The app-wide dock. One native dock exists, so one bridge speaks to it.
  static final ShellChannel instance = ShellChannel._(
    const MethodChannel(channelName),
  );

  /// A fresh, uncached bridge for tests — [isAvailable] memoises, and the
  /// singleton would carry one test's answer into the next.
  @visibleForTesting
  factory ShellChannel.forTesting({MethodChannel? channel}) =>
      ShellChannel._(channel ?? const MethodChannel(channelName));

  /// Fixed by the contract; `ShellDock.swift` names the same string.
  static const String channelName = 'mixtape/shell';

  final MethodChannel _channel;

  final _tabChanged = StreamController<int>.broadcast();
  final _miniPlayerTapped = StreamController<void>.broadcast();
  final _miniPlayerPlayPause = StreamController<void>.broadcast();
  final _miniPlayerNext = StreamController<void>.broadcast();
  final _reduceTransparencyChanged = StreamController<bool>.broadcast();

  bool _initialized = false;
  Future<bool>? _availability;

  /// The tab the listener tapped on the native bar.
  Stream<int> get onTabChanged => _tabChanged.stream;

  /// The mini-player was tapped anywhere but its two buttons: open the mix.
  Stream<void> get onMiniPlayerTapped => _miniPlayerTapped.stream;
  Stream<void> get onMiniPlayerPlayPause => _miniPlayerPlayPause.stream;
  Stream<void> get onMiniPlayerNext => _miniPlayerNext.stream;

  /// iOS's Reduce Transparency setting changed while the app was running.
  Stream<bool> get onReduceTransparencyChanged =>
      _reduceTransparencyChanged.stream;

  /// Start listening for the dock's callbacks. Idempotent.
  void init() {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'tabChanged':
          final index = call.arguments;
          if (index is int) _tabChanged.add(index);
        case 'miniPlayerTapped':
          _miniPlayerTapped.add(null);
        case 'miniPlayerPlayPause':
          _miniPlayerPlayPause.add(null);
        case 'miniPlayerNext':
          _miniPlayerNext.add(null);
        case 'reduceTransparencyChanged':
          final reduced = call.arguments;
          if (reduced is bool) _reduceTransparencyChanged.add(reduced);
      }
      return null;
    });
  }

  /// Highlight [index] on the native bar (Flutter drove the change).
  Future<void> setTab(int index) => _invoke('setTab', index);

  /// Reveal the dock at full size — leaving a mix, or returning to a tab.
  Future<void> show() => _invoke('show');

  /// Fade the dock away: a pushed route inside a mix owns the whole screen.
  Future<void> hide() => _invoke('hide');

  /// Shrink the tab bar to the board's minimised size on scroll, or restore
  /// it. Independent of [show] and [hide], which are route-level.
  Future<void> setMinimized(bool minimized) =>
      _invoke('setMinimized', minimized);

  /// Push what is playing into the native mini-player.
  Future<void> setMiniPlayer(MiniPlayerState state) =>
      _invoke('setMiniPlayer', state.toMap());

  /// The dock's glass resolves against the *system* appearance, so the app's
  /// resolved brightness has to be pushed down on every theme change.
  Future<void> setAppearance({required bool isDark}) =>
      _invoke('setAppearance', isDark);

  /// True only on iOS 26, where the native dock is installed. Asked once and
  /// memoised: the answer cannot change inside a process.
  Future<bool> get isAvailable => _availability ??= _resolveAvailability();

  Future<bool> _resolveAvailability() async {
    if (!_isIOS) return false;
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// iOS's Reduce Transparency setting right now. Read live — the listener can
  /// flip it in Settings while the app is backgrounded — and false off iOS,
  /// where `MediaQuery` already carries the platform's own answer.
  Future<bool> get reduceTransparency async {
    if (!_isIOS) return false;
    try {
      return await _channel.invokeMethod<bool>('getReduceTransparency') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// `defaultTargetPlatform` rather than `Platform.isIOS` so widget tests can
  /// exercise the bridge under `debugDefaultTargetPlatformOverride`.
  bool get _isIOS => defaultTargetPlatform == TargetPlatform.iOS;

  /// Sends [method]; swallows the absence of a dock. Below iOS 26 the channel
  /// is never registered, and a native argument complaint is the Flutter
  /// fallback's problem, not the caller's.
  Future<void> _invoke(String method, [Object? arguments]) async {
    if (!_isIOS) return;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on PlatformException {
      // The dock refused the call; the Flutter dock stays authoritative.
    } on MissingPluginException {
      // No dock on this OS version.
    }
  }

  @visibleForTesting
  void dispose() {
    _tabChanged.close();
    _miniPlayerTapped.close();
    _miniPlayerPlayPause.close();
    _miniPlayerNext.close();
    _reduceTransparencyChanged.close();
  }
}
