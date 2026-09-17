import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/playlists/playlist_api.dart';
import '../../data/playlists/playlist_context_models.dart';
import '../../data/playlists/playlist_models.dart';
import '../providers/auth_provider.dart';
import '../providers/playlist_providers.dart';

class PlaylistInspirationChoice {
  const PlaylistInspirationChoice(
    this.playlist, {
    required this.excludeSourceTracks,
  });
  final PlaylistSummary playlist;
  final bool excludeSourceTracks;
  InitialPlaylistSeed get seed => InitialPlaylistSeed(
    playlistId: playlist.id,
    excludeSourceTracks: excludeSourceTracks,
  );
}

String playlistSourceLabel(String? source) => switch (source) {
  'apple' => 'Apple Music',
  'spotify_export' => 'Spotify export',
  _ => 'Imported playlist',
};

/// Reading and choosing never writes. Null means dismissed, never detach.
Future<PlaylistInspirationChoice?> showPlaylistInspirationPicker(
  BuildContext context,
  WidgetRef ref, {
  Rect? anchor,
  Rect Function()? anchorResolver,
  InitialPlaylistSeed? selected,
}) {
  final api = ref.read(playlistApiProvider);
  return showDialog<PlaylistInspirationChoice>(
    context: context,
    useSafeArea: false,
    builder: (_) => _PlaylistPicker(
      api: api,
      selected: selected,
      anchor: anchor,
      anchorResolver: anchorResolver,
    ),
  );
}

class PlaylistInspirationAttachment extends StatelessWidget {
  const PlaylistInspirationAttachment({
    super.key,
    required this.name,
    this.source,
    this.busy = false,
    this.disabled = false,
    this.statusMessage,
    required this.onPick,
    this.onDetach,
    this.onReload,
    this.reloadLabel = 'Reload inspiration',
  });
  final String? name;
  final String? source;
  final bool busy;
  final bool disabled;
  final String? statusMessage;
  final VoidCallback onPick;
  final VoidCallback? onDetach;
  final VoidCallback? onReload;
  final String reloadLabel;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Row(
        children: [
          Flexible(
            child: TextButton(
              key: const Key('playlist-inspiration-attachment'),
              onPressed: busy || disabled ? null : onPick,
              child: Text(
                name == null ? '+ Playlist' : 'Inspired by $name',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          if (name != null && onDetach != null)
            IconButton(
              tooltip: 'Detach playlist inspiration',
              onPressed: busy || disabled ? null : onDetach,
              icon: const Icon(Icons.close, size: 18),
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            ),
          if (busy)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
      if (statusMessage != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            statusMessage!,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      if (onReload != null)
        TextButton(onPressed: busy ? null : onReload, child: Text(reloadLabel)),
    ],
  );
}

class _PlaylistPicker extends ConsumerStatefulWidget {
  const _PlaylistPicker({
    required this.api,
    this.selected,
    this.anchor,
    this.anchorResolver,
  });
  final PlaylistApi api;
  final InitialPlaylistSeed? selected;
  final Rect? anchor;
  final Rect Function()? anchorResolver;
  @override
  ConsumerState<_PlaylistPicker> createState() => _PlaylistPickerState();
}

class _PlaylistPickerState extends ConsumerState<_PlaylistPicker>
    with WidgetsBindingObserver {
  final _search = TextEditingController();
  Timer? _debounce;
  List<PlaylistSummary> _playlists = [];
  String? _cursor;
  bool _loading = true;
  bool _failed = false;
  bool _exclude = false;
  int _request = 0;
  bool _closing = false;
  Rect? _liveAnchor;
  bool _anchorMeasurePending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _liveAnchor = widget.anchor;
    _scheduleAnchorMeasure();
    _exclude = widget.selected?.excludeSourceTracks ?? false;
    _load(reset: true);
  }

  @override
  void didChangeMetrics() => _scheduleAnchorMeasure();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleAnchorMeasure();
  }

  void _scheduleAnchorMeasure() {
    if (widget.anchorResolver == null || _anchorMeasurePending) return;
    _anchorMeasurePending = true;
    // Keyboard metrics arrive before the underlying composer is laid out.
    // Measure afterwards so the popup protects its new position, not the
    // rectangle captured before the keyboard opened.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _anchorMeasurePending = false;
      if (!mounted || _closing) return;
      Rect measured;
      try {
        measured = widget.anchorResolver!();
      } catch (_) {
        // The originating composer may have been removed while this route
        // was open. A picker without its destination must not return a choice.
        _closing = true;
        Navigator.of(context).pop();
        return;
      }
      if (_liveAnchor != measured) setState(() => _liveAnchor = measured);
    });
  }

  bool get _signedIn => ref.read(authProvider) == AuthStatus.signedIn;

  Future<void> _load({required bool reset}) async {
    if (!reset && _loading) return;
    final request = ++_request;
    setState(() {
      _loading = true;
      _failed = false;
      if (reset) {
        _playlists = [];
        _cursor = null;
      }
    });
    try {
      final page = await widget.api.list(
        query: _search.text.trim().isEmpty ? null : _search.text.trim(),
        cursor: reset ? null : _cursor,
      );
      if (!mounted || request != _request || !_signedIn) return;
      setState(() {
        final seen = _playlists.map((p) => p.id).toSet();
        _playlists = [
          ..._playlists,
          ...page.playlists.where((p) => seen.add(p.id)),
        ];
        _cursor = page.nextCursor;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || request != _request || !_signedIn) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _query(String _) {
    _debounce?.cancel();
    _request++;
    setState(() {
      _loading = true;
      _failed = false;
      _playlists = [];
      _cursor = null;
    });
    _debounce = Timer(
      const Duration(milliseconds: 200),
      () => _load(reset: true),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _request++;
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    if (auth != AuthStatus.signedIn && !_closing) {
      _closing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    }
    final media = MediaQuery.of(context);
    final minTop = media.padding.top + 16;
    final bottom =
        media.size.height -
        math.max(media.padding.bottom, media.viewInsets.bottom) -
        16;
    final width = math.min(
      350.0,
      media.size.width - media.padding.horizontal - 32,
    );
    final anchor = _liveAnchor;
    var top = minTop;
    var available = math.max(0.0, bottom - minTop);
    if (anchor != null) {
      final above = math.max(0.0, math.min(anchor.top - 8, bottom) - minTop);
      final belowTop = math.max(minTop, anchor.bottom + 8);
      final below = math.max(0.0, bottom - belowTop);
      if (above >= below) {
        available = above;
        top = math.min(anchor.top - 8, bottom) - math.min(460.0, above);
      } else {
        available = below;
        top = belowTop;
      }
    }
    final height = math.min(460.0, available);
    final left = (anchor?.left ?? media.padding.left + 16).clamp(
      media.padding.left + 16,
      math.max(
        media.padding.left + 16,
        media.size.width - media.padding.right - width - 16,
      ),
    );
    return Dialog(
      alignment: Alignment.topLeft,
      insetPadding: EdgeInsets.fromLTRB(
        left.toDouble(),
        top.toDouble(),
        16,
        16,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: width,
        height: height,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              Row(
                children: [
                  const Expanded(child: Text('Playlist inspiration')),
                  IconButton(
                    tooltip: 'Close playlist picker',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              TextField(
                key: const Key('playlist-search'),
                controller: _search,
                maxLength: 200,
                onChanged: _query,
                decoration: const InputDecoration(
                  hintText: 'Find a playlist',
                  counterText: '',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Use different songs'),
                value: _exclude,
                onChanged: (value) => setState(() => _exclude = value ?? false),
              ),
              if (_playlists.isEmpty && !_loading && !_failed)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('No matching playlists.'),
                ),
              for (final playlist in _playlists)
                ListTile(
                  key: ValueKey('playlist-choice-${playlist.id}'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(playlist.name),
                  subtitle: Text(
                    '${playlistSourceLabel(playlist.source)} · ${playlist.entryCount} songs',
                  ),
                  trailing: widget.selected?.playlistId == playlist.id
                      ? const Icon(Icons.check, size: 18)
                      : null,
                  onTap: () {
                    if (_signedIn) {
                      Navigator.of(context).pop(
                        PlaylistInspirationChoice(
                          playlist,
                          excludeSourceTracks: _exclude,
                        ),
                      );
                    }
                  },
                ),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (_failed) ...[
                const Text('Couldn’t load playlists.'),
                TextButton(
                  onPressed: () => _load(reset: _playlists.isEmpty),
                  child: const Text('Retry'),
                ),
              ],
              if (!_loading && !_failed && _cursor != null)
                TextButton(
                  onPressed: () => _load(reset: false),
                  child: const Text('Load more'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
