import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/dj_providers.dart';
import 'foundation/cassette_tile.dart';
import 'tape_settings_dialog.dart';

/// Uses the collection's canonical metadata when the conversation is still open.
/// A colour change never reloads or interrupts an in-flight DJ conversation.
Future<void> openTapeSettings(
  BuildContext context,
  WidgetRef ref,
  String sessionId,
) async {
  final saved = ref.read(sessionsProvider).value;
  final session = saved?.where((mix) => mix.id == sessionId).firstOrNull ??
      ref.read(chatProvider(sessionId)).value?.session;
  if (session == null) return;
  final fallback = CassetteTile.caseColorFor(sessionId)
      .toARGB32()
      .toRadixString(16)
      .substring(2);
  await showDialog<void>(
    context: context,
    builder: (_) => TapeSettingsDialog(
      title: session.title,
      initialColor: session.caseColor ?? '#$fallback',
      onSave: (colour) =>
          ref.read(sessionsProvider.notifier).setCaseColor(sessionId, colour),
    ),
  );
}
