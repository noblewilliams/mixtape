/// A native `UISegmentedControl` wherever the Liquid Glass dock is (iOS 26),
/// so the Mixes toggle wears the system's glass — the thumb that turns to a
/// lens under a finger and slides like the dock's — rather than a drawn pill
/// (founder, 2026-11-09). Everywhere else, and whenever something covers it,
/// it is the house [SegmentedToggle].
///
/// Hosted like [GlassSwitch]: `NativeSegmentedViewFactory` in
/// `ShellDock.swift` is the other half, behind the same availability answer.
library;

import 'package:flutter/foundation.dart'
    show Factory, TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter/gestures.dart' show EagerGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:flutter/services.dart';

import '../../../data/shell/shell_channel.dart';
import 'glass_occlusion.dart';
import 'segmented_toggle.dart';

class GlassSegmentedControl<T> extends StatefulWidget {
  const GlassSegmentedControl({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.channel,
  }) : assert(options.length > 1, 'a toggle needs at least two segments');

  final List<SegmentedOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;

  /// The bridge that answers whether the native dock — and so iOS 26 — is
  /// there. Defaults to the app-wide [ShellChannel]; tests inject their own.
  final ShellChannel? channel;

  /// Must match `NativeSegmentedViewFactory`'s registration in `AppDelegate`.
  static const String viewType = 'mixtape/native_segmented';

  /// The control's drawn height at 1x.
  static const double height = 36;

  /// Each segment's padding either side of its label.
  static const double segmentPadding = 18;

  /// The label size, which the native side is told so the two agree.
  static const double fontSize = 13;

  /// Labels stop growing here, as `UISegmentedControl` in a title row does.
  static const double maxTextScale = 1.3;

  /// Room around the control inside the native view: the glass thumb swells
  /// past the track while it is held, and a platform view clips to its frame.
  static const EdgeInsets lensRoom = EdgeInsets.symmetric(
    horizontal: 10,
    vertical: 10,
  );

  /// The width that holds every label at [scaler], in equal segments.
  static double widthFor(
    BuildContext context,
    List<String> labels, {
    TextScaler? scaler,
  }) {
    final textScaler =
        scaler ??
        MediaQuery.textScalerOf(context).clamp(maxScaleFactor: maxTextScale);
    final style = DefaultTextStyle.of(context).style.merge(
      const TextStyle(fontSize: fontSize, fontWeight: FontWeight.w600),
    );
    var widest = 0.0;
    for (final label in labels) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: style),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
        maxLines: 1,
      )..layout();
      if (painter.width > widest) widest = painter.width;
      painter.dispose();
    }
    return labels.length * (widest.ceilToDouble() + 2 * segmentPadding);
  }

  /// The availability answer is cached for the life of the process, which a
  /// second test would otherwise inherit.
  @visibleForTesting
  static void resetAvailabilityForTests() {
    _GlassSegmentedControlState._nativeAvailable = null;
  }

  @override
  State<GlassSegmentedControl<T>> createState() =>
      _GlassSegmentedControlState<T>();
}

class _GlassSegmentedControlState<T> extends State<GlassSegmentedControl<T>> {
  /// Resolved once through the shell channel, then shared by every instance.
  static bool? _nativeAvailable;

  MethodChannel? _native;

  /// The index the native control is showing, so a value the parent refused
  /// is pushed back to it.
  int? _shown;

  bool _covered = false;

  int get _selected {
    final index = widget.options.indexWhere((o) => o.value == widget.value);
    return index < 0 ? 0 : index;
  }

  List<String> get _labels => [for (final o in widget.options) o.label];

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    GlassOcclusion.changes.removeListener(_occlusionChanged);
    GlassOcclusion.changes.addListener(_occlusionChanged);
  }

  @override
  void didUpdateWidget(GlassSegmentedControl<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    GlassOcclusion.changes.removeListener(_occlusionChanged);
    _native?.setMethodCallHandler(null);
    super.dispose();
  }

  void _occlusionChanged() {
    if (!mounted || _nativeAvailable != true) return;
    final covered = GlassOcclusion.isCovered(context);
    if (covered == _covered) return;
    // A navigator can report a route while it builds; rebuild after it.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  void _created(int id) {
    _native?.setMethodCallHandler(null);
    _native = MethodChannel('${GlassSegmentedControl.viewType}_$id')
      ..setMethodCallHandler(_handle);
    _shown = _selected;
  }

  Future<void> _handle(MethodCall call) async {
    if (call.method != 'valueChanged') return;
    final index = (call.arguments as Map)['index'] as int;
    if (index < 0 || index >= widget.options.length) return;
    _shown = index;
    widget.onChanged(widget.options[index].value);
    // Once the parent has had its say, the native control shows its answer.
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => _sync())
      ..ensureVisualUpdate();
  }

  void _sync() {
    if (!mounted || _native == null || _shown == _selected) return;
    _shown = _selected;
    _native!.invokeMethod<void>('setSelected', {
      'index': _selected,
      'animated': true,
    });
  }

  @override
  Widget build(BuildContext context) {
    final current = ModalRoute.of(context)?.isCurrent ?? true;
    _covered = _nativeAvailable == true && GlassOcclusion.isCovered(context);
    if (_nativeAvailable != true || !current || _covered) {
      // The view goes when the fallback takes over; a fresh one is made, and
      // told the value, when it comes back.
      _native?.setMethodCallHandler(null);
      _native = null;
      return SegmentedToggle<T>(
        options: widget.options,
        value: widget.value,
        onChanged: widget.onChanged,
      );
    }

    final scaler = MediaQuery.textScalerOf(
      context,
    ).clamp(maxScaleFactor: GlassSegmentedControl.maxTextScale);
    final scale =
        scaler.scale(GlassSegmentedControl.fontSize) /
        GlassSegmentedControl.fontSize;
    final width = GlassSegmentedControl.widthFor(
      context,
      _labels,
      scaler: scaler,
    );
    final height = GlassSegmentedControl.height + (scale - 1) * 12;
    const room = GlassSegmentedControl.lensRoom;
    // The control resolves its colours against the iOS *system* appearance,
    // so the app's own brightness is handed over at creation.
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // VoiceOver reads the native control's own segments.
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: -room.left,
            right: -room.right,
            top: -room.top,
            bottom: -room.bottom,
            child: UiKitView(
              // Creation params are read once: a theme flip or new labels
              // build a fresh view.
              key: ValueKey<String>('$isDark-${_labels.join('|')}'),
              viewType: GlassSegmentedControl.viewType,
              hitTestBehavior: PlatformViewHitTestBehavior.opaque,
              // Claimed at touch-down, so the thumb swells under the finger
              // instead of waiting for the arena to settle on a tap.
              gestureRecognizers: {
                Factory<EagerGestureRecognizer>(EagerGestureRecognizer.new),
              },
              creationParams: <String, Object?>{
                'labels': _labels,
                'selected': _selected,
                'isDark': isDark,
                'fontSize': GlassSegmentedControl.fontSize * scale,
                'insetX': room.left,
                'insetY': room.top,
                'glass': true,
                'cornerRadius': height / 2,
              },
              creationParamsCodec: const StandardMessageCodec(),
              onPlatformViewCreated: _created,
            ),
          ),
        ],
      ),
    );
  }
}
