/// A mix's immutable versions, and the guarded path back to one of them
/// (`docs/decisions.md` → "Mix history keeps immutable versions"; the
/// September 9 six-feature approval).
///
/// Laid out per the mix conversation redesign
/// (`docs/mockups/approved/2026-11-03-mix-conversation-redesign.md` →
/// Versions; board section 4): "Versions" with Now and Earlier sections,
/// readable times, and each version's "made from" line taken from the
/// transcript the app already holds. An earlier version opens a preview with
/// the tape screen's cassette header and a sticky "Use this version".
///
/// Restyled for the native shell (`docs/mockups/approved/2026-09-17-mobile-shell.md`):
/// the large title, flush rows with a cassette tile, the tape button and the
/// plain text action. Behaviour, copy and provider calls are the approved ones —
/// preview, confirm, restore as a new version, conflict recovery and the
/// retry-safe uncertain path — with the confirmation moved into a native
/// dialog so it rides over the list instead of replacing it.
library;

import 'dart:math';

import 'package:flutter/cupertino.dart'
    show
        CupertinoAlertDialog,
        CupertinoDialogAction,
        CupertinoIcons,
        showCupertinoDialog;
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
import '../widgets/foundation/tape_button.dart';
import '../widgets/foundation/text_action.dart';
import '../widgets/mix_tape_colour.dart';
import '../widgets/tape_header.dart';
import 'queue_screen.dart';

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
    this.fromTape = false,
  });
  final String sessionId;
  final int? initialVersion;

  /// Opened from the tape screen: "Now" goes back to it rather than stacking
  /// a second copy on top.
  final bool fromTape;
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
    await showCupertinoDialog<void>(
      context: context,
      builder: (_) => _WithTokens(
        child: _ConfirmRestoreDialog(
          version: detail['version'] as int,
          onRestore: _attemptRestore,
        ),
      ),
    );
    _confirming = false;
  }

  /// Back from a preview opened from the list returns to the list; a
  /// preview opened straight from the conversation's marker leaves.
  bool get _backToList => _detail != null && _list != null && _done == null;

  void _closePreview() => setState(() {
    _detail = null;
    _request = null;
    _error = null;
  });

  @override
  Widget build(BuildContext context) {
    final transcript = ref.watch(chatProvider(widget.sessionId)).value;
    final colour = watchMixTapeColour(
      ref,
      widget.sessionId,
      saved: transcript?.session.caseColor,
    );
    return _WithTokens(
      // Below the tokens, not beside them: the slivers read them as they build.
      child: Builder(
        builder: (context) => GradientBackground(
          child: PopScope(
            canPop: !_busy && !_backToList,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop && !_busy && _backToList) _closePreview();
            },
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: _detail != null && _done == null
                  ? _preview(context, colour, transcript)
                  : LargeTitleScaffold(
                      title: 'Versions',
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
                      slivers: _done != null
                          ? [SliverToBoxAdapter(child: _doneState(context))]
                          : _listSlivers(context, colour, transcript),
                    ),
            ),
          ),
        ),
      ),
    );
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

  List<Widget> _listSlivers(
    BuildContext context,
    Color colour,
    ChatState? transcript,
  ) {
    final versions = [
      for (final v in (_list?['versions'] as List?) ?? const []) v as Map<String, dynamic>,
    ];
    final currentVersion = _list?['currentVersion'];
    final now = versions.where((v) => v['version'] == currentVersion).toList();
    final earlier = versions
        .where((v) => v['version'] != currentVersion)
        .toList();
    Widget row(Map<String, dynamic> version, {required bool isFirst}) {
      final number = version['version'] as int;
      final isCurrent = number == currentVersion;
      return _VersionRow(
        key: ValueKey('mix-version-$number'),
        version: version,
        caseColor: colour,
        madeFrom: madeFromMessage(transcript?.messages, number),
        duration: isCurrent && transcript != null
            ? tapeDurationLabel(transcript.queue)
            : null,
        isFirst: isFirst,
        onTap: _busy
            ? null
            : isCurrent
            ? _openTape
            : () => _view(number),
      );
    }

    return [
      SliverToBoxAdapter(child: _status(context)),
      if (now.isNotEmpty) ...[
        const SliverToBoxAdapter(child: _SectionHeader('Now')),
        SliverList.list(
          children: [for (final v in now) row(v, isFirst: true)],
        ),
      ],
      if (earlier.isNotEmpty) ...[
        const SliverToBoxAdapter(child: _SectionHeader('Earlier')),
        SliverList.builder(
          itemCount: earlier.length,
          itemBuilder: (context, index) =>
              row(earlier[index], isFirst: index == 0),
        ),
      ],
      SliverToBoxAdapter(child: _listFooter(context, versions)),
    ];
  }

  /// "Now" opens the tape itself — by going back to it, when that is where
  /// the listener came from.
  void _openTape() {
    if (widget.fromTape) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => QueueScreen(sessionId: widget.sessionId),
      ),
    );
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

  /// An earlier version's preview: the tape screen's cassette header, the
  /// message it was made from, its songs, and "Use this version" in a bar
  /// that stays put. The system Back returns to the list.
  Widget _preview(BuildContext context, Color colour, ChatState? transcript) {
    final tokens = context.tokens;
    final detail = _detail!;
    final number = detail['version'] as int;
    final entries = (detail['entries'] as List?) ?? const [];
    final isCurrent = number == detail['currentVersion'];
    final unavailable = entries.any((e) => e['available'] != true);
    final listed = ((_list?['versions'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .where((v) => v['version'] == number)
        .firstOrNull;
    final createdAt = DateTime.tryParse(listed?['createdAt'] as String? ?? '');
    final arc = EnergyArc.values
        .where((a) => a.name == detail['energyArc'])
        .firstOrNull;
    final meta = [
      if (createdAt != null) versionTime(createdAt),
      '${entries.length} ${entries.length == 1 ? 'song' : 'songs'}',
      if (arc != null) 'energy ${arc.label.toLowerCase()}',
    ].join(' · ');
    final madeFrom = madeFromMessage(transcript?.messages, number);
    final restoredFrom = detail['restoredFrom'] ?? listed?['restoredFrom'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Row(
              children: [
                GlassCluster(
                  children: [
                    GlassButton(
                      key: const Key('mix-history-back'),
                      icon: CupertinoIcons.chevron_left,
                      label: 'Back',
                      onPressed: _busy
                          ? null
                          : () => _backToList
                                ? _closePreview()
                                : Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
                Expanded(
                  child: Text(
                    'Version $number',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.smallTitle,
                  ),
                ),
                const SizedBox(width: MixtapeMetrics.minTarget),
              ],
            ),
          ),
        ),
        Expanded(
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: TapeHeader(
                  caseColor: colour,
                  title: 'Version $number',
                  meta: meta,
                  cassetteWidth: 110,
                  titleStyle: tokens.largeTitle.copyWith(
                    fontSize: 21,
                    height: 1.12,
                  ),
                ),
              ),
              if (restoredFrom != null || madeFrom != null)
                SliverToBoxAdapter(
                  child: _MadeFrom(
                    text: restoredFrom != null
                        ? 'Restored from version $restoredFrom'
                        : '“$madeFrom”',
                  ),
                ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: MixtapeMetrics.screenSidePadding,
                  ),
                  child: _status(context),
                ),
              ),
              if (entries.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      'This version has no songs.',
                      style: tokens.secondary.copyWith(color: tokens.smoke),
                    ),
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  MixtapeMetrics.screenSidePadding,
                  0,
                  MixtapeMetrics.screenSidePadding,
                  24,
                ),
                sliver: SliverList.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) => _SongRow(
                    entry: entries[index] as Map<String, dynamic>,
                    isFirst: index == 0,
                  ),
                ),
              ),
            ],
          ),
        ),
        // The current version is where the mix already is: there is
        // nothing to restore it to.
        if (!isCurrent)
          TapeBar(
            reason: unavailable
                ? Text(
                    'A song in this version is no longer available.',
                    key: const Key('mix-history-unavailable'),
                    textAlign: TextAlign.center,
                    style: tokens.meta.copyWith(color: tokens.muted),
                  )
                : null,
            primary: Center(
              child: TapeButton(
                label: 'Use this version',
                onPressed: _busy || unavailable ? null : _confirmRestore,
              ),
            ),
          ),
      ],
    );
  }
}

/// The user message that produced [version]: the last one before the reply
/// that carries it. Null when the transcript does not hold that reply (a
/// restore writes none, and an old mix may predate its history).
String? madeFromMessage(List<ChatMessage>? messages, int version) {
  if (messages == null) return null;
  final reply = messages.indexWhere(
    (m) => !m.isError && m.message.queueVersion == version,
  );
  if (reply < 0) return null;
  for (var i = reply - 1; i >= 0; i--) {
    final message = messages[i];
    if (!message.isError && message.message.role == 'user') {
      final text = message.message.content.trim();
      return text.isEmpty ? null : text;
    }
  }
  return null;
}

/// `.vh`: Now and Earlier.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 4),
      child: Semantics(
        header: true,
        child: Text(
          label.toUpperCase(),
          style: tokens.meta.copyWith(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.6,
            color: tokens.muted,
          ),
        ),
      ),
    );
  }
}

/// `.vask`: "Made from" and the message, centred under the header.
class _MadeFrom extends StatelessWidget {
  const _MadeFrom({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      key: const Key('mix-history-made-from'),
      margin: const EdgeInsets.fromLTRB(22, 6, 22, 12),
      padding: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.hairline)),
      ),
      child: Column(
        children: [
          Text(
            'MADE FROM',
            style: tokens.meta.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.5,
              color: tokens.muted,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            text,
            textAlign: TextAlign.center,
            style: tokens.body.copyWith(
              fontWeight: FontWeight.w600,
              color: tokens.smoke,
            ),
          ),
        ],
      ),
    );
  }
}

/// One saved version (`.vrow`): a 64 pt tilted cassette in the tape
/// colour, "Version n", "Today, 15:40 · N songs · M min", and the message
/// that made it, clamped to two lines — or "Restored from version n".
class _VersionRow extends StatelessWidget {
  const _VersionRow({
    super.key,
    required this.version,
    required this.caseColor,
    required this.madeFrom,
    required this.duration,
    required this.isFirst,
    required this.onTap,
  });

  final Map<String, dynamic> version;
  final Color caseColor;
  final String? madeFrom;
  final String? duration;
  final bool isFirst;
  final VoidCallback? onTap;

  static const double _tile = 64;

  static String metaFor(Map<String, dynamic> version, {String? duration}) {
    final count = version['trackCount'] as int? ?? 0;
    final createdAt = DateTime.tryParse(version['createdAt'] as String? ?? '');
    return [
      if (createdAt != null) versionTime(createdAt),
      '$count ${count == 1 ? 'song' : 'songs'}',
      ?duration,
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final from = version['restoredFrom'];
    final second = from != null
        ? 'Restored from version $from'
        : (madeFrom == null ? null : '“$madeFrom”');
    final meta = metaFor(version, duration: duration);
    return Semantics(
      button: onTap != null,
      label: [
        'Version ${version['version']}',
        meta,
        if (from != null)
          'Restored from version $from'
        else if (madeFrom != null)
          'Made from: $madeFrom',
      ].join('. '),
      onTap: onTap,
      excludeSemantics: true,
      child: FlushRow(
        leading: Transform.rotate(
          angle: TapeHeader.tilt,
          child: CassetteTile(width: _tile, caseColor: caseColor, shadow: true),
        ),
        leadingSize: _tile,
        isFirst: isFirst,
        title: 'Version ${version['version']}',
        subtitleWidget: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              meta,
              style: tokens.meta.copyWith(fontSize: 12.5, color: tokens.muted),
            ),
            if (second != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  second,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: tokens.meta.copyWith(
                    fontSize: 13.5,
                    height: 1.35,
                    color: tokens.smoke,
                  ),
                ),
              ),
          ],
        ),
        onTap: onTap,
      ),
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
      child: CupertinoAlertDialog(
        title: Text('Use version ${widget.version}?'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
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
        actions: [
          CupertinoDialogAction(
            // "Cancel" would read as "it did not happen", which is exactly
            // what an unconfirmed restore cannot promise: the request id is
            // kept on the screen, so closing leaves the retry available.
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: Text(_retry ? 'Close' : 'Cancel'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: _busy ? null : _run,
            child: Text(
              _retry ? 'Retry restore' : 'Use version ${widget.version}',
            ),
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
