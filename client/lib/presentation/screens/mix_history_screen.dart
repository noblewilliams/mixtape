import '../widgets/energy_journey.dart';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/api/api_client.dart';
import '../providers/mix_history_provider.dart';
export '../providers/mix_history_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/dj_providers.dart';


class MixHistoryScreen extends ConsumerStatefulWidget {
  const MixHistoryScreen({
    super.key,
    required this.sessionId,
    this.initialVersion,
  });
  final String sessionId;
  final int? initialVersion;
  @override
  ConsumerState<MixHistoryScreen> createState() => _MixHistoryScreenState();
}

class _MixHistoryScreenState extends ConsumerState<MixHistoryScreen> {
  Map<String, dynamic>? _list, _detail, _request;
  String? _error;
  int? _done;
  bool _busy = false, _confirm = false, _retry = false;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        if (widget.initialVersion != null) {
          _view(widget.initialVersion!);
        } else {
          _load();
        }
      }
    });
  }

  Future<void> _load({int? before}) async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(mixHistoryApiProvider)
          .list(widget.sessionId, before: before);
      if (!mounted || generation != _generation) return;
      setState(() {
        if (before != null && _list != null) {
          result['versions'] = [..._list!['versions'], ...result['versions']];
        }
        _list = result;
        _detail = null;
        _confirm = false;
        _retry = false;
        _request = null;
      });
    } catch (e) {
      if (mounted && generation == _generation) _failed(e);
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  void _failed(Object e) {
    if (e is ApiException && e.statusCode == 401) {
      ref.read(authProvider.notifier).signOut();
      return;
    }
    setState(
      () => _error = e is ApiException && e.statusCode == 404
          ? 'This version is unavailable. Older mixes may not have saved history.'
          : 'Couldn’t load versions. Try again.',
    );
  }

  Future<void> _view(int version) async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final value = await ref
          .read(mixHistoryApiProvider)
          .read(widget.sessionId, version);
      if (mounted && generation == _generation) setState(() => _detail = value);
    } catch (e) {
      if (mounted && generation == _generation) _failed(e);
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    if (_busy || _detail == null) return;
    _request ??= {
      'version': _detail!['version'],
      'expectedVersion': _detail!['currentVersion'],
      'requestId': List.generate(
        16,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join(),
    };
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(mixHistoryApiProvider)
          .restore(widget.sessionId, _request!);
      if (!mounted) return;
      ref.invalidate(chatProvider(widget.sessionId));
      ref.invalidate(sessionsProvider);
      setState(() {
        _done = result['version'] as int;
        _retry = false;
        _confirm = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (e is ApiException && e.statusCode == 401) {
        ref.read(authProvider.notifier).signOut();
        return;
      }
      setState(() {
        if (e is ApiException && e.statusCode == 409) {
          _error =
              'Your mix changed, or a recording is unavailable. Review the latest version.';
          _request = null;
          _retry = false;
          _confirm = false;
          _detail = null;
        } else {
          _error =
              'We couldn’t confirm the restore. Retry safely to check the same request.';
          _retry = true;
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _button(
    String label,
    VoidCallback? onPressed, {
    bool primary = false,
  }) => primary
      ? FilledButton(onPressed: onPressed, child: Text(label))
      : TextButton(onPressed: onPressed, child: Text(label));
  @override
  Widget build(BuildContext context) {
    final entries = (_detail?['entries'] as List?) ?? [];
    final versions = (_list?['versions'] as List?) ?? [];
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Mix version history')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              if (_error != null)
                Semantics(liveRegion: true, child: Text(_error!)),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('Working…'),
                ),
              if (_done != null) ...[
                Semantics(
                  liveRegion: true,
                  child: Text(
                    'Version $_done is ready. Playback and saved playlists have not changed.',
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _button(
                    'Back to mix',
                    () => Navigator.of(context).pop(),
                    primary: true,
                  ),
                ),
              ] else if (_confirm && _detail != null) ...[
                Text(
                  'Use version ${_detail!['version']}?',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 16),
                const Text(
                  'This creates a new version. Your other versions stay available. Any playlist you saved stays as it is.',
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  children: [
                    _button(
                      _retry
                          ? 'Retry restore'
                          : 'Use version ${_detail!['version']}',
                      _busy ? null : _restore,
                      primary: true,
                    ),
                    _button(
                      'Cancel',
                      _busy || _retry
                          ? null
                          : () => setState(() => _confirm = false),
                    ),
                  ],
                ),
              ] else if (_detail != null) ...[
                Text(
                  'Version ${_detail!['version']}',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                EnergyAssessment(detail: _detail!),
                if (entries.isEmpty) const Text('This version has no songs.'),
                for (final e in entries)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Text('${(e['position'] as int) + 1}'),
                    title: Text(e['title'] as String),
                    subtitle: Text(
                      e['available'] == true
                          ? e['artist'] as String
                          : 'Unavailable recording',
                    ),
                  ),
                Wrap(
                  spacing: 12,
                  children: [
                    _button(
                      'Use this version',
                      _busy || entries.any((e) => e['available'] != true)
                          ? null
                          : () => setState(() => _confirm = true),
                      primary: true,
                    ),
                    _button(
                      'Back to versions',
                      _busy
                          ? null
                          : () => _list == null
                                ? _load()
                                : setState(() => _detail = null),
                    ),
                  ],
                ),
              ] else ...[
                for (final v in versions)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 16,
                      children: [
                        Text(
                          'Version ${v['version']}${v['version'] == _list!['currentVersion'] ? ' · current' : ''}\n${v['trackCount']} songs',
                        ),
                        _button(
                          'View',
                          _busy ? null : () => _view(v['version'] as int),
                        ),
                      ],
                    ),
                  ),
                if (_list != null && versions.isEmpty)
                  const Text(
                    'No versions yet. History starts with your first mix.',
                  ),
                if (versions.length == 1)
                  const Text(
                    'Earlier versions may not have been saved. Future changes will be kept.',
                  ),
                if (_list?['nextBefore'] != null)
                  _button(
                    'Older versions',
                    _busy
                        ? null
                        : () => _load(before: _list!['nextBefore'] as int),
                  ),
                if (_error != null)
                  _button('Review latest', _busy ? null : _load),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
