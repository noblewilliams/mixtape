/// Home's bottom panel
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md` → Home;
/// `docs/mockups/approved/2026-09-17-mobile-home-states.md`; `.bpanel`,
/// `.grab`, `.pills` and `.errline` on the Home states board; plan tasks 3.1
/// and 3.2).
///
/// Glass inset from both screen edges, rounded on all four corners, with a
/// drag-handle glyph, holding the compact Mix | Album and Shape row (album
/// picks board H1 to H4), the composer, the start-failure line and at most
/// three idea pills of equal weight (or, after the album nudge, the line that
/// says so). It floats at the bottom of the screen
/// above the dock and rides the keyboard, so it is drawn outside the scroll
/// view Home's open space lives in.
library;

import 'package:flutter/material.dart';

import '../theme/mixtape_theme.dart';
import 'foundation/idea_pill.dart';
import 'foundation/liquid_glass_surface.dart';
import 'foundation/text_action.dart';
import 'mix_prompt_input.dart';
import 'routine_suggestions.dart';

/// One of the three pills a playlist attachment turns the idea pills into
/// (`docs/mockups/approved/2026-09-17-mobile-home-states.md` → Playlist
/// attached; frame W2).
class HomeRefinement {
  const HomeRefinement(this.label, {this.onTap});

  final String label;

  /// What the pill does instead of filling the field — "without its songs"
  /// flips the exclude flag rather than typing anything.
  final VoidCallback? onTap;
}

class HomePanel extends StatefulWidget {
  const HomePanel({
    super.key,
    required this.controller,
    required this.onSubmit,
    this.composerKey,
    this.focusNode,
    this.busy = false,
    this.error,
    this.attachment,
    this.starterPrompts = MixPromptInput.examples,
    this.placeholder,
    this.refinements,
    this.obscured = false,
    this.modeControl,
    this.shapeControl,
    this.sendLabel = MixPromptInput.defaultSendLabel,
    this.routineSuggestion = true,
    this.switched = false,
    this.onKeepMix,
  });

  /// The row above the composer (album picks board H1): the Mix | Album
  /// control at the leading edge and the compact Shape chip trailing. Either
  /// may be absent (no control for an anonymous listener or with albums off;
  /// no chip under Album); with neither there is no row.
  final Widget? modeControl;
  final Widget? shapeControl;

  /// The send key's name ("Find an album" under Album).
  final String sendLabel;

  /// Whether the routine suggestion may take the first pill. Under Album the
  /// three album starters stand alone.
  final bool routineSuggestion;

  /// The album nudge just moved the control: the "Switched to Album" line
  /// replaces the pills until send, with [onKeepMix] as the way back.
  final bool switched;
  final VoidCallback? onKeepMix;

  /// The composer's draft, which the pills fill.
  final TextEditingController controller;

  /// Send. Pills never reach it.
  final VoidCallback onSubmit;

  /// Put on the [MixPromptInput] itself, so Home can measure the composer for
  /// the playlist picker's anchor.
  final Key? composerKey;

  /// The field's focus, so a pill can put the caret where it just typed.
  final FocusNode? focusNode;

  /// A mix is being created: the composer locks and the pills go inert.
  final bool busy;

  /// The start-failure message, shown as the board's alert line.
  final String? error;

  /// The playlist attachment chip, drawn above the field by the composer.
  final Widget? attachment;

  /// Where the starter pills come from — the composer's own placeholders, so
  /// Home never invents a second set of prompts.
  final List<String> starterPrompts;

  /// The placeholder the composer shows instead of its rotating hints, which
  /// the starters also leave out. With a playlist attached the board reads
  /// `Something like <name>, but…`.
  final String? placeholder;

  /// With a playlist attached, the pills become refinements of it and the
  /// routine suggestion stands down — the board shows exactly three.
  final List<HomeRefinement>? refinements;

  /// A modal route is over Home (smoke round four, note 2). The panel fades
  /// out rather than showing its top edge and handle above the sheet under the
  /// scrim, and gives up its native glass while it is gone: a `UiKitView`
  /// composites above a route barrier and would punch a hole in the dim.
  final bool obscured;

  /// How long the panel takes to go and come back. Instant under reduced
  /// motion.
  static const Duration veilDuration = Duration(milliseconds: 120);

  /// The fade itself, for tests.
  static const Key veilKey = Key('home-panel-veil');

  /// The board's `.bpanel` top radius.
  static const double topRadius = 30;

  /// The panel floats: it is inset from both screen edges and rounded on all
  /// four corners (smoke round two, note 5).
  static const double sideInset = 12;
  static const double floatingRadius = 32;

  /// `.bpanel` side padding.
  static const double sidePadding = 14;

  /// The gap between the panel and the dock below it.
  static const double dockGap = 8;

  /// `.bpanel.kb`: the gap the panel keeps above the keyboard.
  static const double keyboardGap = 14;

  /// `.grab`.
  static const double handleWidth = 36;
  static const double handleHeight = 5;
  static const Color handleColor = Color.fromRGBO(127, 120, 130, 0.45);

  /// `.pills`: 8 pt between pills on a row, 12 pt above the row.
  static const double pillGap = 8;

  /// The gap between pill rows. Now that pills shrink-wrap, three of them wrap
  /// onto three rows; 4 pt keeps them reading as one group rather than as a
  /// list (smoke round three, note 6).
  static const double pillRunGap = 4;

  static const double pillsTopGap = 12;

  /// The board never shows a fourth pill.
  static const int maxPills = 3;

  static const Key handleKey = Key('home-panel-handle');

  /// The compact row above the composer.
  static const Key modeRowKey = Key('home-panel-mode-row');

  /// Text scaling stops here on the compact row, as the Mixes toggle caps its
  /// labels. The compact control and chip grow their drawn height with the
  /// scale up to this cap: 26 pt at 1x, 32 pt at 1.5x and beyond (a 28 pt
  /// segment in a 32 pt track), still 44 pt to touch.
  static const double modeRowMaxTextScale = 1.5;

  /// The nudge line and its way back (board H3).
  static const Key switchedKey = Key('home-panel-switched');
  static const Key keepMixKey = Key('home-panel-keep-mix');
  static const String switchedText = 'Switched to Album for this prompt.';
  static const String keepMixLabel = 'Keep it a mix';

  /// The glass itself, so a test can measure where the panel sits.
  static const Key surfaceKey = Key('home-panel-surface');
  static const Key pillsKey = Key('home-panel-pills');

  /// The failure line, keyed as the pre-native error was.
  static const Key errorKey = Key('start-error');

  static Key starterPillKey(int index) => ValueKey('home-panel-starter-$index');

  static Key refinementPillKey(int index) =>
      ValueKey('home-panel-refinement-$index');

  @override
  State<HomePanel> createState() => _HomePanelState();
}

class _HomePanelState extends State<HomePanel> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(HomePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  /// The pills dim on the first character and undim on the last.
  void _changed() {
    if (mounted) setState(() {});
  }

  /// A pill replaces the draft and leaves the caret at its end, focused and
  /// unsent.
  void _fill(String text) {
    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    widget.focusNode?.requestFocus();
  }

  /// The first three placeholders that are not the one the field is showing.
  List<String> get _starters => [
    for (final prompt in widget.starterPrompts)
      if (prompt != (widget.placeholder ?? MixPromptInput.initialPlaceholder))
        prompt,
  ].take(HomePanel.maxPills).toList();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    // Over the keyboard when it is up — the dock stays behind it, and the
    // shell owns that. Otherwise clear of the dock's own inset.
    final bottom = keyboard > 0
        ? keyboard + HomePanel.keyboardGap
        : media.padding.bottom + HomePanel.dockGap;

    final dimmed = widget.busy || widget.controller.text.trim().isNotEmpty;
    final starters = _starters;
    final error = widget.error;
    final hasRow = widget.modeControl != null || widget.shapeControl != null;

    return ConstrainedBox(
      // At 200% text with the keyboard up the panel wants more room than the
      // phone has; capped here, its content scrolls inside instead of
      // climbing off the top of the screen.
      constraints: BoxConstraints(
        maxHeight: (media.size.height - media.padding.top).clamp(
          0.0,
          double.infinity,
        ),
      ),
      child: Padding(
        // The dock relationship is unchanged: the gap below still comes out
        // of the panel's own bottom padding.
        padding: const EdgeInsets.symmetric(horizontal: HomePanel.sideInset),
        child: AnimatedOpacity(
          key: HomePanel.veilKey,
          opacity: widget.obscured ? 0 : 1,
          duration: media.disableAnimations
              ? Duration.zero
              : HomePanel.veilDuration,
          child: LiquidGlassSurface(
            key: HomePanel.surfaceKey,
            borderRadius: BorderRadius.circular(HomePanel.floatingRadius),
            fallbackBlurSigma: 30,
            fallbackTint: tokens.panel,
            allowNative: !widget.obscured,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                HomePanel.sidePadding,
                8,
                HomePanel.sidePadding,
                bottom,
              ),
              // The panel's own overflow is its own business: a scroll in here
              // must not minimise the shell's dock.
              child: NotificationListener<ScrollNotification>(
                onNotification: (_) => true,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          key: HomePanel.handleKey,
                          width: HomePanel.handleWidth,
                          height: HomePanel.handleHeight,
                          // With the row below it, its invisible 9 pt hit
                          // band supplies most of the board's 12 pt gap.
                          margin: EdgeInsets.only(
                            top: 2,
                            bottom: hasRow ? 4 : 12,
                          ),
                          decoration: const BoxDecoration(
                            color: HomePanel.handleColor,
                            borderRadius: BorderRadius.all(Radius.circular(3)),
                          ),
                        ),
                      ),
                      if (hasRow) _modeRow(),
                      MixPromptInput(
                        key: widget.composerKey,
                        controller: widget.controller,
                        focusNode: widget.focusNode,
                        busy: widget.busy,
                        onSubmit: widget.onSubmit,
                        attachment: widget.attachment,
                        placeholder: widget.placeholder,
                        sendLabel: widget.sendLabel,
                        // The pills hold these; the rotating hint skips them so
                        // the field never repeats a pill below it. Refinements
                        // are not prompts, so they reserve nothing.
                        reservedExamples: widget.refinements == null
                            ? starters
                            : const [],
                      ),
                      if (error != null) _errorLine(tokens, error),
                      if (widget.switched)
                        _switchedLine(tokens)
                      else
                        Padding(
                          padding: const EdgeInsets.only(
                            top: HomePanel.pillsTopGap,
                          ),
                          // With a playlist attached the three pills are refinements
                          // of it, and no routine suggestion competes with them.
                          child: widget.refinements != null
                              ? _refinementPills(dimmed: dimmed)
                              : !widget.routineSuggestion
                              ? Wrap(
                                  key: HomePanel.pillsKey,
                                  spacing: HomePanel.pillGap,
                                  runSpacing: HomePanel.pillRunGap,
                                  children: [
                                    for (var i = 0; i < starters.length; i++)
                                      _starterPill(
                                        i,
                                        starters[i],
                                        dimmed: dimmed,
                                      ),
                                  ],
                                )
                              : RoutinePillSlot(
                                  onFill: _fill,
                                  dimmed: dimmed,
                                  enabled: !widget.busy,
                                  builder: (context, pill) {
                                    final shown = pill == null
                                        ? HomePanel.maxPills
                                        : HomePanel.maxPills - 1;
                                    return Wrap(
                                      key: HomePanel.pillsKey,
                                      spacing: HomePanel.pillGap,
                                      runSpacing: HomePanel.pillRunGap,
                                      children: [
                                        if (pill != null) pill,
                                        for (
                                          var i = 0;
                                          i < shown && i < starters.length;
                                          i++
                                        )
                                          _starterPill(
                                            i,
                                            starters[i],
                                            dimmed: dimmed,
                                          ),
                                      ],
                                    );
                                  },
                                ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The board's `.moderow`: the control leading, the chip trailing, one row
  /// tall enough for their 44 pt targets whichever of them is present, so
  /// nothing jumps when the chip leaves under Album.
  Widget _modeRow() => MediaQuery.withClampedTextScaling(
    maxScaleFactor: HomePanel.modeRowMaxTextScale,
    child: ConstrainedBox(
      key: HomePanel.modeRowKey,
      constraints: const BoxConstraints(minHeight: MixtapeMetrics.minTarget),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (widget.modeControl != null) Flexible(child: widget.modeControl!),
          if (widget.modeControl != null && widget.shapeControl != null)
            const SizedBox(width: 8),
          if (widget.shapeControl != null)
            Flexible(child: widget.shapeControl!),
        ],
      ),
    ),
  );

  /// The board's `.switched` line (H3): what the nudge did and the one-tap
  /// way back, announced politely once as it appears.
  Widget _switchedLine(MixtapeTokens tokens) => Semantics(
    key: HomePanel.switchedKey,
    container: true,
    liveRegion: true,
    explicitChildNodes: true,
    label: HomePanel.switchedText,
    child: Padding(
      // The board's `.switched` margin-top.
      padding: const EdgeInsets.only(top: 8, left: 2),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ExcludeSemantics(
            child: Text(
              HomePanel.switchedText,
              style: tokens.secondary.copyWith(color: tokens.smoke),
            ),
          ),
          TextAction(
            key: HomePanel.keepMixKey,
            label: HomePanel.keepMixLabel,
            onPressed: widget.busy ? null : widget.onKeepMix,
          ),
        ],
      ),
    ),
  );

  /// The attached playlist's three refinements, in the board's order.
  Widget _refinementPills({required bool dimmed}) => Wrap(
    key: HomePanel.pillsKey,
    spacing: HomePanel.pillGap,
    runSpacing: HomePanel.pillRunGap,
    children: [
      for (var i = 0; i < widget.refinements!.length; i++)
        IdeaPill(
          key: HomePanel.refinementPillKey(i),
          label: widget.refinements![i].label,
          dimmed: dimmed,
          onPressed: widget.busy
              ? null
              : (widget.refinements![i].onTap ??
                    () => _fill(widget.refinements![i].label)),
        ),
    ],
  );

  Widget _starterPill(int index, String prompt, {required bool dimmed}) =>
      IdeaPill(
        key: HomePanel.starterPillKey(index),
        label: prompt,
        dimmed: dimmed,
        onPressed: widget.busy ? null : () => _fill(prompt),
      );

  /// The board's `.errline`: an error circle and the message in err ink,
  /// announced the moment it appears.
  Widget _errorLine(MixtapeTokens tokens, String message) => Semantics(
    key: HomePanel.errorKey,
    container: true,
    liveRegion: true,
    label: message,
    child: ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.only(top: 10, left: 2, right: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, size: 16, color: tokens.errInk),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: tokens.secondary.copyWith(color: tokens.errInk),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
