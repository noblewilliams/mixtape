/// A mix's immutable versions, and the guarded path back to one of them
/// (`docs/decisions.md` → "Mix history keeps immutable versions"; the
/// September 9 six-feature approval).
///
/// Restyled for the native shell (`docs/mockups/approved/2026-09-17-mobile-shell.md`):
/// the large title, flush rows with a cassette tile, the tape button and the
/// plain text action. Behaviour, copy and provider calls are the approved ones —
/// preview, confirm, restore as a new version, conflict recovery and the
/// retry-safe uncertain path — with the confirmation moved into a native
/// dialog so it rides over the list instead of replacing it.
library;

import 'dart:math';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_client.dart';
import '../format/relative_time.dart';
import '../providers/auth_provider.dart';
import '../providers/dj_providers.dart';
import '../providers/mix_history_provider.dart';
import '../theme/mixtape_theme.dart';
import '../widgets/energy_journey.dart';
import '../widgets/foundation/cassette_tile.dart';
import '../widgets/foundation/flush_row.dart';
import '../widgets/foundation/glass_cluster.dart';
import '../widgets/foundation/gradient_background.dart';
import '../widgets/foundation/large_title_scaffold.dart';
import '../widgets/foundation/square_art.dart';
import '../widgets/foundation/status_word.dart';
import '../widgets/foundation/tape_button.dart';
import '../widgets/foundation/text_action.dart';

export '../providers/mix_history_provider.dart';

/// What a restore attempt settled into. `null` means the screen went away or
/// the session signed out, and nothing is left to report.
enum _RestoreOutcome { done, conflict, uncertain }

/// Shown while a list, a preview or a restore is in flight.
const String _workingMessage = 'Working…';

/// The restore came back unreadable. The request id is kept, so trying again
/// asks about the same request rather than starting a second one.
const String _uncertainMessage =
    'We couldn’t confirm the restore. Retry safely to check the same request.';

const String _conflictMessage =
    'Your mix changed, or a recording is unavailable. Review the latest version.';

const String _confirmBody =
    'This creates a new version. Your other versions stay available. '
    'Any playlist you saved stays as it is.';

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
  bool _busy = false, _confirming = false;
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
      // A request is only ever valid for the version it was made against, so
      // moving to another preview starts a fresh one rather than replaying an
      // unanswered restore under a new label.
      _request = null;
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

  /// One attempt at the restore, reusing [_request] so a retry after an
  /// unreadable answer asks about the same request rather than making a
  /// second one.
  Future<_RestoreOutcome?> _attemptRestore() async {
    final detail = _detail;
    if (detail == null) return null;
    _request ??= {
      'version': detail['version'],
      'expectedVersion': detail['currentVersion'],
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
      if (!mounted) return null;
      ref.invalidate(chatProvider(widget.sessionId));
      ref.invalidate(sessionsProvider);
      setState(() {
        _busy = false;
        _done = result['version'] as int;
      });
      return _RestoreOutcome.done;
    } catch (e) {
      if (!mounted) return null;
      if (e is ApiException && e.statusCode == 401) {
        ref.read(authProvider.notifier).signOut();
        return null;
      }
      if (e is ApiException && e.statusCode == 409) {
        setState(() {
          _busy = false;
          _error = _conflictMessage;
          _request = null;
          _detail = null;
        });
        return _RestoreOutcome.conflict;
      }
      // The line stays on the screen behind the dialog too, so cancelling out
      // of the retry does not hide what happened.
      setState(() {
        _busy = false;
        _error = _uncertainMessage;
      });
      return _RestoreOutcome.uncertain;
    }
  }

  Future<void> _confirmRestore() async {
    final detail = _detail;
    if (detail == null || _busy || _confirming) return;
    _confirming = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _WithTokens(
        child: _ConfirmRestoreDialog(
          version: detail['version'] as int,
          onRestore: _attemptRestore,
        ),
      ),
    );
    _confirming = false;
  }

  @override
  Widget build(BuildContext context) {
    return _WithTokens(
      // Below the tokens, not beside them: the slivers read them as they build.
      child: Builder(
        builder: (context) => GradientBackground(
          child: PopScope(
            canPop: !_busy,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: LargeTitleScaffold(
                title: 'Version history',
                leading: GlassCluster(
                  children: [
                    GlassButton(
                      key: const Key('mix-history-back'),
                      icon: CupertinoIcons.chevron_left,
                      label: 'Back',
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
                slivers: _slivers(context),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _slivers(BuildContext context) {
    if (_done != null) {
      return [SliverToBoxAdapter(child: _doneState(context))];
    }
    if (_detail != null) return _detailSlivers(context);
    return _listSlivers(context);
  }

  /// The error and the in-flight line, above whichever state is showing.
  Widget _status(BuildContext context) {
    final tokens = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: tokens.secondary.copyWith(color: tokens.errInk),
              ),
            ),
          ),
        if (_busy)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Semantics(
              liveRegion: true,
              child: Text(
                _workingMessage,
                style: tokens.secondary.copyWith(color: tokens.smoke),
              ),
            ),
          ),
      ],
    );
  }

  Widget _doneState(BuildContext context) {
    final tokens = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 8),
        Semantics(
          liveRegion: true,
          child: Text(
            'Version $_done is ready. Playback and saved playlists have not changed.',
            style: tokens.body,
          ),
        ),
        const SizedBox(height: 20),
        TapeButton(
          label: 'Back to mix',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  List<Widget> _listSlivers(BuildContext context) {
    final versions = (_list?['versions'] as List?) ?? const [];
    return [
      SliverToBoxAdapter(child: _status(context)),
      SliverList.builder(
        itemCount: versions.length,
        itemBuilder: (context, index) {
          final version = versions[index] as Map<String, dynamic>;
          return _VersionRow(
            key: ValueKey('mix-version-${version['version']}'),
            sessionId: widget.sessionId,
            version: version,
            isCurrent: version['version'] == _list?['currentVersion'],
            isFirst: index == 0,
            onTap: _busy ? null : () => _view(version['version'] as int),
          );
        },
      ),
      SliverToBoxAdapter(child: _listFooter(context, versions)),
    ];
  }

  Widget _listFooter(BuildContext context, List<dynamic> versions) {
    final tokens = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_list != null && versions.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'No versions yet. History starts with your first mix.',
              style: tokens.secondary.copyWith(color: tokens.smoke),
            ),
          ),
        if (versions.length == 1)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'Earlier versions may not have been saved. '
              'Future changes will be kept.',
              style: tokens.secondary.copyWith(color: tokens.smoke),
            ),
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (_error != null)
              TapeButton(
                label: 'Review latest',
                onPressed: _busy ? null : _load,
              ),
            if (_list?['nextBefore'] != null)
              TextAction(
                label: 'Older versions',
                quiet: true,
                onPressed: _busy
                    ? null
                    : () => _load(before: _list!['nextBefore'] as int),
              ),
          ],
        ),
      ],
    );
  }

  List<Widget> _detailSlivers(BuildContext context) {
    final tokens = context.tokens;
    final detail = _detail!;
    final entries = (detail['entries'] as List?) ?? const [];
    final isCurrent = detail['version'] == detail['currentVersion'];
    final unavailable = entries.any((e) => e['available'] != true);
    return [
      SliverToBoxAdapter(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _status(context),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('Version ${detail['version']}', style: tokens.section),
                if (isCurrent)
                  const StatusWord(label: 'Current', kind: StatusKind.ok),
              ],
            ),
            EnergyAssessment(detail: detail),
            if (entries.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'This version has no songs.',
                  style: tokens.secondary.copyWith(color: tokens.smoke),
                ),
              ),
          ],
        ),
      ),
      SliverList.builder(
        itemCount: entries.length,
        itemBuilder: (context, index) => _SongRow(
          entry: entries[index] as Map<String, dynamic>,
          isFirst: index == 0,
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // The current version is where the mix already is: there is
              // nothing to restore it to.
              if (!isCurrent)
                TapeButton(
                  label: 'Use this version',
                  onPressed: _busy || unavailable ? null : _confirmRestore,
                ),
              TextAction(
                label: 'Back to versions',
                quiet: true,
                onPressed: _busy
                    ? null
                    : () => _list == null
                          ? _load()
                          : setState(() {
                              _detail = null;
                              _request = null;
                            }),
              ),
            ],
          ),
        ),
      ),
    ];
  }
}

/// One saved version: the cassette, "Version N", and a meta line of song
/// count, age and where the version came from.
class _VersionRow extends StatelessWidget {
  const _VersionRow({
    super.key,
    required this.sessionId,
    required this.version,
    required this.isCurrent,
    required this.isFirst,
    required this.onTap,
  });

  final String sessionId;
  final Map<String, dynamic> version;
  final bool isCurrent, isFirst;
  final VoidCallback? onTap;

  static const double _tile = 44;

  /// The only origin the payload actually records. Everything else — whether
  /// a version came from a new mix or an edit — would be a guess, so the meta
  /// line simply leaves it out.
  static String? originOf(Map<String, dynamic> version) {
    final from = version['restoredFrom'];
    return from == null ? null : 'restored from version $from';
  }

  static String metaFor(Map<String, dynamic> version) {
    final count = version['trackCount'] as int? ?? 0;
    final createdAt = DateTime.tryParse(version['createdAt'] as String? ?? '');
    final origin = originOf(version);
    return [
      '$count ${count == 1 ? 'song' : 'songs'}',
      if (createdAt != null) relativeTime(createdAt),
      if (origin != null) origin,
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return FlushRow(
      leading: CassetteTile(width: _tile, seedId: sessionId),
      leadingSize: _tile,
      isFirst: isFirst,
      title: 'Version ${version['version']}',
      subtitleWidget: Wrap(
        spacing: 8,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (isCurrent)
            const StatusWord(label: 'Current', kind: StatusKind.ok),
          Text(
            metaFor(version),
            style: tokens.meta.copyWith(fontSize: 12.5, color: tokens.muted),
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// A song inside a previewed version: position, 40 pt art, title, artist.
class _SongRow extends StatelessWidget {
  const _SongRow({required this.entry, required this.isFirst});

  final Map<String, dynamic> entry;
  final bool isFirst;

  static const double _art = 40;
  static const double _numberWidth = 22;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final available = entry['available'] == true;
    return FlushRow(
      isFirst: isFirst,
      leadingSize: _numberWidth + 8 + _art,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: _numberWidth),
            child: Text(
              '${(entry['position'] as int) + 1}',
              textAlign: TextAlign.right,
              style: tokens.meta.copyWith(color: tokens.muted),
            ),
          ),
          const SizedBox(width: 8),
          const SquareArt(size: _art),
        ],
      ),
      title: entry['title'] as String,
      subtitle: available ? entry['artist'] as String : 'Unavailable recording',
    );
  }
}

/// "Use version N?" — the approved confirmation, and the only place a restore
/// is actually sent.
///
/// It owns the in-flight and retry states so the uncertain answer keeps the
/// same request in view: the screen hands it one attempt at a time and the
/// request id is reused across them.
class _ConfirmRestoreDialog extends StatefulWidget {
  const _ConfirmRestoreDialog({required this.version, required this.onRestore});

  final int version;
  final Future<_RestoreOutcome?> Function() onRestore;

  @override
  State<_ConfirmRestoreDialog> createState() => _ConfirmRestoreDialogState();
}

class _ConfirmRestoreDialogState extends State<_ConfirmRestoreDialog> {
  bool _busy = false, _retry = false;

  Future<void> _run() async {
    if (_busy) return;
    setState(() => _busy = true);
    final outcome = await widget.onRestore();
    if (!mounted) return;
    if (outcome == _RestoreOutcome.uncertain) {
      setState(() {
        _busy = false;
        _retry = true;
      });
      return;
    }
    // Done, conflicted, or gone: the screen behind now owns the answer.
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        backgroundColor: tokens.panel,
        surfaceTintColor: Colors.transparent,
        scrollable: true,
        title: Text('Use version ${widget.version}?', style: tokens.section),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_confirmBody, style: tokens.body),
            if (_busy)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _workingMessage,
                    style: tokens.secondary.copyWith(color: tokens.smoke),
                  ),
                ),
              ),
            if (_retry)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _uncertainMessage,
                    style: tokens.secondary.copyWith(color: tokens.errInk),
                  ),
                ),
              ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.end,
        actionsOverflowAlignment: OverflowBarAlignment.end,
        actions: [
          TextAction(
            // "Cancel" would read as "it did not happen", which is exactly
            // what an unconfirmed restore cannot promise: the request id is
            // kept on the screen, so closing leaves the retry available.
            label: _retry ? 'Close' : 'Cancel',
            quiet: true,
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
          ),
          TapeButton(
            label: _retry ? 'Retry restore' : 'Use version ${widget.version}',
            onPressed: _busy ? null : _run,
          ),
        ],
      ),
    );
  }
}

/// The history screen is pushed from hosts that do not all carry the app
/// theme (a mix row's actions menu inside a bare `MaterialApp`, for one), so
/// the tokens the foundation widgets read are ensured here rather than
/// assumed. In the app the ambient theme already carries them and this is a
/// pass-through.
class _WithTokens extends StatelessWidget {
  const _WithTokens({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (theme.extension<MixtapeTokens>() != null) return child;
    return Theme(
      data: theme.brightness == Brightness.dark
          ? MixtapeTheme.dark()
          : MixtapeTheme.light(),
      child: child,
    );
  }
}
