import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/api/api_client.dart';
import '../../data/listening/listening_models.dart';
import '../providers/onboarding_provider.dart';

const _genericErrorMessage = 'something went wrong on our end — try again';
const _offlineErrorMessage =
    "couldn't reach the DJ — check your connection and try again";

/// The waiting state's five-turn DJ interview (spec "Before the data
/// arrives"), as one scrolling form: artists you would never skip as chips,
/// then four short free-text answers, any of which may stay empty. Submit
/// posts the answers on the `ios` surface; the server stores the notes and
/// seeds and records `interview_completed` itself — this screen never posts
/// that event. Pushed from Home, which refreshes onboarding on return.
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

  /// Guarded by [_submitting] so a second tap can never post twice.
  Future<void> _submit() async {
    if (_submitting) return;
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
    final theme = Theme.of(context);
    final atCap = _artists.length >= InterviewScreen.maxArtists;
    return Scaffold(
      appBar: AppBar(title: const Text('Tell the DJ about your taste')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Five quick questions. Skip any you like — the DJ works with what it gets.',
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 24),
              Text(
                'Artists you would never skip',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              TextField(
                key: const Key('interview-artist-field'),
                controller: _artistController,
                enabled: !_submitting && !atCap,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _addArtist(),
                decoration: InputDecoration(
                  hintText: atCap
                      ? 'That is ${InterviewScreen.maxArtists} — plenty'
                      : 'Add an artist',
                  helperText: atCap
                      ? null
                      : 'Up to ${InterviewScreen.maxArtists}',
                  errorText: _artistError,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    key: const Key('interview-add-artist'),
                    tooltip: 'Add',
                    icon: const Icon(Icons.add),
                    onPressed: _submitting || atCap ? null : _addArtist,
                  ),
                ),
              ),
              if (_artists.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (var i = 0; i < _artists.length; i++)
                      InputChip(
                        key: Key('interview-artist-$i'),
                        label: Text(_artists[i]),
                        onDeleted: _submitting
                            ? null
                            : () => setState(() => _artists.removeAt(i)),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 24),
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
              if (_error != null) ...[
                Text(
                  _error!,
                  key: const Key('interview-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                const SizedBox(height: 8),
              ],
              FilledButton(
                key: const Key('interview-submit'),
                onPressed: _submitting ? null : _submit,
                child: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save my answers'),
              ),
            ],
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextField(
        key: fieldKey,
        controller: controller,
        enabled: enabled,
        minLines: 1,
        maxLines: 3,
        maxLength: InterviewScreen.maxAnswerLength,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
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
