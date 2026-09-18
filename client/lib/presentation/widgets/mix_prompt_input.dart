import 'energy_journey.dart';
import 'dart:async';
import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../theme/mixtape_theme.dart';
import 'foundation/prism_stripe.dart';

class MixPromptInput extends StatefulWidget {
  const MixPromptInput({
    super.key,
    required this.controller,
    required this.busy,
    required this.onSubmit,
    this.attachment,
    this.focusNode,
    this.reservedExamples = const [],
    this.showVoiceInput = voiceInputEnabled,
  });
  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSubmit;
  final Widget? attachment;

  /// The field's focus, when the owner needs it — Home's idea pills fill the
  /// field and focus it. Absent, the composer keeps one of its own.
  final FocusNode? focusNode;

  /// Placeholders the rotation must leave alone — Home's panel reserves the
  /// prompts its idea pills are showing, so the hint never repeats a pill
  /// sitting right below it.
  final List<String> reservedExamples;

  /// Draws the mic between the field and send. Defaults to the build flag;
  /// Phase 7 turns the flag on and gives the mic its behaviour.
  final bool showVoiceInput;

  /// The rotating placeholders, in order.
  ///
  /// Public so Home's panel can draw its starter pills from the same list
  /// (plan task 3.2) instead of inventing a second set of prompts.
  static const List<String> examples = [
    'A slow Sunday morning',
    'High-energy songs for my workout',
    'Dinner with friends, soft vocals',
    'More like my favourite soul songs',
    'A rainy drive home',
    'Instrumentals to help me focus',
  ];

  /// The placeholder a fresh composer opens on — the one Home's starter pills
  /// leave out, so a pill never repeats the hint beside it.
  static String get initialPlaceholder => examples.first;

  @override
  State<MixPromptInput> createState() => _MixPromptInputState();
}

class _MixPromptInputState extends State<MixPromptInput>
    with WidgetsBindingObserver {
  static const _examples = MixPromptInput.examples;

  /// The composer's own shape: 12 pt top corners, 16 pt bottom.
  static const BorderRadius _fieldRadius = BorderRadius.only(
    topLeft: Radius.circular(MixtapeMetrics.composerRadiusTop),
    topRight: Radius.circular(MixtapeMetrics.composerRadiusTop),
    bottomLeft: Radius.circular(MixtapeMetrics.composerRadiusBottom),
    bottomRight: Radius.circular(MixtapeMetrics.composerRadiusBottom),
  );

  /// The focus ring sits 2 pt outside the field, so its corners grow by 2.
  static const BorderRadius _ringRadius = BorderRadius.only(
    topLeft: Radius.circular(MixtapeMetrics.composerRadiusTop + 2),
    topRight: Radius.circular(MixtapeMetrics.composerRadiusTop + 2),
    bottomLeft: Radius.circular(MixtapeMetrics.composerRadiusBottom + 2),
    bottomRight: Radius.circular(MixtapeMetrics.composerRadiusBottom + 2),
  );

  /// The send key's inner surface: the square motif, shrunk.
  static const BorderRadius _sendRadius = BorderRadius.only(
    topLeft: Radius.circular(8),
    topRight: Radius.circular(8),
    bottomLeft: Radius.circular(10),
    bottomRight: Radius.circular(10),
  );

  /// Only built when the owner did not hand one down, and only disposed then.
  FocusNode? _ownFocus;
  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());
  late final Timer _timer;
  int _example = 0;
  bool _resumed = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resumed =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    widget.controller.addListener(_changed);
    _focus.addListener(_changed);
    _timer = Timer.periodic(const Duration(milliseconds: 4500), (_) {
      if (!mounted ||
          !_resumed ||
          widget.busy ||
          _focus.hasFocus ||
          widget.controller.text.isNotEmpty ||
          MediaQuery.disableAnimationsOf(context) ||
          !(ModalRoute.of(context)?.isCurrent ?? true)) {
        return;
      }
      setState(() => _example = (_example + 1) % _rotation.length);
    });
  }

  /// The placeholders left once the pills have taken theirs. Everything is
  /// reserved only if a caller reserves the whole list, in which case the
  /// hint falls back to rotating them all rather than showing nothing.
  List<String> get _rotation {
    final free = [
      for (final example in _examples)
        if (!widget.reservedExamples.contains(example)) example,
    ];
    return free.isEmpty ? _examples : free;
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(MixPromptInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _ownFocus)?.removeListener(_changed);
      _focus.addListener(_changed);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _resumed = state == AppLifecycleState.resumed;

  @override
  void dispose() {
    _timer.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_changed);
    _focus.removeListener(_changed);
    _ownFocus?.dispose();
    super.dispose();
  }

  void _submit() {
    if (!widget.busy && widget.controller.text.trim().isNotEmpty) {
      widget.onSubmit();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (theme.extension<MixtapeTokens>() != null) return _composer(context);
    // TEMPORARY: screens still on the pre-token theme (and their tests) build
    // a bare MaterialApp; give the composer's subtree the tokens it reads.
    // Remove once the screen tests pump MixtapeTheme (Phase 3).
    return Theme(
      data: theme.copyWith(
        extensions: [
          ...theme.extensions.values,
          theme.brightness == Brightness.dark
              ? MixtapeTokens.dark
              : MixtapeTokens.light,
        ],
      ),
      child: Builder(builder: _composer),
    );
  }

  Widget _composer(BuildContext context) {
    final tokens = context.tokens;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasText = widget.controller.text.trim().isNotEmpty;
    final focused = _focus.hasFocus;

    final field = TextField(
      key: const Key('prompt-field'),
      controller: widget.controller,
      focusNode: _focus,
      readOnly: widget.busy,
      minLines: 1,
      maxLines: 3,
      maxLength: 2000,
      textInputAction: TextInputAction.send,
      onSubmitted: (_) => _submit(),
      cursorColor: tokens.plum,
      style: tokens.body,
      decoration: InputDecoration(
        hintText: _rotation[_example % _rotation.length],
        hintStyle: tokens.body.copyWith(color: tokens.muted),
        counterText: '',
        isDense: true,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
      ),
    );

    final surface = ClipRRect(
      borderRadius: _fieldRadius,
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 2, 4, 2),
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: field,
                  ),
                ),
                if (widget.showVoiceInput)
                  _iconKey(
                    key: const Key('voice-input'),
                    tooltip: 'Speak your idea',
                    onPressed: widget.busy ? null : () {},
                    child: Icon(Icons.mic_none, size: 18, color: tokens.plum),
                  ),
                _iconKey(
                  key: const Key('start-session'),
                  tooltip: 'Start new mix',
                  onPressed: widget.busy || !hasText ? null : _submit,
                  child: widget.busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : DecoratedBox(
                          key: const Key('send-surface'),
                          decoration: BoxDecoration(
                            color: hasText
                                ? (isDark
                                      ? Colors.white.withValues(alpha: 0.12)
                                      : tokens.plum.withValues(alpha: 0.10))
                                : Colors.transparent,
                            borderRadius: _sendRadius,
                          ),
                          child: SizedBox.square(
                            dimension: 30,
                            child: Center(
                              child: Icon(
                                Icons.arrow_upward,
                                size: 18,
                                color: hasText ? tokens.plum : tokens.muted,
                              ),
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
          // The board's `inset 0 1px 0` top highlight.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 1,
              color: Colors.white.withValues(alpha: isDark ? 0.06 : 0.7),
            ),
          ),
          // The stripe fades out under focus rather than leaving the tree:
          // changing the composer's structure would reparent the field and
          // cost it the keyboard.
          Positioned(
            left: 8,
            top: 0,
            bottom: 0,
            child: Center(
              child: Opacity(
                key: const Key('prompt-stripe'),
                opacity: focused ? 0 : 1,
                child: const PrismStripe(),
              ),
            ),
          ),
        ],
      ),
    );

    return Semantics(
      label: 'Describe your new mix',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.attachment != null) widget.attachment!,
          EnergyControl(controller: widget.controller, enabled: !widget.busy),
          Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              gradient: focused ? tokens.prismGradient() : null,
              borderRadius: _ringRadius,
            ),
            child: Container(
              constraints: const BoxConstraints(
                minHeight: MixtapeMetrics.composerHeight,
              ),
              decoration: BoxDecoration(
                color: tokens.field,
                borderRadius: _fieldRadius,
                border: Border.all(
                  color: focused ? Colors.transparent : tokens.hairline,
                ),
                boxShadow: [
                  BoxShadow(
                    color: tokens.glassShadow,
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: surface,
            ),
          ),
        ],
      ),
    );
  }

  /// A 40 pt key inside a 44 pt target, per the board's composer grid.
  ///
  /// [tooltip] is also the spoken label: Flutter's own tooltip semantics are a
  /// hint, not a name, so the key would otherwise be announced as "button".
  Widget _iconKey({
    required Key key,
    required String tooltip,
    required VoidCallback? onPressed,
    required Widget child,
  }) => SizedBox.square(
    dimension: MixtapeMetrics.minTarget,
    child: IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(
        minWidth: MixtapeMetrics.minTarget,
        minHeight: MixtapeMetrics.minTarget,
      ),
      // Inside the button, so the label merges into its node instead of
      // sitting beside it.
      icon: Semantics(label: tooltip, child: child),
    ),
  );
}
