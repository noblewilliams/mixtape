/// Who do you love? (board frames A3 and A4).
///
/// Three plain artist fields, each becoming a chip once entered. Continue
/// enables at three. It writes the seeds a corpus mix needs through
/// `/me/artist-seeds` (creating the anonymous listener lazily), then sends
/// the prompt from Welcome; reached without one (Skip for now, I've requested
/// it), it goes on to the prompt page instead.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../theme/mixtape_theme.dart';
import '../../providers/keep_mixes_provider.dart' show KeptPrompt;
import '../../widgets/keep_sheet.dart';
import 'first_run_flow.dart';
import 'step_scaffold.dart';
import 'welcome_screen.dart';

class ArtistsScreen extends ConsumerStatefulWidget {
  const ArtistsScreen({super.key, this.prompt});

  /// The prompt typed on Welcome, sent once the seeds are saved. Null when
  /// the listener came here before asking for anything.
  final String? prompt;

  static const String headline = 'Who do you love?';
  static const String line =
      'Three artists is enough. The DJ borrows from the shared catalogue '
      'until your music is in.';
  static const List<String> placeholders = [
    'First artist',
    'Second artist',
    'Third artist',
  ];
  static const int needed = 3;

  static const Key continueKey = Key('first-run-continue');
  static const Key errorKey = Key('first-run-artists-error');
  static Key fieldKey(int i) => Key('artist-field-$i');
  static Key chipKey(int i) => Key('artist-chip-$i');
  static Key removeKey(int i) => Key('artist-remove-$i');

  @override
  ConsumerState<ArtistsScreen> createState() => _ArtistsScreenState();
}

class _ArtistsScreenState extends ConsumerState<ArtistsScreen> {
  final _controllers = [
    for (var i = 0; i < ArtistsScreen.needed; i++) TextEditingController(),
  ];
  final _focus = [for (var i = 0; i < ArtistsScreen.needed; i++) FocusNode()];

  /// The entered names, a chip each; null while the slot is a field.
  final List<String?> _chips = List.filled(ArtistsScreen.needed, null);
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (var i = 0; i < ArtistsScreen.needed; i++) {
      _controllers[i].addListener(() => setState(() {}));
      _focus[i].addListener(() {
        if (!_focus[i].hasFocus) _commit(i);
      });
    }
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    for (final f in _focus) {
      f.dispose();
    }
    super.dispose();
  }

  /// The slot's name: its chip, or what is typed in it.
  String _name(int i) => (_chips[i] ?? _controllers[i].text).trim();

  List<String> get _names => [
    for (var i = 0; i < ArtistsScreen.needed; i++)
      if (_name(i).isNotEmpty) _name(i),
  ];

  bool get _ready => _names.length >= ArtistsScreen.needed;

  void _commit(int i) {
    if (!mounted) return;
    final text = _controllers[i].text.trim();
    if (text.isEmpty || _chips[i] != null) return;
    setState(() => _chips[i] = text);
  }

  void _submitted(int i) {
    _commit(i);
    final next = _chips.indexWhere((c) => c == null);
    if (next >= 0) {
      _focus[next].requestFocus();
    } else {
      FocusScope.of(context).unfocus();
    }
  }

  void _remove(int i) {
    setState(() {
      _chips[i] = null;
      _controllers[i].clear();
    });
    _focus[i].requestFocus();
  }

  Future<void> _continue() async {
    if (_busy || !_ready) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final names = _names;
    try {
      await saveArtistSeeds(ref, names);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = FirstRunErrors.seeds;
      });
      return;
    }
    if (!mounted) return;
    final prompt = widget.prompt;
    if (prompt == null) {
      setState(() => _busy = false);
      unawaited(
        pushFirstRunPage<void>(
          context,
          const WelcomeScreen.prompt(seedsSaved: true),
        ),
      );
      return;
    }
    // The seeds are in: the busy state ends here and the making page,
    // pushed by startFirstMix, covers the DJ turn.
    setState(() => _busy = false);
    final error = await startFirstMix(
      context,
      ref,
      prompt,
      onCap: () {
        if (mounted) {
          unawaited(openCapSignIn(context, KeptPrompt(prompt)));
        }
      },
    );
    if (!mounted) return;
    setState(() => _error = error);
  }

  @override
  Widget build(BuildContext context) {
    return StepScaffold(
      background: FirstRunBackground.artists,
      headline: ArtistsScreen.headline,
      line: ArtistsScreen.line,
      body: [
        const SizedBox(height: 24),
        for (var i = 0; i < ArtistsScreen.needed; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          _slot(i),
        ],
        if (_error != null) ...[
          const SizedBox(height: 12),
          Semantics(
            liveRegion: true,
            child: Text(
              _error!,
              key: ArtistsScreen.errorKey,
              style: FirstRunType.line(
                context.tokens,
              ).copyWith(color: FirstRunColors.err),
            ),
          ),
        ],
      ],
      actions: [
        FirstRunPill(
          key: ArtistsScreen.continueKey,
          label: 'Continue',
          forward: true,
          disabledHint: 'Add three artists.',
          onPressed: _ready && !_busy ? () => unawaited(_continue()) : null,
        ),
      ],
    );
  }

  Widget _slot(int i) {
    final tokens = paperTokens(context.tokens);
    final chip = _chips[i];
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: FirstRunColors.paper,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: chip == null
                ? TextField(
                    key: ArtistsScreen.fieldKey(i),
                    controller: _controllers[i],
                    focusNode: _focus[i],
                    textInputAction: i == ArtistsScreen.needed - 1
                        ? TextInputAction.done
                        : TextInputAction.next,
                    textCapitalization: TextCapitalization.words,
                    autocorrect: false,
                    onSubmitted: (_) => _submitted(i),
                    cursorColor: FirstRunColors.ink,
                    style: tokens.body.copyWith(color: FirstRunColors.ink),
                    decoration: InputDecoration(
                      hintText: ArtistsScreen.placeholders[i],
                      hintStyle: tokens.body.copyWith(
                        color: FirstRunColors.paperMuted,
                      ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  )
                : _Chip(
                    key: ArtistsScreen.chipKey(i),
                    name: chip,
                    removeKey: ArtistsScreen.removeKey(i),
                    onRemove: _busy ? null : () => _remove(i),
                  ),
          ),
        ),
      ),
    );
  }
}

/// An entered artist (the board's `.achip`), with a 44 pt remove target.
class _Chip extends StatelessWidget {
  const _Chip({
    super.key,
    required this.name,
    required this.removeKey,
    required this.onRemove,
  });

  final String name;
  final Key removeKey;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      padding: const EdgeInsets.only(left: 14),
      constraints: const BoxConstraints(minHeight: 36),
      decoration: BoxDecoration(
        color: FirstRunColors.chip,
        borderRadius: BorderRadius.circular(MixtapeMetrics.pillRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              name,
              style: tokens.body.copyWith(
                color: FirstRunColors.ink,
                fontWeight: FontWeight.w600,
                fontSize: 15,
              ),
            ),
          ),
          IconButton(
            key: removeKey,
            tooltip: 'Remove $name',
            onPressed: onRemove,
            constraints: const BoxConstraints(
              minWidth: MixtapeMetrics.minTarget,
              minHeight: MixtapeMetrics.minTarget,
            ),
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.close, size: 14, color: Color(0xFF3F383F)),
          ),
        ],
      ),
    );
  }
}
