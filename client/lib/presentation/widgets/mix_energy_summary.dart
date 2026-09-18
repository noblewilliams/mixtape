/// The energy line under the tape card
/// (`docs/mockups/approved/2026-09-17-mobile-conversation-states.md`;
/// `.energy` and frame C1 on
/// `docs/mockups/2026-09-17-mobile-conversation-states.html`).
///
/// One quiet line: the wave glyph and the shape the DJ actually managed,
/// against the ask — "limited coverage" honestly when fewer than two thirds of
/// the songs have known energy. Silent while the version detail loads or if it
/// cannot be read: the conversation is readable without it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/mix_history_provider.dart';
import '../theme/mixtape_theme.dart';
import 'energy_journey.dart';

final mixEnergyProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, ({String id, int version})>(
      (ref, key) => ref.watch(mixHistoryApiProvider).read(key.id, key.version),
      retry: (_, _) => null,
    );

class MixEnergySummary extends ConsumerWidget {
  const MixEnergySummary({
    super.key,
    required this.sessionId,
    required this.version,
  });

  final String sessionId;
  final int version;

  static const Key lineKey = Key('energy-line');

  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(mixEnergyProvider((id: sessionId, version: version)))
      .when(
        data: (detail) {
          final line = energyLine(detail);
          if (line == null) return const SizedBox.shrink();
          return EnergyLine(text: line);
        },
        loading: () => const SizedBox.shrink(),
        error: (_, _) => const SizedBox.shrink(),
      );
}

/// `.energy`: the wave glyph and the verdict in meta muted, flush left.
class EnergyLine extends StatelessWidget {
  const EnergyLine({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      key: MixEnergySummary.lineKey,
      padding: const EdgeInsets.only(left: 2, top: 2, bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: EnergyWave(
              arc: EnergyArc.arc,
              width: 16,
              height: 11,
              color: tokens.muted,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: tokens.meta.copyWith(color: tokens.muted),
            ),
          ),
        ],
      ),
    );
  }
}
