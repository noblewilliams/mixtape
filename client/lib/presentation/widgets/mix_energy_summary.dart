import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/mix_history_provider.dart';
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
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(mixEnergyProvider((id: sessionId, version: version)))
      .when(
        data: (detail) => EnergyAssessment(detail: detail),
        loading: () => const SizedBox.shrink(),
        error: (_, _) => const SizedBox.shrink(),
      );
}
