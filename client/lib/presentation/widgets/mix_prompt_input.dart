import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../providers/voice_providers.dart';
import '../theme/mixtape_theme.dart';
import 'ai_consent_sheet.dart';
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
    this.sendLabel = defaultSendLabel,
    this.reservedExamples = const [],
    this.exampleSet,
    this.showVoiceInput = voiceInputEnabled,
    this.voiceController,
    this.beforeVoice,
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

  /// The send key's tooltip and spoken name. Home names it "Find an album"
  /// under Album (album picks board H2).
  final String sendLabel;

  static const String defaultSendLabel = 'Start new mix';

  /// Placeholders the rotation must leave alone — Home's panel reserves the
  /// prompts its idea pills are showing, so the hint never repeats a pill
  /// sitting right below it.
  final List<String> reservedExamples;

  /// Rotating placeholders that replace [examples] — the first-run welcome
  /// rotates its own three (first-run spec, Copy).
  final List<String>? exampleSet;

  /// Draws the mic between the field and send. Defaults to the build flag;
  /// Phase 7.4 removes the flag.
  final bool showVoiceInput;

  /// The microphone's state. Left out, the composer takes the app's own from
  /// the Riverpod scope around it, so Home and a conversation share one
  /// microphone; tests hand one in directly.
  final VoiceComposerController? voiceController;

  /// What a mic tap waits on before recording; false leaves the mic closed.
  /// Left out, it is the AI-consent sheet. The first run passes its own,
  /// which also creates the anonymous listener the transcriber needs.
  final Future<bool> Function()? beforeVoice;

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
  /// two, note 9) and again when the field still read as mostly padding
  /// (device smoke, 2026-11-13).
  static const double fieldVerticalPadding = 6;

  /// How the field's type sits below body text — one step down.
  static const double fieldFontStepDown = 1;

  /// The surface's height with one line of draft (device smoke, 2026-11-13:
  /// down from the shared 48 pt composer height).
  static const double minHeight = 40;

  /// How many lines the draft grows to before it scrolls inside the field.
  static const int maxLines = 5;

  /// The mic and send keys: 36 pt wide, the surface's full height to touch.
  static const double keyWidth = 36;

  /// Where the draft starts, from the surface's leading edge.
  static const double textInset = 14;

  /// The prism underline: how far in from each side it stops (clear of the
  /// 16 pt bottom corners) and how thick it is.
  static const double stripeInset = 16;
  static const double stripeHeight = 2;

  /// The surface itself, for tests.
  static const Key surfaceKey = Key('prompt-surface');

  @override
  State<MixPromptInput> createState() => _MixPromptInputState();
}

class _MixPromptInputState extends State<MixPromptInput>
    with WidgetsBindingObserver {
  List<String> get _examples => widget.exampleSet ?? MixPromptInput.examples;

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
    _voice?.removeListener(_voiceChanged);
    _voice = next;
    _voiceFromScope = fromScope && next != null;
    _voice?.addListener(_voiceChanged);
  }

  /// The words heard so far go into the field as they arrive (device smoke,
  /// 2026-11-13), until the dictation lands or is given up.
  void _voiceChanged() {
    final voice = _voice;
    if (_dictating &&
        voice != null &&
        voice.busy &&
        voice.partial != _shownWords) {
      _showWords(voice.partial);
    }
    if (mounted) setState(() {});
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
      if (!mounted) return;
      // Nothing to land: the draft goes back to what it was before speaking.
      if (transcript == null) _endDictation(restore: true);
      if (transcript == null &&
          voice.failure?.failure == VoiceInputFailure.consentRequired) {
        // `/transcribe` wants AI consent: the sheet, not a failure line. The
        // clip is gone; what was typed stays. The next mic tap asks first.
        voice.clearFailure();
        await confirmAiConsentAfterRefusal(context);
        return;
      }
      if (transcript == null) return;
      _land(transcript);
      return;
    }
    if (voice.busy) return;
    // A clip goes to Groq, so the AI-consent sheet comes first when the
    // listener has not agreed; Not now leaves the mic closed.
    final gate = widget.beforeVoice ?? () => confirmAiConsent(context);
    if (!await gate() || !mounted) return;
    // The gate may have changed who is signed in, and with it the
    // controller: record on the one bound now.
    final current = _voice;
    if (current == null || current.busy || widget.busy) return;
    _beginDictation();
    await current.start();
    if (!mounted) return;
    if (current.state != VoiceComposerState.listening) {
      _endDictation(restore: true);
    }
  }

  /// A dictation under way: what the field held before and after the cursor
  /// when it began, and the words last drawn between them.
  bool _dictating = false;
  String _before = '';
  String _after = '';
  String _shownWords = '';

  /// The field's own scroll, so a dictation can keep its latest line in view
  /// while the field is not focused.
  final ScrollController _fieldScroll = ScrollController();

  /// The words will go where the cursor is. The keyboard goes while the
  /// listener speaks; the field is the microphone's until it lands.
  void _beginDictation() {
    final text = widget.controller.text;
    final selection = widget.controller.selection;
    final at = selection.isValid
        ? selection.end.clamp(0, text.length)
        : text.length;
    _before = text.substring(0, at);
    _after = text.substring(at);
    _shownWords = '';
    _dictating = true;
    _focus.unfocus();
  }

  /// The draft with [words] where the cursor was, a space either side where
  /// the field's own text would otherwise run into them, and the cursor
  /// after them (in front of the space that keeps them apart from what
  /// followed).
  TextEditingValue _compose(String words) {
    if (words.isEmpty) {
      return TextEditingValue(
        text: '$_before$_after',
        selection: TextSelection.collapsed(offset: _before.length),
      );
    }
    final opened = _before.isNotEmpty && !_before.endsWith(' ')
        ? ' $words'
        : words;
    final cursor = _before.length + opened.length;
    final closed = _after.isNotEmpty && !_after.startsWith(' ')
        ? '$opened '
        : opened;
    return TextEditingValue(
      text: '$_before$closed$_after',
      selection: TextSelection.collapsed(offset: cursor),
    );
  }

  void _showWords(String words) {
    _shownWords = words;
    widget.controller.value = _compose(words);
    _followLatest();
  }

  /// Land a transcript where the cursor was, and hand the field back with the
  /// cursor after it. Nothing sends: it is a draft like any other.
  void _land(String transcript) {
    widget.controller.value = _compose(transcript);
    _dictating = false;
    _shownWords = '';
    _focus.requestFocus();
    _followLatest();
  }

  /// The dictation is over without a transcript. With [restore], words it
  /// drew are taken back out; a field it never wrote into is left alone.
  void _endDictation({required bool restore}) {
    if (!_dictating) return;
    if (restore && _shownWords.isNotEmpty) {
      widget.controller.value = _compose('');
    }
    _dictating = false;
    _shownWords = '';
  }

  /// Keep the latest line in view as words arrive (device smoke, 2026-11-13:
  /// a long dictation sat on its first line with the rest out of sight).
  /// Only when the words end the draft: words dropped mid-text leave the
  /// view where the cursor is.
  void _followLatest() {
    if (_after.isNotEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_fieldScroll.hasClients) return;
      final position = _fieldScroll.position;
      if (position.pixels != position.maxScrollExtent) {
        _fieldScroll.jumpTo(position.maxScrollExtent);
      }
    });
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
    if (widget.busy && !oldWidget.busy) {
      unawaited(_voice?.cancel() ?? _idle);
      _endDictation(restore: true);
    }
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
    voice?.removeListener(_voiceChanged);
    unawaited(voice?.cancel() ?? Future<void>.value());
    _fieldScroll.dispose();
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
    // field gives up its focus (and the keyboard) while the listener speaks.
    final focused = _focus.hasFocus || listening;
    final failure = voice?.failure;

    final fieldStyle = tokens.body.copyWith(
      fontSize: (tokens.body.fontSize ?? 16) - MixPromptInput.fieldFontStepDown,
    );

    final field = TextField(
      key: const Key('prompt-field'),
      controller: widget.controller,
      focusNode: _focus,
      // Read-only while the microphone is writing into it.
      readOnly: widget.busy || listening,
      scrollController: _fieldScroll,
      minLines: 1,
      maxLines: MixPromptInput.maxLines,
      maxLength: 2000,
      textInputAction: TextInputAction.send,
      onSubmitted: (_) => _submit(),
      // A tap anywhere else puts the keyboard away: iOS text fields do not
      // do it on their own (device smoke, 2026-11-13). The composer's own
      // keys and anything an owner wraps in a [TextFieldTapRegion] (Home's
      // pills) count as the field, so they keep it.
      onTapOutside: (_) => _focus.unfocus(),
      cursorColor: tokens.plum,
      // The words heard live wait in muted ink while the better pass over
      // them is on its way, then land at full ink.
      style: transcribing
          ? fieldStyle.copyWith(color: tokens.muted)
          : fieldStyle,
      decoration: InputDecoration(
        hint: Text(
          listening
              ? (transcribing ? 'Transcribing…' : 'Listening…')
              : widget.placeholder ?? _rotation[_example % _rotation.length],
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
        ),
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

    // The row's own height inside the 1 pt border: the keys fill it, and a
    // single line of draft is centred in it.
    const rowHeight = MixPromptInput.minHeight - 4;

    final surface = ClipRRect(
      borderRadius: _fieldRadius,
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              MixPromptInput.textInset - 1,
              1,
              1,
              1,
            ),
            // The keys sit at the foot of a long draft, as Messages' do.
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: rowHeight),
                    // The field stays while the microphone is open: the words
                    // stream into it (device smoke, 2026-11-13).
                    child: Align(alignment: Alignment.centerLeft, child: field),
                  ),
                ),
                // While the DJ works the composer is a plain field: the
                // working cassette in the transcript (or Home's starting
                // state) already says so, and a second spinner in the send
                // key said it twice (device smoke, 2026-11-13).
                if (!widget.busy)
                  TextFieldTapRegion(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.showVoiceInput && listening)
                          _meter(transcribing: transcribing),
                        if (widget.showVoiceInput)
                          _iconKey(
                            key: const Key('voice-input'),
                            tooltip: listening
                                ? 'Stop listening'
                                : 'Speak your idea',
                            onPressed: transcribing
                                ? null
                                : () => unawaited(_toggleVoice()),
                            child: Icon(
                              listening ? Icons.pause : Icons.mic_none,
                              size: 18,
                              color: listening ? tokens.errInk : tokens.plum,
                            ),
                          ),
                        // Nothing to send, nothing drawn: the key arrives
                        // beside the mic with the first character (smoke
                        // round two, note 9).
                        // No send while the microphone is writing either.
                        if (hasText && !listening)
                          _iconKey(
                            key: const Key('start-session'),
                            tooltip: widget.sendLabel,
                            onPressed: _submit,
                            child: DecoratedBox(
                              key: const Key('send-surface'),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? Colors.white.withValues(alpha: 0.12)
                                    : tokens.plum.withValues(alpha: 0.10),
                                borderRadius: _sendRadius,
                              ),
                              child: SizedBox.square(
                                dimension: 28,
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
          // The prism along the bottom edge, as the tape buttons wear it,
          // clear of the rounded corners (device smoke, 2026-11-13: the
          // upright stripe sat cramped against the draft once the padding
          // went). Focus hands it to the full prism ring. It fades rather
          // than leaving the tree: changing the composer's structure would
          // reparent the field and cost it the keyboard.
          Positioned(
            left: MixPromptInput.stripeInset,
            right: MixPromptInput.stripeInset,
            bottom: 0,
            child: Opacity(
              key: const Key('prompt-stripe'),
              opacity: focused ? 0 : 0.85,
              child: const PrismStripe(
                horizontal: true,
                width: double.infinity,
                height: MixPromptInput.stripeHeight,
                borderRadius: BorderRadius.all(Radius.circular(1)),
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
          // In line with the field's edge, inside its 2 pt focus ring.
          if (widget.attachment != null)
            Padding(
              padding: const EdgeInsets.only(left: 2),
              child: widget.attachment,
            ),
          Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              gradient: focused ? tokens.prismGradient() : null,
              borderRadius: _ringRadius,
            ),
            child: Container(
              key: MixPromptInput.surfaceKey,
              constraints: const BoxConstraints(
                minHeight: MixPromptInput.minHeight,
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

  /// The board's prism meter, beside the key that stops the microphone, and
  /// the word VoiceOver hears for where the dictation is.
  Widget _meter({required bool transcribing}) => Semantics(
    container: true,
    liveRegion: true,
    label: transcribing ? 'Transcribing' : 'Listening',
    excludeSemantics: true,
    child: Padding(
      padding: const EdgeInsets.only(left: 6, right: 2),
      child: VoiceLevelMeter(level: _voice?.level ?? 0),
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

  /// A key [MixPromptInput.keyWidth] wide and the row's full height, at the
  /// surface's trailing edge (device smoke, 2026-11-13: down from 44 pt
  /// squares, which left the draft little room).
  ///
  /// [tooltip] is also the spoken label: Flutter's own tooltip semantics are a
  /// hint, not a name, so the key would otherwise be announced as "button".
  Widget _iconKey({
    required Key key,
    required String tooltip,
    required VoidCallback? onPressed,
    required Widget child,
  }) => SizedBox(
    width: MixPromptInput.keyWidth,
    height: MixPromptInput.minHeight - 4,
    child: IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(
        minWidth: MixPromptInput.keyWidth,
        minHeight: MixPromptInput.minHeight - 4,
      ),
      // Inside the button, so the label merges into its node instead of
      // sitting beside it.
      icon: Semantics(label: tooltip, child: child),
    ),
  );
}
