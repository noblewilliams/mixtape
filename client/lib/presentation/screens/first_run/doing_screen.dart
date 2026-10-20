/// Step 3 of 3, the doing page (board frames B4 to B7): the Apple library
/// sync with its live count, the Exportify quick start, the Spotify data
/// request, or the Apple export. The instruction copy is the request
/// screen's own (`spotify_request_screen.dart`), and the files go through the
/// existing import sheet and its review step unchanged.
///
/// The anonymous listener is created before a sync or an import starts:
/// both are user-scoped and reset on the auth transition.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../format/import_format.dart';
import '../../providers/device_providers.dart';
import '../../providers/library_sync_provider.dart';
import '../../providers/listening_import_provider.dart';
import '../../providers/onboarding_provider.dart';
import '../../theme/mixtape_theme.dart';
import '../../widgets/foundation/cassette_tile.dart';
import '../import_sheet.dart';
import '../spotify_request_screen.dart';
import 'choose_method_screen.dart';
import 'first_run_flow.dart';
import 'step_scaffold.dart';

class DoingScreen extends ConsumerStatefulWidget {
  const DoingScreen({
    super.key,
    required this.method,
    this.mode = AddMusicMode.firstRun,
  });

  final AddMethod method;
  final AddMusicMode mode;

  static const String syncHeadline = 'Syncing your library';
  static const String exportifyHeadline = 'Export from Exportify';
  static const String requestHeadline = 'Request your data';
  static const String appleExportHeadline = 'Upload an Apple export';

  static String songsSoFar(int n) => '${formatCount(n)} songs so far';
  static String songsIn(int n) => '${formatCount(n)} songs in.';
  static String stoppedAt(int n) => 'Sync stopped at ${formatCount(n)} songs.';

  static const Key statusKey = Key('doing-status');
  static const Key doneKey = Key('doing-done');
  static const Key retryKey = Key('doing-retry');
  static const Key continueKey = Key('doing-continue');
  static const Key openExportifyKey = Key('doing-open-exportify');
  static const Key chooseFilesKey = Key('doing-choose-files');
  static const Key requestedKey = Key('doing-requested');
  static const Key errorKey = Key('doing-error');
  static const Key cassetteKey = Key('doing-cassette');

  /// The sync count is a polite live region announced at most this often.
  static const Duration announceEvery = Duration(seconds: 10);

  @override
  ConsumerState<DoingScreen> createState() => _DoingScreenState();
}

class _DoingScreenState extends ConsumerState<DoingScreen> {
  /// Songs counted by the sync so far, kept through a failure.
  int _songs = 0;

  /// The anonymous sign-in before the sync or import could not finish.
  bool _sessionFailed = false;

  /// The sync was asked for on this page (an idle state after that is a
  /// cancelled run, which reads as stopped).
  bool _syncAsked = false;

  bool _busy = false;
  String? _error;

  /// The live region's label: the count, at most once per
  /// [DoingScreen.announceEvery]. A count that arrives inside the window
  /// waits in [_pendingAnnouncement] and is announced when the window
  /// closes, so the last count before a pause is still read.
  String? _announced;
  String? _pendingAnnouncement;
  Timer? _announceWindow;

  /// The failure has been announced (once per failure).
  bool _failureAnnounced = false;

  @override
  void dispose() {
    _announceWindow?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    if (widget.method == AddMethod.appleSync) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_startSync());
      });
    }
  }

  Future<void> _startSync() async {
    setState(() {
      _sessionFailed = false;
      _syncAsked = false;
    });
    try {
      await ensureAnonymousSession(ref);
    } catch (_) {
      if (mounted) setState(() => _sessionFailed = true);
      return;
    }
    if (!mounted) return;
    _rememberService();
    setState(() => _syncAsked = true);
    unawaited(ref.read(librarySyncProvider.notifier).sync());
  }

  /// The service this page belongs to, remembered on the device (and, for
  /// Spotify, posted as `chose_spotify`) once there is a listener to keep it
  /// for. Fire and forget, like the onboarding notifier's own posts.
  void _rememberService() {
    final onboarding = ref.read(onboardingProvider.notifier);
    // The anonymous listener was just created, so onboarding is reloading;
    // the notifier remembers a choice only over a loaded state, so wait for
    // this listener's load (never across a later auth change: the future is
    // taken now) and then record it.
    final loaded = ref
        .read(onboardingProvider.future)
        .then<void>((_) {}, onError: (Object _) {});
    switch (widget.method) {
      case AddMethod.appleSync || AddMethod.appleExport:
        unawaited(loaded.then((_) => onboarding.markChoseApple()));
      case AddMethod.exportify:
        unawaited(loaded.then((_) => onboarding.markChoseSpotify()));
      case AddMethod.spotifyExport:
        // Handled with the request itself, in order.
        break;
    }
  }

  void _finish(int songs) => finishAddMusic(context, widget.mode, songs: songs);

  Future<void> _chooseFiles() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ensureAnonymousSession(ref);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = firstRunErrorFor(e);
        });
      }
      return;
    }
    if (!mounted) return;
    _rememberService();
    setState(() => _busy = false);
    // An earlier run's result may still be in the provider; only a state
    // this visit produced may finish the step.
    final before = ref.read(listeningImportProvider);
    await openImportFlow(context, ref);
    if (!mounted) return;
    final after = ref.read(listeningImportProvider);
    if (identical(after, before)) return;
    final songs = switch (after) {
      ImportDone(:final result) ||
      ImportPartial(:final result) => result.summary.tracks,
      _ => null,
    };
    // A dismissed picker or an unfinished run leaves the listener here.
    if (songs != null) _finish(songs);
  }

  Future<void> _markRequested() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ensureAnonymousSession(ref);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = firstRunErrorFor(e);
        });
      }
      return;
    }
    if (!mounted) return;
    // Detached, like the request screen's: neither the funnel posts nor the
    // reminder can block or fail the tap. chose_spotify first, so Home's
    // waiting row knows the service.
    final onboarding = ref.read(onboardingProvider.notifier);
    final loaded = ref
        .read(onboardingProvider.future)
        .then<void>((_) {}, onError: (Object _) {});
    unawaited(() async {
      await loaded;
      await onboarding.markChoseSpotify();
      await onboarding.markRequested();
    }());
    unawaited(
      ref
          .read(reminderSchedulerProvider)
          .scheduleRequestReminder(after: requestReminderDelay)
          .catchError((Object _) {}),
    );
    setState(() => _busy = false);
    continueWithoutMusic(context, widget.mode);
  }

  /// Offers a count to the live region. The first count of a window is
  /// announced at once and opens a [DoingScreen.announceEvery] window; later
  /// ones wait for it to close, and the latest is announced then.
  void _offerCount(String text) {
    if (text == _announced || text == _pendingAnnouncement) return;
    if (_announceWindow?.isActive ?? false) {
      _pendingAnnouncement = text;
      return;
    }
    _announced = text;
    _pendingAnnouncement = null;
    _announceWindow = Timer(DoingScreen.announceEvery, _closeWindow);
  }

  void _closeWindow() {
    final pending = _pendingAnnouncement;
    if (!mounted || pending == null) return;
    setState(() {
      _announced = pending;
      _pendingAnnouncement = null;
    });
    _announceWindow = Timer(DoingScreen.announceEvery, _closeWindow);
  }

  /// The end of the run is read at once, whatever the window.
  void _announceNow(String text) {
    _announceWindow?.cancel();
    _pendingAnnouncement = null;
    _announced = text;
  }

  @override
  Widget build(BuildContext context) => switch (widget.method) {
    AddMethod.appleSync => _sync(context),
    AddMethod.exportify => _exportify(context),
    AddMethod.spotifyExport => _spotifyRequest(context),
    AddMethod.appleExport => _appleExport(context),
  };

  Widget _sync(BuildContext context) {
    final sync = ref.watch(librarySyncProvider);
    // Only this page's run counts: a result left from an earlier sync is
    // not what the listener is waiting for.
    if (_syncAsked) {
      switch (sync) {
        case SyncRunning(:final songs):
          // A retry uploads from the start again; what the earlier run
          // already sent is on the server, so the count never goes back.
          if (songs > _songs) _songs = songs;
        case SyncDone(:final summary):
          _songs = summary.songs;
        default:
          break;
      }
    }
    // A failure left from an earlier run is not this page's.
    final failed =
        _sessionFailed ||
        (_syncAsked && (sync is SyncFailed || sync is SyncIdle));
    final done = !failed && _syncAsked && sync is SyncDone;
    final running = !failed && !done;
    // Refused library access: only Settings helps, so say so rather than
    // the generic line.
    final deniedMessage = failed && sync is SyncFailed && sync.accessDenied
        ? sync.message
        : null;

    final status =
        deniedMessage ??
        (failed
            ? DoingScreen.stoppedAt(_songs)
            : done
            ? DoingScreen.songsIn(_songs)
            : DoingScreen.songsSoFar(_songs));
    if (failed) {
      if (!_failureAnnounced) {
        _failureAnnounced = true;
        _announceWindow?.cancel();
        _pendingAnnouncement = null;
        // An alert, read at once (approval → Accessibility).
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          unawaited(
            SemanticsService.announce(
              status,
              TextDirection.ltr,
              assertiveness: Assertiveness.assertive,
            ),
          );
        });
      }
    } else {
      _failureAnnounced = false;
      if (done) {
        _announceNow(status);
      } else {
        _offerCount(status);
      }
    }
    final tokens = context.tokens;
    final statusStyle = FirstRunType.line(
      tokens,
    ).copyWith(color: failed ? FirstRunColors.err : FirstRunColors.cream);

    return StepScaffold(
      background: FirstRunBackground.step3,
      headline: DoingScreen.syncHeadline,
      step: 3,
      top: Center(
        child: Transform.rotate(
          angle: 0.07,
          child: ExcludeSemantics(
            child: CassetteTile(
              key: DoingScreen.cassetteKey,
              width: 176,
              // The hubs turn while it works and stop on failure; the tile
              // holds them still under reduced motion.
              spinning: running,
              shadow: true,
            ),
          ),
        ),
      ),
      body: [
        const SizedBox(height: 12),
        Semantics(
          container: true,
          // A failure is announced once as an alert instead (above).
          liveRegion: !failed,
          label: failed ? status : _announced,
          excludeSemantics: true,
          child: Row(
            key: DoingScreen.statusKey,
            children: [
              if (failed) ...[
                const Icon(
                  Icons.error_outline,
                  size: 18,
                  color: FirstRunColors.err,
                ),
                const SizedBox(width: 8),
              ],
              Expanded(child: Text(status, style: statusStyle)),
            ],
          ),
        ),
      ],
      actions: [
        // The slot above Done is held for Retry so nothing moves on failure.
        Visibility(
          visible: failed,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: FirstRunPill(
            key: DoingScreen.retryKey,
            label: 'Retry',
            onPressed: failed ? () => unawaited(_startSync()) : null,
          ),
        ),
        if (failed)
          FirstRunPill(
            key: DoingScreen.continueKey,
            label: "Continue with what's in",
            forward: true,
            onPressed: () => _finish(_songs),
          )
        else
          FirstRunPill(
            key: DoingScreen.doneKey,
            label: 'Done',
            forward: true,
            onPressed: done ? () => _finish(_songs) : null,
          ),
      ],
    );
  }

  Widget _errorLine(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Semantics(
      liveRegion: true,
      child: Text(
        _error!,
        key: DoingScreen.errorKey,
        style: FirstRunType.line(
          context.tokens,
        ).copyWith(color: FirstRunColors.err),
      ),
    ),
  );

  Widget _exportify(BuildContext context) {
    final openLink = ref.watch(linkOpenerProvider);
    return StepScaffold(
      background: FirstRunBackground.step3,
      headline: DoingScreen.exportifyHeadline,
      step: 3,
      body: [
        const SizedBox(height: 18),
        for (var i = 0; i < exportifyQuickStartSteps.length; i++)
          _Step(number: i + 1, child: Text(exportifyQuickStartSteps[i])),
        if (_error != null) _errorLine(context),
      ],
      actions: [
        FirstRunPill(
          key: DoingScreen.openExportifyKey,
          label: 'Open Exportify',
          semanticsHint: 'opens outside Mixtape',
          trailing: const Icon(Icons.open_in_new),
          onPressed: () => unawaited(openLink(exportifyUrl)),
        ),
        FirstRunPill(
          key: DoingScreen.chooseFilesKey,
          label: 'Choose files',
          emphasis: true,
          leading: const Icon(Icons.insert_drive_file_outlined),
          onPressed: _busy ? null : () => unawaited(_chooseFiles()),
        ),
      ],
    );
  }

  Widget _spotifyRequest(BuildContext context) {
    final openLink = ref.watch(linkOpenerProvider);
    return StepScaffold(
      background: FirstRunBackground.step3,
      headline: DoingScreen.requestHeadline,
      step: 3,
      body: [
        const SizedBox(height: 18),
        for (var i = 0; i < spotifyRequestSteps.length; i++)
          _Step(
            number: i + 1,
            dense: true,
            child: _MarkupText(
              text: spotifyRequestSteps[i],
              address: spotifyPrivacyAddress,
              linkKey: const Key('doing-link-spotify-privacy'),
              onOpenAddress: () => unawaited(openLink(spotifyPrivacyUrl)),
            ),
          ),
        if (_error != null) _errorLine(context),
      ],
      actions: [
        FirstRunPill(
          key: DoingScreen.requestedKey,
          label: "I've requested it",
          forward: true,
          onPressed: _busy ? null : () => unawaited(_markRequested()),
        ),
      ],
    );
  }

  Widget _appleExport(BuildContext context) {
    final openLink = ref.watch(linkOpenerProvider);
    return StepScaffold(
      background: FirstRunBackground.step3,
      headline: DoingScreen.appleExportHeadline,
      step: 3,
      body: [
        const SizedBox(height: 18),
        for (var i = 0; i < appleRequestSteps.length; i++)
          _Step(
            number: i + 1,
            dense: true,
            child: _MarkupText(
              text: appleRequestSteps[i],
              address: applePrivacyAddress,
              linkKey: const Key('doing-link-apple-privacy'),
              onOpenAddress: () => unawaited(openLink(applePrivacyUrl)),
            ),
          ),
        if (_error != null) _errorLine(context),
      ],
      actions: [
        FirstRunPill(
          key: DoingScreen.chooseFilesKey,
          label: 'Choose files',
          emphasis: true,
          leading: const Icon(Icons.insert_drive_file_outlined),
          onPressed: _busy ? null : () => unawaited(_chooseFiles()),
        ),
      ],
    );
  }
}

/// One numbered instruction line (the board's `ol.steps`).
class _Step extends StatelessWidget {
  const _Step({required this.number, required this.child, this.dense = false});

  final int number;
  final Widget child;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final style = tokens.body.copyWith(
      fontSize: dense ? 14 : 15,
      height: dense ? 1.35 : 1.4,
      color: FirstRunColors.cream,
    );
    return Padding(
      padding: EdgeInsets.only(bottom: dense ? 6 : 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 24,
            child: Text(
              '$number.',
              style: style.copyWith(
                fontWeight: FontWeight.w600,
                color: FirstRunColors.cream.withValues(alpha: 0.8),
              ),
            ),
          ),
          Expanded(
            child: DefaultTextStyle.merge(style: style, child: child),
          ),
        ],
      ),
    );
  }
}

/// A step's `**bold**` / `*italic*` markup through the request screen's own
/// renderer, with [address] as the one tappable run.
class _MarkupText extends StatelessWidget {
  const _MarkupText({
    required this.text,
    required this.address,
    required this.linkKey,
    required this.onOpenAddress,
  });

  final String text;
  final String address;
  final Key linkKey;
  final VoidCallback onOpenAddress;

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    return Text.rich(
      TextSpan(
        style: style,
        children: requestCopySpans(
          text,
          addressText: address,
          address: (value) => InkWell(
            key: linkKey,
            onTap: onOpenAddress,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                value,
                style: style.copyWith(
                  fontWeight: FontWeight.bold,
                  decoration: TextDecoration.underline,
                  decorationColor: FirstRunColors.cream,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
