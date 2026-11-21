/// The app's haptic vocabulary: every touch plays one, and what it plays
/// depends on what the touch does (`docs/decisions.md` → Haptics).
///
/// Call sites name the action ([HapticKind]), never a raw pattern, so the
/// feel of the whole app is tuned in one table ([Haptics.patternOf]).
///
/// Two tiers. The `mixtape/haptics` bridge in `ios/Runner/AppDelegate.swift`
/// plays the full palette (soft and rigid impacts at any intensity, the
/// notification patterns). A binary without the bridge (one a Shorebird
/// patch lands on, or Android) gets Flutter's built-in patterns instead,
/// where some kinds share a feel.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What a touch does, which decides how it feels. Ordered from the lightest
/// touch to the heaviest.
enum HapticKind {
  /// Choosing among peers: a tab, a segment, an option in a sheet or menu,
  /// a chip turning on or off.
  select,

  /// Closing or backing out: Cancel, a scrim tap, a sheet's close.
  dismiss,

  /// An ordinary tap that goes somewhere: a row, Back, a text link, an
  /// icon button.
  tap,

  /// Presenting something on top: a sheet, a menu, a dialog, a picker.
  open,

  /// A switch flipping.
  toggle,

  /// Tapping one of the DJ's recommendations: an idea pill, a routine
  /// suggestion, a playlist inspiration.
  suggest,

  /// A long press that lifts something up (a context menu, a drag).
  lift,

  /// A gesture crossing its commit point: a swipe arming, a pull revealing.
  threshold,

  /// A call to action: Continue, Play, Save, Share, a tape button.
  primary,

  /// The big one: sending the prompt that makes a mix, playing it now,
  /// creating the playlist.
  commit,

  /// Confirming something that removes or ends: Delete, Archive, Sign out.
  destructive,

  /// A touch whose result is an immediate success (Copied, Saved).
  success,

  /// A touch that could not do what it asked.
  error,
}

/// The iOS generator the native bridge plays.
enum HapticStyle {
  selection,
  light,
  medium,
  heavy,
  soft,
  rigid,
  success,
  warning,
  error,
}

/// Flutter's built-in patterns, for binaries without the bridge.
enum HapticFallback { selection, light, medium, heavy, success, warning, error }

@immutable
class HapticPattern {
  const HapticPattern(this.style, this.intensity, this.fallback);

  final HapticStyle style;

  /// 0–1, for the impact styles. Ignored by selection and the notifications.
  final double intensity;
  final HapticFallback fallback;
}

abstract final class Haptics {
  /// Fixed by the contract; `AppDelegate.swift` names the same string.
  static const String channelName = 'mixtape/haptics';
  static const MethodChannel _channel = MethodChannel(channelName);

  /// The whole feel of the app. Natively every kind is distinct; the
  /// fallback column collapses them onto Flutter's seven patterns.
  static const Map<HapticKind, HapticPattern> _patterns = {
    HapticKind.select: HapticPattern(
      HapticStyle.selection,
      1,
      HapticFallback.selection,
    ),
    HapticKind.dismiss: HapticPattern(
      HapticStyle.soft,
      0.45,
      HapticFallback.selection,
    ),
    HapticKind.tap: HapticPattern(HapticStyle.light, 0.6, HapticFallback.light),
    HapticKind.open: HapticPattern(HapticStyle.soft, 0.8, HapticFallback.light),
    HapticKind.toggle: HapticPattern(
      HapticStyle.rigid,
      0.6,
      HapticFallback.light,
    ),
    HapticKind.suggest: HapticPattern(
      HapticStyle.soft,
      1,
      HapticFallback.medium,
    ),
    HapticKind.lift: HapticPattern(
      HapticStyle.medium,
      0.7,
      HapticFallback.medium,
    ),
    HapticKind.threshold: HapticPattern(
      HapticStyle.rigid,
      1,
      HapticFallback.medium,
    ),
    HapticKind.primary: HapticPattern(
      HapticStyle.medium,
      0.9,
      HapticFallback.medium,
    ),
    HapticKind.commit: HapticPattern(
      HapticStyle.heavy,
      0.85,
      HapticFallback.heavy,
    ),
    HapticKind.destructive: HapticPattern(
      HapticStyle.warning,
      1,
      HapticFallback.warning,
    ),
    HapticKind.success: HapticPattern(
      HapticStyle.success,
      1,
      HapticFallback.success,
    ),
    HapticKind.error: HapticPattern(HapticStyle.error, 1, HapticFallback.error),
  };

  static HapticPattern patternOf(HapticKind kind) => _patterns[kind]!;

  /// One touch, one haptic: when a control and the thing it opens both ask
  /// (a button that presents a sheet), the first one in this window wins.
  static Duration _debounce = const Duration(milliseconds: 80);
  static DateTime Function() _clock = DateTime.now;
  static DateTime? _lastPlayed;

  /// Null until the first play answers; false once the bridge is missing,
  /// so later plays go straight to the fallback.
  static bool? _nativeAvailable;

  /// Plays [kind]. Never throws and never needs awaiting: a haptic that
  /// cannot play is simply not felt.
  static Future<void> play(HapticKind kind) async {
    final now = _clock();
    final last = _lastPlayed;
    if (last != null && now.difference(last) < _debounce) return;
    _lastPlayed = now;

    final pattern = patternOf(kind);
    if (_nativeAvailable != false) {
      try {
        await _channel.invokeMethod<void>('play', {
          'kind': kind.name,
          'style': pattern.style.name,
          'intensity': pattern.intensity,
        });
        _nativeAvailable = true;
        return;
      } on MissingPluginException {
        _nativeAvailable = false;
      } on PlatformException {
        // Fall through to the built-in pattern for this one touch.
      }
    }
    try {
      await _playFallback(pattern.fallback);
    } on PlatformException {
      // Not felt; nothing to recover.
    }
  }

  /// Wraps [action] so it plays [kind] first. Keeps a null action null, so a
  /// disabled control stays disabled (`onPressed: Haptics.on(...)`).
  static VoidCallback? on(HapticKind kind, VoidCallback? action) {
    if (action == null) return null;
    return () {
      unawaited(play(kind));
      action();
    };
  }

  /// [on] for callbacks that take a value (`onChanged`, `onSelected`).
  static ValueChanged<T>? onValue<T>(HapticKind kind, ValueChanged<T>? action) {
    if (action == null) return null;
    return (value) {
      unawaited(play(kind));
      action(value);
    };
  }

  static Future<void> _playFallback(HapticFallback fallback) =>
      switch (fallback) {
        HapticFallback.selection => HapticFeedback.selectionClick(),
        HapticFallback.light => HapticFeedback.lightImpact(),
        HapticFallback.medium => HapticFeedback.mediumImpact(),
        HapticFallback.heavy => HapticFeedback.heavyImpact(),
        HapticFallback.success => HapticFeedback.successNotification(),
        HapticFallback.warning => HapticFeedback.warningNotification(),
        HapticFallback.error => HapticFeedback.errorNotification(),
      };

  /// Back to a fresh state between tests.
  @visibleForTesting
  static void debugReset({
    Duration debounce = const Duration(milliseconds: 80),
    DateTime Function() clock = DateTime.now,
  }) {
    _debounce = debounce;
    _clock = clock;
    _lastPlayed = null;
    _nativeAvailable = null;
  }
}
