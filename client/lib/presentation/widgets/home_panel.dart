/// Home's bottom panel
/// (`docs/mockups/approved/2026-09-17-mobile-shell.md` → Home;
/// `docs/mockups/approved/2026-09-17-mobile-home-states.md`; `.bpanel`,
/// `.grab`, `.pills` and `.errline` on the Home states board; plan tasks 3.1
/// and 3.2).
///
/// Glass with a 30 pt top radius and a drag-handle glyph, holding the
/// composer, the start-failure line and at most three idea pills of equal
/// weight. It is anchored to the bottom of the screen above the dock and rides
/// the keyboard, so it is drawn outside the scroll view Home's open space
/// lives in.
library;

import 'package:flutter/material.dart';

import '../theme/mixtape_theme.dart';
import 'foundation/idea_pill.dart';
import 'foundation/liquid_glass_surface.dart';
import 'mix_prompt_input.dart';
import 'routine_suggestions.dart';

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
  });

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

  /// The placeholder the composer is showing, which the starters leave out.
  final String? placeholder;

  /// The board's `.bpanel` top radius.
  static const double topRadius = 30;

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

  /// `.pills`: 8 pt gaps, 12 pt above the row.
  static const double pillGap = 8;
  static const double pillsTopGap = 12;

  /// The board never shows a fourth pill.
  static const int maxPills = 3;

  static const Key handleKey = Key('home-panel-handle');
  static const Key pillsKey = Key('home-panel-pills');

  /// The failure line, keyed as the pre-native error was.
  static const Key errorKey = Key('start-error');

  static Key starterPillKey(int index) => ValueKey('home-panel-starter-$index');

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
      child: LiquidGlassSurface(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(HomePanel.topRadius),
        ),
        fallbackBlurSigma: 30,
        fallbackTint: tokens.panel,
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
                      margin: const EdgeInsets.only(top: 2, bottom: 12),
                      decoration: const BoxDecoration(
                        color: HomePanel.handleColor,
                        borderRadius: BorderRadius.all(Radius.circular(3)),
                      ),
                    ),
                  ),
                  MixPromptInput(
                    key: widget.composerKey,
                    controller: widget.controller,
                    focusNode: widget.focusNode,
                    busy: widget.busy,
                    onSubmit: widget.onSubmit,
                    attachment: widget.attachment,
                    // The pills hold these; the rotating hint skips them so
                    // the field never repeats a pill below it.
                    reservedExamples: starters,
                  ),
                  if (error != null) _errorLine(tokens, error),
                  Padding(
                    padding: const EdgeInsets.only(top: HomePanel.pillsTopGap),
                    // The routine suggestion owns the first slot; with nothing
                    // eligible the two known starters stay where they are and a
                    // third joins them at the end, so nothing moves when the
                    // routine resolves.
                    child: RoutinePillSlot(
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
                          runSpacing: HomePanel.pillGap,
                          children: [
                            if (pill != null) pill,
                            for (
                              var i = 0;
                              i < shown && i < starters.length;
                              i++
                            )
                              _starterPill(i, starters[i], dimmed: dimmed),
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
    );
  }

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
