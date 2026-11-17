/// What select mode does on the Mixes tab and its Archived screen
/// (`docs/mockups/approved/2026-11-16-select-delete-mixes.md`): which rows
/// are ticked, the toolbar's Archive and Delete, the confirm, the signed-out
/// popover, and the toasts. Both screens mix it in, so both behave alike.
library;

import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dj/dj_api.dart' show SignInRequiredException;
import '../../data/dj/dj_models.dart';
import '../providers/auth_provider.dart';
import '../providers/dj_providers.dart';
import '../providers/shell_providers.dart';
import '../widgets/foundation/glass_cluster.dart';
import '../widgets/foundation/mixtape_feedback.dart';
import '../widgets/foundation/mixtape_menu.dart';
import '../widgets/mix_select_mode.dart';
import 'mix_archive_feedback.dart';
import 'shell/shell_route_observer.dart' show ShellTabScope;
import 'sign_in_screen.dart' show openKeepMixesSignIn;

mixin MixSelectFlow<W extends ConsumerStatefulWidget> on ConsumerState<W> {
  bool _selecting = false;
  final Set<String> _selected = {};
  final Set<String> _deleting = {};
  bool _busy = false;
  DockTakeoverNotifier? _takeover;

  /// The own mixes this list can tick, in list order.
  List<DjSession> get selectableSessions;

  /// Mixes the DJ is still making (the confirm says it will stop).
  Set<String> get workingIds;

  /// Archived's list: Unarchive in Archive's place.
  bool get archivedList;

  bool get selecting => _selecting;
  bool isSelected(String id) => _selected.contains(id);
  bool isDeleting(String id) => _deleting.contains(id);
  int get selectedCount => _selected.length;

  bool get allSelected {
    final ids = selectableSessions.map((s) => s.id);
    return ids.isNotEmpty && ids.every(_selected.contains);
  }

  /// Opens select mode, with [id] already ticked when the row menu's Select
  /// opened it. The toolbar takes the dock's place.
  void enterSelect([String? id]) {
    setState(() {
      _selecting = true;
      _selected.clear();
      if (id != null) _selected.add(id);
    });
    final takeover = ref.read(dockTakeoverProvider.notifier)..hold(this);
    _takeover = takeover;
    if (id != null) _announceCount();
  }

  void exitSelect() {
    if (!_selecting) return;
    setState(() {
      _selecting = false;
      _selected.clear();
      _deleting.clear();
    });
    _takeover?.release(this);
    _takeover = null;
  }

  void toggleSelected(String id) {
    if (_busy) return;
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
    _announceCount();
  }

  /// Select all ticks every own mix on this list; Deselect all clears them.
  void toggleAll() {
    if (_busy) return;
    final all = allSelected;
    setState(() {
      _selected.clear();
      if (!all) _selected.addAll(selectableSessions.map((s) => s.id));
    });
    _announceCount();
  }

  /// Ends select mode when another tab comes up, so the dock it holds comes
  /// back there, whichever screen of this tab holds it (Mixes, or Archived
  /// pushed over it). Called from build; outside the shell there is no tab.
  void exitSelectOnTabChange(BuildContext context) {
    final tab = ShellTabScope.maybeOf(context);
    if (tab == null) return;
    ref.listen<int>(selectedTabProvider, (previous, next) {
      if (previous != next && next != tab) exitSelect();
    });
  }

  /// Drops ticks on mixes that left the list (a refresh, another device).
  void pruneSelection() {
    if (!_selecting || _busy) return;
    final present = selectableSessions.map((s) => s.id).toSet();
    _selected.retainWhere(present.contains);
  }

  @override
  void dispose() {
    final takeover = _takeover;
    if (takeover != null) {
      // Not inside the tree's teardown: a provider must not change while
      // the tree finalises.
      scheduleMicrotask(() {
        try {
          takeover.release(this);
        } catch (_) {
          // The container went with the screen (a sign-out).
        }
      });
    }
    super.dispose();
  }

  void _announce(
    String message, {
    Assertiveness assertiveness = Assertiveness.polite,
  }) {
    if (!mounted) return;
    unawaited(
      SemanticsService.sendAnnouncement(
        View.of(context),
        message,
        Directionality.maybeOf(context) ?? TextDirection.ltr,
        assertiveness: assertiveness,
      ),
    );
  }

  void _announceCount() => _announce(MixSelect.count(_selected.length));

  List<String> get _orderedSelection => [
    for (final s in selectableSessions)
      if (_selected.contains(s.id)) s.id,
  ];

  /// The nav bar while selecting: Select all / Deselect all (leading pill)
  /// and the ✓ Done circle (trailing).
  Widget selectAllButton() => GlassLabelButton(
    key: MixSelect.selectAllKey,
    label: allSelected ? MixSelect.deselectAllLabel : MixSelect.selectAllLabel,
    onPressed: selectableSessions.isEmpty ? null : toggleAll,
  );

  Widget doneButton() => GlassButton(
    key: MixSelect.doneKey,
    icon: CupertinoIcons.checkmark,
    label: MixSelect.doneLabel,
    onPressed: exitSelect,
  );

  /// The ⋯ circle outside select mode, with its one item, Select mixes.
  Widget moreButton() => Builder(
    builder: (anchor) => GlassButton(
      key: MixSelect.moreKey,
      icon: CupertinoIcons.ellipsis,
      label: MixSelect.moreLabel,
      onPressed: () async {
        final choice = await showMixtapeMenu<String>(
          anchor,
          actions: const [
            MixtapeMenuAction(
              key: MixSelect.selectMixesKey,
              value: 'select',
              label: MixSelect.selectMixesLabel,
              icon: MixMenuIcons.select,
            ),
          ],
        );
        if (choice == 'select' && mounted) enterSelect();
      },
    ),
  );

  /// The toolbar, placed where the tab bar sits.
  Widget selectToolbar(BuildContext context) => Positioned(
    left: 22,
    right: 22,
    bottom:
        MediaQuery.viewPaddingOf(context).bottom + MixSelect.toolbarBottomGap,
    child: MixSelectToolbar(
      count: _selected.length,
      unarchive: archivedList,
      onArchive: _archiveSelected,
      onDelete: _deleteSelected,
    ),
  );

  void _toast(
    ScaffoldMessengerState messenger,
    String message,
    FeedbackKind kind, {
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 4),
  }) {
    if (!messenger.mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      mixtapeSnackBar(
        message: message,
        kind: kind,
        actionLabel: actionLabel,
        onAction: onAction,
        duration: duration,
      ),
    );
  }

  /// Archive (Unarchive on Archived) asks nothing: each ticked mix takes the
  /// one-mix path, then one toast with Undo for all of them. A mix the
  /// server refused stays ticked, and select mode stays up for it.
  Future<void> _archiveSelected() async {
    if (_busy) return;
    final ids = _orderedSelection;
    if (ids.isEmpty) return;
    final unarchive = archivedList;
    final notifier = ref.read(sessionsProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final accessible = MediaQuery.accessibleNavigationOf(context);
    _busy = true;
    final List<bool> results;
    try {
      results = await Future.wait([
        for (final id in ids)
          unarchive ? notifier.unarchive(id) : notifier.archive(id),
      ]);
    } finally {
      _busy = false;
    }
    final done = [
      for (var i = 0; i < ids.length; i++)
        if (results[i]) ids[i],
    ];
    final failed = ids.where((id) => !done.contains(id)).toSet();
    if (!mounted) return;
    if (failed.isNotEmpty) {
      setState(() => _selected.retainAll(failed));
      _toast(
        messenger,
        unarchive ? unarchiveFailedMessage : archiveFailedMessage,
        FeedbackKind.error,
      );
      return;
    }
    exitSelect();
    _toast(
      messenger,
      MixSelect.archived(done.length, unarchive: unarchive),
      FeedbackKind.success,
      duration: accessible ? const Duration(days: 1) : archiveUndoDuration,
      actionLabel: 'Undo',
      onAction: () async {
        messenger.hideCurrentSnackBar();
        final undone = await Future.wait([
          for (final id in done)
            unarchive ? notifier.archive(id) : notifier.unarchive(id),
        ]);
        if (undone.contains(false)) {
          _toast(
            messenger,
            unarchive ? archiveFailedMessage : unarchiveFailedMessage,
            FeedbackKind.error,
          );
        }
      },
    );
  }

  /// Delete: signed out, the sign-in popover; otherwise the confirm anchored
  /// to Delete, then the rows fade while the server deletes. Success ends
  /// select mode with a toast; a failure brings the rows back still ticked.
  Future<void> _deleteSelected(BuildContext anchor) async {
    if (_busy) return;
    final ids = _orderedSelection;
    if (ids.isEmpty) return;
    if (ref.read(isAnonymousProvider)) {
      await _askSignIn(anchor);
      return;
    }
    final known = ref.read(knownSharedMixesProvider);
    final shared = selectableSessions
        .where((s) => _selected.contains(s.id))
        .any(known.isShared);
    final working = ids.any(workingIds.contains);
    final confirmed = await showMixtapeConfirm<bool>(
      anchor,
      title: MixSelect.confirmTitle(ids.length),
      lines: [
        MixSelect.goneLine,
        if (shared) MixSelect.sharedLine,
        if (working) MixSelect.workingLine,
      ],
      actions: [
        MixtapeConfirmAction(
          key: MixSelect.confirmDeleteKey,
          value: true,
          label: MixSelect.confirmAction(ids.length),
          isDestructive: true,
        ),
        const MixtapeConfirmAction(
          key: MixSelect.cancelKey,
          value: false,
          label: MixSelect.cancelLabel,
        ),
      ],
    );
    if (confirmed != true || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _deleting.addAll(ids);
    });
    try {
      final deleted = await ref
          .read(sessionsProvider.notifier)
          .deleteSessions(ids);
      if (!mounted) return;
      _busy = false;
      exitSelect();
      // Only what the server deleted: ids it skipped were already gone.
      if (deleted.isNotEmpty) {
        _toast(
          messenger,
          MixSelect.deleted(deleted.length),
          FeedbackKind.success,
        );
      }
    } on SignInRequiredException {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _deleting.clear();
      });
      if (anchor.mounted) await _askSignIn(anchor);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _deleting.clear();
      });
      _toast(messenger, MixSelect.deleteFailed, FeedbackKind.error);
      _announce(MixSelect.deleteFailed, assertiveness: Assertiveness.assertive);
    }
  }

  /// "Sign in to delete mixes" (board S7): Sign in goes to the existing
  /// sign-in page, and the anonymous mixes come along as today.
  Future<void> _askSignIn(BuildContext anchor) async {
    final choice = await showMixtapeConfirm<bool>(
      anchor,
      title: MixSelect.signInTitle,
      lines: const [MixSelect.signInLine],
      actions: const [
        MixtapeConfirmAction(
          key: MixSelect.signInKey,
          value: true,
          label: MixSelect.signInLabel,
        ),
        MixtapeConfirmAction(
          key: MixSelect.notNowKey,
          value: false,
          label: MixSelect.notNowLabel,
        ),
      ],
    );
    if (choice == true && mounted) await openKeepMixesSignIn(context);
  }
}
