/// The one place a mix's tape colour is decided
/// (`docs/mockups/approved/2026-11-03-mix-conversation-redesign.md` → Tape
/// colour): every cassette drawn for a mix — the strip, the version markers,
/// the tape header, the versions list, the Mixes rows — asks here, so none of
/// them can drift back to hashing the mix id while a colour is saved.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/dj_providers.dart';
import 'foundation/cassette_tile.dart';
import 'tape_palette.dart';

/// The saved colour when there is a valid one, else the colour the mix id
/// seeds. The seeded colour is the one the mix has always been shown in, so
/// a mix with nothing saved never appears to change.
Color resolveMixTapeColour(String sessionId, {String? saved}) =>
    tapeColor(saved) ?? CassetteTile.caseColorFor(sessionId);

/// The saved hex for [sessionId] from the Mixes summaries — the list every
/// tape colour write lands in first ([SessionsNotifier.setCaseColor]).
String? _summaryHex(WidgetRef ref, String sessionId) => ref.watch(
  sessionsProvider.select(
    (sessions) => sessions.value
        ?.where((session) => session.id == sessionId)
        .firstOrNull
        ?.caseColor,
  ),
);

/// The colour to draw [sessionId]'s cassettes in, rebuilding when it changes.
///
/// The Mixes summaries win because a colour picked in tape settings lands
/// there; [saved] (the conversation's own copy of the session, which a
/// colour write does not touch) covers a mix the list has not loaded.
Color watchMixTapeColour(WidgetRef ref, String sessionId, {String? saved}) {
  final listed = _summaryHex(ref, sessionId);
  return resolveMixTapeColour(
    sessionId,
    saved: tapeColor(listed) != null ? listed : saved,
  );
}

/// The hex of the colour [sessionId] is shown in right now, for the tape
/// settings sheet: it opens on that colour's family.
String currentMixTapeHex(WidgetRef ref, String sessionId, {String? saved}) {
  final summaries = ref.read(sessionsProvider).value;
  final listed = summaries
      ?.where((session) => session.id == sessionId)
      .firstOrNull
      ?.caseColor;
  return tapeHex(
    resolveMixTapeColour(
      sessionId,
      saved: tapeColor(listed) != null ? listed : saved,
    ),
  );
}
