import 'energy_journey.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../providers/voice_providers.dart';
import '../theme/mixtape_theme.dart';
import 'foundation/prism_stripe.dart';
import 'foundation/text_action.dart';
import 'voice_level_meter.dart';

class MixPromptInput extends StatefulWidget {
  const MixPromptInput({
    super.key,
    required this.controller,
    required this.busy,
    required this.onSubmit,
    this.attachment,
    this.focusNode,
    this.placeholder,
    this.reservedExamples = const [],
    this.showVoiceInput = voiceInputEnabled,
    this.voiceController,
  });
  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSubmit;
  final Widget? attachment;

  /// The field's focus, when the owner needs it — Home's idea pills fill the
  /// field and focus it. Absent, the composer keeps one of its own.
  final FocusNode? focusNode;

  /// A fixed hint that replaces the rotating ones, and stops the rotation.
  ///
  /// Home's, while a playlist is attached: `Something like <name>, but…`
  /// (`docs/mockups/approved/2026-09-17-mobile-home-states.md` → Playlist
  /// attached).
  final String? placeholder;

  /// Placeholders the rotation must leave alone — Home's panel reserves the
  /// prompts its idea pills are showing, so the hint never repeats a pill
  /// sitting right below it.
  final List<String> reservedExamples;

  /// Draws the mic between the field and send. Defaults to the build flag;
  /// Phase 7.4 removes the flag.
  final bool showVoiceInput;

  /// The microphone's state. Left out, the composer takes the app's own from
  /// the Riverpod scope around it, so Home and a conversation share one
  /// microphone; tests hand one in directly.
  final VoiceComposerController? voiceController;

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

  /// The field's own vertical padding, tightened with its type (smoke round
  /// two, note 9).
  static const double fieldVerticalPadding = 9;

  /// How the field's type sits below body text — one step down.
  static const double fieldFontStepDown = 1;

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

  /// The microphone, once the tree has been walked for it.
  VoiceComposerController? _voice;

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
          // A fixed placeholder is the caller's, and does not rotate.
          widget.placeholder != null ||
          // A hint that changed under the level meter would be a second
          // thing moving while someone is talking.
          _listening ||
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindVoice();
  }

  /// The mic's state comes from the caller, or from the app's own provider
  /// when there is a scope to read it from — widget tests of the composer
  /// pump a bare `MaterialApp`, and a composer with no voice is just a
  /// composer with a dead mic, not a crash.
  void _bindVoice() {
    // No mic, no microphone: a composer that does not draw the key must not
    // hold state that could still be listening behind it.
    var next = widget.showVoiceInput ? widget.voiceController : null;
    if (next == null && widget.showVoiceInput) {
      if (_voiceFromScope && _voice != null) return;
      ProviderContainer? container;
      try {
        container = ProviderScope.containerOf(context, listen: false);
      } on StateError {
        // No scope: a composer pumped on its own in a widget test. A
        // provider that itself fails is not caught here.
        container = null;
      }
      if (container != null) {
        // Reading the provider can create it, and a provider created while
        // the framework is still building marks the scope dirty mid-build.
        // Bind a frame later instead; the mic is inert for that one frame.
        final scope = container;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted ||
              !widget.showVoiceInput ||
              widget.voiceController != null) {
            return;
          }
          _attachVoice(
            scope.read(voiceComposerControllerProvider),
            fromScope: true,
          );
          if (mounted) setState(() {});
        });
      }
      return;
    }
    _attachVoice(next, fromScope: false);
  }

  bool _voiceFromScope = false;

  void _attachVoice(VoiceComposerController? next, {required bool fromScope}) {
    if (next == _voice) return;
    _voice?.removeListener(_changed);
    _voice = next;
    _voiceFromScope = fromScope && next != null;
    _voice?.addListener(_changed);
  }

  bool get _listening =>
      _voice != null &&
      (_voice!.state == VoiceComposerState.listening ||
          _voice!.state == VoiceComposerState.transcribing);

  /// Open the microphone, or close it and land what was said.
  Future<void> _toggleVoice() async {
    final voice = _voice;
    if (voice == null || widget.busy) return;
    if (voice.state == VoiceComposerState.listening) {
      final transcript = await voice.stop();
      if (!mounted || transcript == null) return;
      _insert(transcript);
      return;
    }
    if (voice.busy) return;
    await voice.start();
  }

  /// Land a transcript where the cursor is, and hand the field back with the
  /// cursor after it. Nothing sends: it is a draft like any other.
  void _insert(String transcript) {
    final text = widget.controller.text;
    final selection = widget.controller.selection;
    final at = selection.isValid
        ? selection.end.clamp(0, text.length)
        : text.length;
    final before = text.substring(0, at);
    final after = text.substring(at);
    final opened = before.isNotEmpty && !before.endsWith(' ')
        ? ' $transcript'
        : transcript;
    // The cursor stays at the end of what was said, in front of the space
    // that keeps it apart from whatever the field already held.
    final cursor = before.length + opened.length;
    final closed = after.isNotEmpty && !after.startsWith(' ')
        ? '$opened '
        : opened;
    widget.controller.value = TextEditingValue(
      text: '$before$closed$after',
      selection: TextSelection.collapsed(offset: cursor),
    );
    _focus.requestFocus();
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
    if (oldWidget.voiceController != widget.voiceController ||
        oldWidget.showVoiceInput != widget.showVoiceInput) {
      final dropped = _voice;
      _bindVoice();
      if (dropped != null && dropped != _voice) unawaited(dropped.cancel());
    }
    // The composer locked while someone was talking — a mix is starting, or
    // the owner took the field away. The clip goes rather than the mic
    // staying open behind a field nobody can reach.
    if (widget.busy && !oldWidget.busy) unawaited(_voice?.cancel() ?? _idle);
  }

  static final Future<void> _idle = Future<void>.value();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _resumed = state == AppLifecycleState.resumed;

  @override
  void dispose() {
    _timer.cancel();
    // The screen is going: the microphone goes back with it, and the clip
    // is thrown away rather than transcribed into a field that is gone.
    final voice = _voice;
    _voice = null;
    voice?.removeListener(_changed);
    unawaited(voice?.cancel() ?? Future<void>.value());
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
    final voice = _voice;
    final listening = _listening;
    final transcribing = voice?.state == VoiceComposerState.transcribing;
    // The board shows the composer lit while the mic is open, even though the
    // field itself is out of the tree and holds no focus.
    final focused = _focus.hasFocus || listening;
    final failure = voice?.failure;

    final fieldStyle = tokens.body.copyWith(
      fontSize: (tokens.body.fontSize ?? 16) - MixPromptInput.fieldFontStepDown,
    );

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
      style: fieldStyle,
      decoration: InputDecoration(
        hintText: widget.placeholder ?? _rotation[_example % _rotation.length],
        hintStyle: fieldStyle.copyWith(color: tokens.muted),
        counterText: '',
        isDense: true,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: const EdgeInsets.symmetric(
          vertical: MixPromptInput.fieldVerticalPadding,
        ),
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
                    child: listening
                        ? _listeningLine(tokens, transcribing: transcribing)
                        : field,
                  ),
                ),
                if (widget.showVoiceInput)
                  _iconKey(
                    key: const Key('voice-input'),
                    tooltip: listening ? 'Stop listening' : 'Speak your idea',
                    onPressed: widget.busy || transcribing
                        ? null
                        : () => unawaited(_toggleVoice()),
                    child: Icon(
                      listening ? Icons.pause : Icons.mic_none,
                      size: 18,
                      color: listening ? tokens.errInk : tokens.plum,
                    ),
                  ),
                // Nothing to send, nothing drawn: the key arrives beside the
                // mic with the first character (smoke round two, note 9).
                if (hasText || widget.busy)
                  _iconKey(
                    key: const Key('start-session'),
                    tooltip: 'Start new mix',
                    onPressed: widget.busy || listening || !hasText
                        ? null
                        : _submit,
                    child: widget.busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : DecoratedBox(
                            key: const Key('send-surface'),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.12)
                                  : tokens.plum.withValues(alpha: 0.10),
                              borderRadius: _sendRadius,
                            ),
                            child: SizedBox.square(
                              dimension: 30,
                              child: Center(
                                child: Icon(
                                  Icons.arrow_upward,
                                  size: 18,
                                  color: tokens.plum,
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
          if (failure != null && widget.showVoiceInput)
            _failureLine(tokens, voice!, failure),
        ],
      ),
    );
  }

  /// What the field says while the mic is open: the board's prism meter and
  /// one word of state, in plum.
  Widget _listeningLine(MixtapeTokens tokens, {required bool transcribing}) =>
      Semantics(
        container: true,
        label: transcribing ? 'Transcribing' : 'Listening',
        excludeSemantics: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              VoiceLevelMeter(level: _voice?.level ?? 0),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  transcribing ? 'Transcribing…' : 'Listening…',
                  style: tokens.body.copyWith(color: tokens.plum),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      );

  /// The one sentence a failed attempt leaves under the field, and — for a
  /// microphone only Settings can give back — the way there.
  Widget _failureLine(
    MixtapeTokens tokens,
    VoiceComposerController voice,
    VoiceInputException failure,
  ) => Padding(
    padding: const EdgeInsets.only(top: 10, left: 2, right: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline, size: 16, color: tokens.errInk),
        const SizedBox(width: 8),
        Expanded(
          child: Semantics(
            key: const Key('voice-failure'),
            container: true,
            liveRegion: true,
            label: failure.message,
            child: ExcludeSemantics(
              child: Text(
                failure.message,
                style: tokens.secondary.copyWith(color: tokens.errInk),
              ),
            ),
          ),
        ),
        if (failure.failure == VoiceInputFailure.permissionDenied &&
            voice.settingsAvailable)
          TextAction(
            label: 'Open Settings',
            onPressed: () => unawaited(voice.openSettings()),
          ),
      ],
    ),
  );

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
