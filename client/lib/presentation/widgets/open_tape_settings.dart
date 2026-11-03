import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/dj_providers.dart';
import 'mix_tape_colour.dart';
import 'tape_settings_dialog.dart';

/// Opens the tape settings sheet for [sessionId]. Uses the collection's
/// canonical metadata when the conversation is still open. A colour change
/// never reloads or interrupts an in-flight DJ conversation; a new name goes
/// through the conversation when it is open, so its title follows.
Future<void> openTapeSettings(
  BuildContext context,
  WidgetRef ref,
  String sessionId,
) async {
  final saved = ref.read(sessionsProvider).value;
  final chat = ref.read(chatProvider(sessionId)).value?.session;
  final session =
      saved?.where((mix) => mix.id == sessionId).firstOrNull ?? chat;
  if (session == null) return;
  await showTapeSettingsSheet(
    context,
    title: chat?.title ?? session.title,
    initialColor: currentMixTapeHex(ref, sessionId, saved: session.caseColor),
    onSave: (colour) =>
        ref.read(sessionsProvider.notifier).setCaseColor(sessionId, colour),
    onRename: (name) => chat != null
        ? ref.read(chatProvider(sessionId).notifier).rename(name)
        : ref.read(sessionsProvider.notifier).rename(sessionId, name),
  );
}
