import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/playback/playback_controller.dart';
import '../providers/playback_provider.dart';
import '../providers/library_sync_provider.dart';

String _time(double ms) =>
    '${ms ~/ 60000}:${((ms ~/ 1000) % 60).toString().padLeft(2, '0')}';

class PlaybackScreen extends ConsumerWidget {
  const PlaybackScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playbackProvider);
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final index = player.unavailableIndex ?? player.sample.index ?? 0;
        final track = index < player.tracks.length
            ? player.tracks[index]
            : null;
        return Scaffold(
          appBar: AppBar(title: const Text('Your player')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  track?.title ?? player.title,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                Text('${track?.artist ?? ''} · Apple Music'),
                const SizedBox(height: 12),
                Text('${player.title} · version ${player.version}'),
                if (player.busy)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: LinearProgressIndicator(),
                  ),
                if (player.error.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(player.error),
                  ),
                if (player.error.isNotEmpty)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: player.busy ? null : player.reconnect,
                      child: const Text('Connect Apple Music'),
                    ),
                  ),
                const SizedBox(height: 24),
                Semantics(
                  label: 'Playback position',
                  child: _PlaybackSeek(
                    player: player,
                    duration: (track?.durationMs ?? 0).toDouble(),
                  ),
                ),
                Text(
                  '${_time(player.sample.positionMs)} / ${_time((track?.durationMs ?? 0).toDouble())}',
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    OutlinedButton(
                      onPressed: player.busy
                          ? null
                          : () => player.command('previous'),
                      child: const Text('Previous'),
                    ),
                    FilledButton(
                      onPressed: player.busy
                          ? null
                          : () => player.command(
                              player.sample.status == 'playing'
                                  ? 'pause'
                                  : 'resume',
                            ),
                      child: Text(
                        player.sample.status == 'playing' ? 'Pause' : 'Resume',
                      ),
                    ),
                    OutlinedButton(
                      onPressed: player.busy
                          ? null
                          : () => player.command('next'),
                      child: const Text('Next'),
                    ),
                    TextButton(
                      onPressed: player.busy
                          ? null
                          : () => player.command('repeat'),
                      child: const Text('Repeat song'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => player.stop(),
                      child: Text(player.busy ? 'Cancel' : 'Stop playback'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const ListeningPreferencesScreen(),
                        ),
                      ),
                      child: const Text('Listening preferences'),
                    ),
                    TextButton(
                      onPressed: player.busy
                          ? null
                          : () async {
                              final ids = player.tracks
                                  .map((t) => t.appleId!)
                                  .toList();
                              await player.stop();
                              if (!context.mounted) return;
                              try {
                                await ref
                                    .read(musicKitBridgeProvider)
                                    .playQueue(ids);
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Playing in Music. Listening there is not observed.',
                                      ),
                                    ),
                                  );
                                }
                              } catch (_) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Could not send to Music.'),
                                    ),
                                  );
                                }
                              }
                            },
                      child: const Text('Send to Music'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class PlaybackMini extends ConsumerWidget {
  const PlaybackMini({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playbackProvider);
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        if (player.sessionId == null) return const SizedBox.shrink();
        final index = player.unavailableIndex ?? player.sample.index ?? 0;
        final track = index < player.tracks.length
            ? player.tracks[index]
            : null;
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            borderRadius: BorderRadius.circular(12),
          ),
          child: ListTile(
            title: Text(
              track?.title ?? player.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              player.busy
                  ? 'Getting ready…'
                  : player.error.isNotEmpty
                  ? 'Playback unavailable'
                  : player.sample.status == 'playing'
                  ? 'Playing'
                  : 'Paused',
            ),
            trailing: const Icon(Icons.open_in_full),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PlaybackScreen()),
            ),
          ),
        );
      },
    );
  }
}

class ListeningPreferencesScreen extends ConsumerStatefulWidget {
  const ListeningPreferencesScreen({super.key});
  @override
  ConsumerState<ListeningPreferencesScreen> createState() =>
      _ListeningPreferencesState();
}

class _ListeningPreferencesState
    extends ConsumerState<ListeningPreferencesScreen> {
  bool busy = false;
  String message = '';
  String? clearId;
  @override
  void initState() {
    super.initState();
    Future.microtask(() => ref.read(playbackProvider).initialize());
  }

  Future<void> save(bool enabled) async {
    setState(() => busy = true);
    try {
      await ref.read(playbackProvider).setLearning(enabled);
      if (mounted) {
        setState(
          () => message = enabled
              ? 'Listening learning is on.'
              : 'Listening learning is off.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'Could not save. Collection is paused until you try again.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> clear() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear learned listening?'),
        content: const Text(
          'Remove listening activity collected for learning. Imported history, mixes and written preferences stay.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear learned listening'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => busy = true);
    clearId ??= playbackUuid();
    try {
      await ref.read(playbackProvider).clear(clearId!);
      if (mounted) {
        setState(() {
          message = 'Learned listening cleared.';
          clearId = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => message =
              'Could not confirm clearing. Retry to check the same request.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playbackProvider);
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Listening preferences')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                'Let listening shape your mixes.',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 16),
              const Text(
                'Patterns in skips, repeats and listening help the DJ adapt. One skipped song does not mean you dislike it.',
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Learn from my listening in Mixtape'),
                value: player.preferences?['enabled'] == true,
                onChanged: busy ? null : save,
              ),
              const Text(
                'Imported history and preferences you told the DJ stay separate.',
              ),
              if (message.isNotEmpty) Text(message),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: busy ? null : clear,
                  child: const Text('Clear learned listening'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaybackSeek extends StatefulWidget {
  const _PlaybackSeek({required this.player, required this.duration});
  final PlaybackController player;
  final double duration;
  @override
  State<_PlaybackSeek> createState() => _PlaybackSeekState();
}

class _PlaybackSeekState extends State<_PlaybackSeek> {
  double? draft;
  @override
  Widget build(BuildContext context) => Slider(
    value: (draft ?? widget.player.sample.positionMs).clamp(0, widget.duration),
    max: widget.duration,
    label: _time(draft ?? widget.player.sample.positionMs),
    onChanged: widget.player.busy || widget.duration <= 0
        ? null
        : (value) => setState(() => draft = value),
    onChangeEnd: widget.player.busy
        ? null
        : (value) {
            setState(() => draft = null);
            widget.player.command('seek', seconds: value / 1000);
          },
  );
}
