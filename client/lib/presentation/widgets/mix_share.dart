/// Share and Stop sharing for a mix (spec 2026-11-13 shared-mixes → Sender;
/// board frames S1–S6, approved in
/// `docs/mockups/approved/2026-11-13-shared-mixes.md`).
///
/// Both live in the header ⋯ menus of the conversation and the tape, as
/// their own group at the top. Share shows on a mix with at least one song,
/// never on an album session; Stop sharing shows only while the mix has an
/// active link. Share asks the server for the link (the name page first
/// when the server needs a name), then opens the system share sheet. Stop
/// sharing confirms with a native alert, then revokes every link.
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dj/dj_api.dart';
import '../../data/dj/dj_models.dart';
import '../providers/device_providers.dart';
import '../providers/dj_providers.dart';
import '../screens/first_run/name_screen.dart';
import 'foundation/mixtape_menu.dart';

abstract final class MixShare {
  static const String shareValue = 'share';
  static const String stopValue = 'stop-sharing';

  static const String shareLabel = 'Share';
  static const String stopLabel = 'Stop sharing';
  static const String stopTitle = 'Stop sharing?';
  static const String stopMessage =
      "People with the link won't be able to open it.";
  static const String shareFailed = "Couldn't share this mix. Try again.";
  static const String stopFailed = "Couldn't stop sharing this mix. Try again.";

  /// The text the share sheet carries with the link.
  static String text(String title) => 'Listen to my mix “$title” on Mixtape';

  /// The menu's Share group for [state]; empty when there is nothing to
  /// offer. The caller puts a separator before the entry that follows.
  static List<MixtapeMenuAction<String>> menuActions(ChatState? state) {
    if (state == null || state.kind == SessionKind.album) return const [];
    return [
      if (state.queue.isNotEmpty)
        const MixtapeMenuAction(
          value: shareValue,
          label: shareLabel,
          icon: MixMenuIcons.share,
        ),
      if (state.shared)
        const MixtapeMenuAction(
          value: stopValue,
          label: stopLabel,
          icon: MixMenuIcons.stopSharing,
        ),
    ];
  }

  /// Runs [action] when it is one of the Share group's; false otherwise.
  /// [origin] anchors the share sheet on iPad; [onError] shows the toast.
  static Future<bool> handle(
    BuildContext context,
    WidgetRef ref,
    String sessionId,
    String action, {
    required void Function(String message) onError,
    Rect? origin,
  }) async {
    switch (action) {
      case shareValue:
        await share(context, ref, sessionId, onError: onError, origin: origin);
        return true;
      case stopValue:
        await stop(context, ref, sessionId, onError: onError);
        return true;
    }
    return false;
  }

  /// The ⋯ button's place on screen, for the iPad popover.
  static Rect? originOf(BuildContext anchor) {
    final box = anchor.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  /// Share: the link, then the system sheet. A `name_required` pushes the
  /// name page (no Skip); a saved name asks again at once.
  static Future<void> share(
    BuildContext context,
    WidgetRef ref,
    String sessionId, {
    required void Function(String message) onError,
    Rect? origin,
  }) async {
    final api = ref.read(djApiProvider);
    final sheet = ref.read(shareSheetProvider);
    final chat = ref.read(chatProvider(sessionId).notifier);
    final title = ref.read(chatProvider(sessionId)).value?.session.title ?? '';
    final navigator = Navigator.of(context);

    ShareLinkResult link;
    try {
      link = await api.shareSession(sessionId);
    } on ShareNameRequiredException {
      if (!context.mounted) return;
      final named = await navigator.push(NameScreen.shareRoute());
      if (named != true || !context.mounted) return;
      try {
        link = await api.shareSession(sessionId);
      } catch (_) {
        if (context.mounted) onError(shareFailed);
        return;
      }
    } catch (_) {
      if (context.mounted) onError(shareFailed);
      return;
    }
    chat.setShared(true);
    try {
      await sheet.share(text: text(title), url: link.url, origin: origin);
    } catch (_) {
      if (context.mounted) onError(shareFailed);
    }
  }

  /// Stop sharing: the alert, then the revoke. No toast on success; the
  /// menu loses Stop sharing.
  static Future<void> stop(
    BuildContext context,
    WidgetRef ref,
    String sessionId, {
    required void Function(String message) onError,
  }) async {
    final api = ref.read(djApiProvider);
    final chat = ref.read(chatProvider(sessionId).notifier);
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => CupertinoAlertDialog(
        title: const Text(stopTitle),
        content: const Text(stopMessage),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text(stopLabel),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await api.stopSharing(sessionId);
      chat.setShared(false);
    } catch (_) {
      if (context.mounted) onError(stopFailed);
    }
  }
}
