/// Archiving and unarchiving a mix, with the toast that follows: shared by the
/// Mixes tab and its Archived screen so both say the same thing and both
/// offer Undo.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/dj_providers.dart';
import '../widgets/foundation/mixtape_feedback.dart';

const archiveFailedMessage = "couldn't archive — try again";
const unarchiveFailedMessage = "couldn't unarchive — try again";

/// How long the success toast and its Undo stay up.
const archiveUndoDuration = Duration(seconds: 3);

/// Moves mix [id] into or out of the archive. The provider moves the row once
/// the server agrees; a failure leaves it where it was and says so.
Future<bool> setMixArchived(
  BuildContext context,
  WidgetRef ref,
  String id, {
  required bool archived,
}) async {
  // Everything the toast needs is taken now: the screen may be gone by the
  // time the request, or the Undo, comes back.
  final notifier = ref.read(sessionsProvider.notifier);
  final messenger = ScaffoldMessenger.of(context);
  final accessible = MediaQuery.accessibleNavigationOf(context);

  final ok = archived
      ? await notifier.archive(id)
      : await notifier.unarchive(id);
  if (!messenger.mounted) return ok;
  messenger.hideCurrentSnackBar();
  if (!ok) {
    messenger.showSnackBar(
      mixtapeSnackBar(
        message: archived ? archiveFailedMessage : unarchiveFailedMessage,
        kind: FeedbackKind.error,
      ),
    );
    return ok;
  }
  messenger.showSnackBar(
    mixtapeSnackBar(
      message: archived ? 'Mix archived' : 'Mix unarchived',
      kind: FeedbackKind.success,
      duration: accessible ? const Duration(days: 1) : archiveUndoDuration,
      actionLabel: 'Undo',
      onAction: () async {
        messenger.hideCurrentSnackBar();
        final undone = archived
            ? await notifier.unarchive(id)
            : await notifier.archive(id);
        if (!undone && messenger.mounted) {
          messenger.showSnackBar(
            mixtapeSnackBar(
              message: archived ? unarchiveFailedMessage : archiveFailedMessage,
              kind: FeedbackKind.error,
            ),
          );
        }
      },
    ),
  );
  return ok;
}
