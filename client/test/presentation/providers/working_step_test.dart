// Where a streamed turn has got to (turn steps spec 2026-11-13, "iOS
// client" → State).
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/presentation/providers/working_step.dart';

void main() {
  final t0 = DateTime(2026, 11, 13, 20);
  final t1 = t0.add(const Duration(seconds: 3));

  test('the stream opening is listening, once', () {
    final opened = WorkingStep.after(null, const TurnStreamOpened(), now: t0);
    expect(opened, WorkingStep.listening(t0));
    expect(
      identical(
        WorkingStep.after(opened, const TurnStreamOpened(), now: t1),
        opened,
      ),
      isTrue,
    );
  });

  test('a step it knows replaces the last, stamped with its arrival', () {
    final opened = WorkingStep.listening(t0);
    const crates = TurnStep('digging', scope: 'catalogue');
    expect(WorkingStep.after(opened, crates, now: t1), WorkingStep(crates, t1));
  });

  test('an unknown step, the session id and the same step change nothing', () {
    final digging = WorkingStep(
      const TurnStep('digging', scope: 'library', artists: ['Tems']),
      t0,
    );
    for (final progress in <TurnProgress>[
      const TurnStep('tuning'),
      const TurnSessionStarted('s1'),
      const TurnStep('digging', scope: 'library', artists: ['Tems']),
    ]) {
      expect(
        identical(WorkingStep.after(digging, progress, now: t1), digging),
        isTrue,
        reason: '$progress',
      );
    }
    expect(WorkingStep.after(null, const TurnStep('tuning'), now: t1), isNull);
    // The same step with other names is a new one.
    expect(
      WorkingStep.after(
        digging,
        const TurnStep('digging', scope: 'catalogue'),
        now: t1,
      ),
      WorkingStep(const TurnStep('digging', scope: 'catalogue'), t1),
    );
  });
}
