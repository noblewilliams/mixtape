import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/api/api_client.dart';
import '../../data/listening/listening_models.dart';
import '../providers/onboarding_provider.dart';
import '../theme/mixtape_theme.dart';
import '../widgets/foundation/frosted_surface.dart';
import '../widgets/foundation/glass_cluster.dart';
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/large_title_scaffold.dart';
import '../widgets/foundation/section_word.dart';
import '../widgets/foundation/tape_button.dart';

const _genericErrorMessage = 'something went wrong on our end — try again';
const _offlineErrorMessage =
    "couldn't reach the DJ — check your connection and try again";

/// The waiting state's five-turn DJ interview (spec "Before the data
/// arrives"), as one scrolling form: artists you would never skip as chips
/// (at least one, or there is nothing to submit), then four short free-text
/// answers, any of which may stay empty. Submit posts the answers on the
/// `ios` surface; the server stores the notes and seeds and records
/// `interview_completed` itself — this screen never posts that event.
/// Pushed from Home, which refreshes onboarding on return.
///
/// Restyled for the native shell (`docs/mockups/approved/2026-09-17-mobile-shell.md`):
/// the large title, each question a section word over a composer-shaped field,
/// and the save action pinned in a frosted bar that rides the keyboard.
class InterviewScreen extends ConsumerStatefulWidget {
  const InterviewScreen({super.key});

  static const int maxArtists = 20;
  static const int maxArtistLength = 200;
  static const int maxAnswerLength = 300;

  @override
  ConsumerState<InterviewScreen> createState() => _InterviewScreenState();
}

class _InterviewScreenState extends ConsumerState<InterviewScreen> {
  final _artistController = TextEditingController();
  final _playsMost = TextEditingController();
  final _listensWhen = TextEditingController();
  final _neverWants = TextEditingController();
  final _era = TextEditingController();
  final List<String> _artists = [];
  String? _artistError;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _artistController.dispose();
    _playsMost.dispose();
    _listensWhen.dispose();
    _neverWants.dispose();
    _era.dispose();
    super.dispose();
  }

  void _addArtist() {
    final name = _artistController.text.trim();
    if (name.isEmpty) return;
    if (name.length > InterviewScreen.maxArtistLength) {
      setState(
        () => _artistError =
            'Keep each name to ${InterviewScreen.maxArtistLength} characters',
      );
      return;
    }
    setState(() {
      _artistError = null;
      if (!_artists.contains(name) &&
          _artists.length < InterviewScreen.maxArtists) {
        _artists.add(name);
      }
    });
    _artistController.clear();
  }

  /// The server's limit counts UTF-16 code units (JavaScript's `length`),
  /// while the field's `maxLength` counts graphemes, so an emoji-heavy answer
  /// can pass the field and still be over. Checked here, before the post.
  static bool _tooLong(TextEditingController c) =>
      c.text.trim().length > InterviewScreen.maxAnswerLength;

  /// Guarded by [_submitting] so a second tap can never post twice, and by
  /// the artist list because the button is only enabled once it has one.
  Future<void> _submit() async {
    if (_submitting || _artists.isEmpty) return;
    if ([_playsMost, _listensWhen, _neverWants, _era].any(_tooLong)) {
      setState(
        () => _error = 'Keep each answer to ${InterviewScreen.maxAnswerLength} characters',
      );
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(listeningApiProvider)
          .postInterview(
            InterviewAnswers(
              neverSkip: List.unmodifiable(_artists),
              playsMost: _playsMost.text.trim(),
              listensWhen: _listensWhen.text.trim(),
              neverWants: _neverWants.text.trim(),
              era: _era.text.trim(),
            ),
          );
      // Detached: Home's card reads interviewCompletedAt from the refreshed
      // state, and a slow refetch must not hold the listener on this screen.
      unawaited(ref.read(onboardingProvider.notifier).refresh());
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(interviewSavedMessage(result))));
      Navigator.of(context).pop();
    } on NetworkException {
      if (!mounted) return;
      setState(() => _error = _offlineErrorMessage);
    } on ApiException {
      if (!mounted) return;
      setState(() => _error = _genericErrorMessage);
    } on ListeningModelException {
      if (!mounted) return;
      setState(() => _error = _genericErrorMessage);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GradientBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        // The save bar is the last row of the body, so the Scaffold's own
        // keyboard inset carries it above the keyboard.
        body: Column(
          children: [
            Expanded(
              child: LargeTitleScaffold(
                title: 'Tell the DJ about your taste',
                leading: GlassCluster(
                  children: [
                    GlassButton(
                      key: const Key('interview-back'),
                      icon: CupertinoIcons.chevron_left,
                      label: 'Back',
                      onPressed: _submitting
                          ? null
                          : () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
                slivers: [SliverToBoxAdapter(child: _form(context))],
              ),
            ),
            _SaveBar(
              error: _error,
              onSave: _submitting || _artists.isEmpty ? null : _submit,
              submitting: _submitting,
            ),
          ],
        ),
      ),
    );
  }

  Widget _form(BuildContext context) {
    final tokens = context.tokens;
    final atCap = _artists.length >= InterviewScreen.maxArtists;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 4),
        Text(
          'Five quick questions. Name at least one artist; the other four are '
          'optional — the DJ works with what it gets.',
          style: tokens.body.copyWith(color: tokens.smoke),
        ),
        const SectionWord('Artists you would never skip'),
        _FieldShell(
          child: Row(
            children: [
              Expanded(
                child: _fieldText(
                  context,
                  key: const Key('interview-artist-field'),
                  controller: _artistController,
                  enabled: !_submitting && !atCap,
                  hint: atCap
                      ? 'That is ${InterviewScreen.maxArtists} — plenty'
                      : 'Add an artist',
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _addArtist(),
                ),
              ),
              IconButton(
                key: const Key('interview-add-artist'),
                tooltip: 'Add',
                icon: Icon(Icons.add, size: 20, color: tokens.plum),
                onPressed: _submitting || atCap ? null : _addArtist,
              ),
            ],
          ),
        ),
        if (_artistError != null)
          _InlineNote(text: _artistError!, ink: tokens.errInk, live: true)
        else if (!atCap)
          _InlineNote(
            text: 'Up to ${InterviewScreen.maxArtists}',
            ink: tokens.muted,
          ),
        if (_artists.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < _artists.length; i++)
                  InterviewArtistChip(
                    key: Key('interview-artist-$i'),
                    label: _artists[i],
                    onRemove: _submitting
                        ? null
                        : () => setState(() => _artists.removeAt(i)),
                  ),
              ],
            ),
          ),
        _Answer(
          fieldKey: const Key('interview-plays-most'),
          controller: _playsMost,
          enabled: !_submitting,
          label: 'What do you play most these days?',
        ),
        _Answer(
          fieldKey: const Key('interview-listens-when'),
          controller: _listensWhen,
          enabled: !_submitting,
          label: 'When do you listen, and to what?',
        ),
        _Answer(
          fieldKey: const Key('interview-never-wants'),
          controller: _neverWants,
          enabled: !_submitting,
          label: 'Anything you never want to hear?',
        ),
        _Answer(
          fieldKey: const Key('interview-era'),
          controller: _era,
          enabled: !_submitting,
          label: 'An era you keep returning to',
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

/// The composer's own text treatment, without its chrome: no border of its
/// own, the shell around it draws the field.
TextField _fieldText(
  BuildContext context, {
  required Key key,
  required TextEditingController controller,
  required bool enabled,
  String? hint,
  int minLines = 1,
  int maxLines = 1,
  int? maxLength,
  TextInputAction? textInputAction,
  TextCapitalization textCapitalization = TextCapitalization.sentences,
  ValueChanged<String>? onSubmitted,
}) {
  final tokens = context.tokens;
  return TextField(
    key: key,
    controller: controller,
    enabled: enabled,
    minLines: minLines,
    maxLines: maxLines,
    maxLength: maxLength,
    textInputAction: textInputAction,
    textCapitalization: textCapitalization,
    onSubmitted: onSubmitted,
    cursorColor: tokens.plum,
    style: tokens.body,
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: tokens.body.copyWith(color: tokens.muted),
      counterText: '',
      isDense: true,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      disabledBorder: InputBorder.none,
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
    ),
  );
}

/// The composer's shape around a field: the field tint, a hairline edge and
/// 12 pt top / 16 pt bottom corners.
class _FieldShell extends StatelessWidget {
  const _FieldShell({required this.child});

  final Widget child;

  static const BorderRadius radius = BorderRadius.only(
    topLeft: Radius.circular(MixtapeMetrics.composerRadiusTop),
    topRight: Radius.circular(MixtapeMetrics.composerRadiusTop),
    bottomLeft: Radius.circular(MixtapeMetrics.composerRadiusBottom),
    bottomRight: Radius.circular(MixtapeMetrics.composerRadiusBottom),
  );

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      constraints: const BoxConstraints(
        minHeight: MixtapeMetrics.composerHeight,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: tokens.field,
        borderRadius: radius,
        border: Border.all(color: tokens.hairline),
      ),
      child: child,
    );
  }
}

/// A quiet line under a field: the artist cap, or the name-length refusal.
class _InlineNote extends StatelessWidget {
  const _InlineNote({required this.text, required this.ink, this.live = false});

  final String text;
  final Color ink;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final line = Padding(
      padding: const EdgeInsets.only(top: 6, left: 2),
      child: Text(text, style: context.tokens.secondary.copyWith(color: ink)),
    );
    return live ? Semantics(liveRegion: true, child: line) : line;
  }
}

/// One named artist, as the Home pill shaped for removal: the whole chip is
/// the remove target, with the glyph as its affordance, so the 44 pt rule
/// holds on a 34 pt pill.
class InterviewArtistChip extends StatelessWidget {
  const InterviewArtistChip({
    super.key,
    required this.label,
    required this.onRemove,
  });

  final String label;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      button: true,
      enabled: onRemove != null,
      label: 'Remove $label',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onRemove,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: MixtapeMetrics.minTarget,
          ),
          child: Center(
            widthFactor: 1,
            child: Opacity(
              opacity: onRemove == null ? 0.5 : 1,
              child: Container(
                constraints: const BoxConstraints(
                  minHeight: MixtapeMetrics.pillHeight,
                ),
                padding: const EdgeInsets.fromLTRB(13, 0, 9, 0),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: isDark ? 0.10 : 0.55),
                  borderRadius: const BorderRadius.all(
                    Radius.circular(MixtapeMetrics.pillRadius),
                  ),
                  border: Border.all(color: tokens.hairline),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: tokens.text,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(Icons.close, size: 14, color: tokens.smoke),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Answer extends StatelessWidget {
  const _Answer({
    required this.fieldKey,
    required this.controller,
    required this.enabled,
    required this.label,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final bool enabled;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SectionWord(label),
        _FieldShell(
          child: _fieldText(
            context,
            key: fieldKey,
            controller: controller,
            enabled: enabled,
            minLines: 1,
            maxLines: 3,
            maxLength: InterviewScreen.maxAnswerLength,
          ),
        ),
      ],
    );
  }
}

/// The pinned save bar: the inline error over the tape button, on glass.
class _SaveBar extends StatelessWidget {
  const _SaveBar({
    required this.error,
    required this.onSave,
    required this.submitting,
  });

  final String? error;
  final VoidCallback? onSave;
  final bool submitting;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return FrostedSurface(
      borderRadius: BorderRadius.zero,
      shadow: false,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            MixtapeMetrics.screenSidePadding,
            10,
            MixtapeMetrics.screenSidePadding,
            10,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (error != null)
                Semantics(
                  liveRegion: true,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      error!,
                      key: const Key('interview-error'),
                      style: tokens.secondary.copyWith(color: tokens.errInk),
                    ),
                  ),
                ),
              Align(
                child: TapeButton(
                  key: const Key('interview-submit'),
                  label: 'Save my answers',
                  onPressed: onSave,
                  leading: submitting
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "saved 4 notes, 2 artists" — the counts the server answers with.
String interviewSavedMessage(InterviewResult result) {
  final notes = result.notesSaved;
  final artists = result.seeds;
  return 'saved $notes ${notes == 1 ? 'note' : 'notes'}, '
      '$artists ${artists == 1 ? 'artist' : 'artists'}';
}
