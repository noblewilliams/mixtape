/// Where a streamed mix turn has got to, for the DJ's working line (spec
/// `docs/superpowers/specs/2026-11-13-dj-turn-steps-design.md`, "iOS
/// client"): the latest step the turn reported and when it arrived.
///
/// It rides on [ChatState] and on the Mixes activity's working entry, so a
/// conversation reopened in the same app process picks up the step its turn
/// is on, as it picks up when the turn went out.
library;

import '../../data/dj/dj_api.dart'
    show TurnProgress, TurnStep, TurnStreamOpened;

class WorkingStep {
  /// The stream opened and no step has come yet: the DJ is listening.
  const WorkingStep.listening(this.at) : step = null;

  const WorkingStep(TurnStep this.step, this.at);

  /// The latest step; null while the DJ is listening.
  final TurnStep? step;

  /// When [step] arrived (or the stream opened), on this device's clock.
  final DateTime at;

  /// The steps the working line has words for (the spec's step table). The
  /// server may add steps; a client keeps its line through one not here.
  static const Set<String> known = {
    'listening',
    'playlists',
    'digging',
    'picking',
    'checking',
    'editing',
    'pressing',
    'labelling',
    'noting',
    'writing',
  };

  /// [current] once [progress] has arrived, at [now]. [current] itself when
  /// [progress] changes nothing: a step not in [known], the same step again
  /// (its clock keeps running), the create's session id, or a second open.
  static WorkingStep? after(
    WorkingStep? current,
    TurnProgress progress, {
    DateTime? now,
  }) => switch (progress) {
    TurnStreamOpened() =>
      current ?? WorkingStep.listening(now ?? DateTime.now()),
    final TurnStep step when known.contains(step.step) =>
      current?.step == step
          ? current
          : WorkingStep(step, now ?? DateTime.now()),
    _ => current,
  };

  @override
  bool operator ==(Object other) =>
      other is WorkingStep && other.step == step && other.at == at;

  @override
  int get hashCode => Object.hash(step, at);

  @override
  String toString() => 'WorkingStep($step, at: $at)';
}
