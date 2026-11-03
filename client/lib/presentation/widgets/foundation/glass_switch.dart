/// A native `UISwitch` wherever the Liquid Glass dock is (iOS 26), so a
/// toggle wears the system's glass thumb — the shorter track and the lens that
/// swells under a finger — rather than Flutter's drawing of an older switch
/// (founder, 2026-11-03). Everywhere else it is [Switch.adaptive].
///
/// The native view is hosted like [LiquidGlassSurface]'s, behind the same
/// availability answer; `NativeSwitchViewFactory` in `ShellDock.swift` is its
/// other half.
library;

import 'package:flutter/foundation.dart'
    show Factory, TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter/gestures.dart' show EagerGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

import '../../../data/shell/shell_channel.dart';
import 'liquid_glass_surface.dart' show LiquidGlassSurface;

class GlassSwitch extends StatefulWidget {
  const GlassSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.channel,
  });

  final bool value;

  /// Null disables the switch, as with [Switch].
  final ValueChanged<bool>? onChanged;

  /// The bridge that answers whether the native dock — and so iOS 26 — is
  /// there. Defaults to the app-wide [ShellChannel]; tests inject their own.
  final ShellChannel? channel;

  /// Must match `NativeSwitchViewFactory`'s registration in `AppDelegate`.
  static const String viewType = 'mixtape/native_switch';

  /// The iOS 26 switch's own size, which the row lays out around.
  static const Size switchSize = Size(64, 28);

  /// The native view's frame: the switch centred with room to spare, since
  /// the glass thumb grows past the track while it is held.
  static const Size hostSize = Size(96, 52);

  /// The availability answer is cached for the life of the process, which a
  /// second test would otherwise inherit.
  @visibleForTesting
  static void resetAvailabilityForTests() {
    _GlassSwitchState._nativeAvailable = null;
  }

  @override
  State<GlassSwitch> createState() => _GlassSwitchState();
}

class _GlassSwitchState extends State<GlassSwitch> {
  /// Resolved once through the shell channel, then shared by every instance.
  static bool? _nativeAvailable;

  MethodChannel? _native;

  /// What the native switch is showing, so a value the parent refused (a
  /// failed save, a disabled row) is pushed back to it.
  bool? _shown;

  @override
  void initState() {
    super.initState();
    if (_nativeAvailable != null) return;
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      _nativeAvailable = false;
      return;
    }
    (widget.channel ?? ShellChannel.instance).isAvailable.then((available) {
      _nativeAvailable = available;
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(GlassSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.onChanged == null) != (widget.onChanged == null)) {
      _native?.invokeMethod<void>('setEnabled', {
        'enabled': widget.onChanged != null,
      });
    }
    _sync();
  }

  @override
  void dispose() {
    _native?.setMethodCallHandler(null);
    super.dispose();
  }

  void _created(int id) {
    _native?.setMethodCallHandler(null);
    _native = MethodChannel('${GlassSwitch.viewType}_$id')
      ..setMethodCallHandler(_handle);
    _shown = widget.value;
  }

  Future<void> _handle(MethodCall call) async {
    if (call.method != 'valueChanged') return;
    final value = (call.arguments as Map)['value'] as bool;
    _shown = value;
    widget.onChanged?.call(value);
    // Once the parent has had its say, the native switch shows its answer.
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => _sync())
      ..ensureVisualUpdate();
  }

  void _sync() {
    if (!mounted || _native == null || _shown == widget.value) return;
    _shown = widget.value;
    _native!.invokeMethod<void>('setValue', {
      'value': widget.value,
      'animated': true,
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_nativeAvailable != true) {
      return Switch.adaptive(value: widget.value, onChanged: widget.onChanged);
    }

    // The switch resolves its colours against the iOS *system* appearance,
    // so the app's own brightness is handed over at creation, as the glass
    // surface does.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox.fromSize(
      size: GlassSwitch.switchSize,
      child: OverflowBox(
        maxWidth: GlassSwitch.hostSize.width,
        maxHeight: GlassSwitch.hostSize.height,
        child: SizedBox.fromSize(
          size: GlassSwitch.hostSize,
          child: UiKitView(
            key: ValueKey<bool>(isDark),
            viewType: GlassSwitch.viewType,
            hitTestBehavior: PlatformViewHitTestBehavior.opaque,
            // Claimed at touch-down, so the thumb swells under the finger
            // instead of waiting for the arena to settle on a tap.
            gestureRecognizers: {
              Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new),
            },
            creationParams: <String, Object?>{
              'value': widget.value,
              'enabled': widget.onChanged != null,
              'isDark': isDark,
            },
            creationParamsCodec: const StandardMessageCodec(),
            onPlatformViewCreated: _created,
          ),
        ),
      ),
    );
  }
}
