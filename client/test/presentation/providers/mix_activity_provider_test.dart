// What the Mixes list knows about turns in flight and replies not yet seen
// (device smoke 2026-11-13).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/dj/dj_api.dart' show TurnStep;
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/mix_activity_provider.dart';
import 'package:mixtape/presentation/providers/working_step.dart';

class _Auth extends AuthNotifier {
  @override
  AuthStatus build() => AuthStatus.session;

  void flip(AuthStatus next) => state = next;
}

DjSession _session(String id, DateTime updatedAt) => DjSession(
  id: id,
  title: id,
  status: 'active',
  queueVersion: 1,
  updatedAt: updatedAt,
);

void main() {
  late ProviderContainer container;
  MixActivityNotifier notifier() => container.read(mixActivityProvider.notifier);
  MixActivity activity() => container.read(mixActivityProvider);

  setUp(() {
    container = ProviderContainer(
      overrides: [authProvider.overrideWith(_Auth.new)],
    );
    addTearDown(container.dispose);
  });

  test('a turn is working while it is out, then ready until seen', () {
    final end = notifier().beginTurn('a');
    expect(activity().isWorking('a'), isTrue);
    expect(activity().workingSince('a'), isNotNull);
    expect(activity().isReady('a'), isFalse);

    end(ready: true);
    expect(activity().isWorking('a'), isFalse);
    expect(activity().isReady('a'), isTrue);

    notifier().seen('a');
    expect(activity().isReady('a'), isFalse);
  });

  test('a turn taken back leaves nothing to see', () {
    final end = notifier().beginTurn('a');
    end(ready: false);
    expect(activity().isWorking('a'), isFalse);
    expect(activity().isReady('a'), isFalse);
  });

  test('ending twice, or after the listener changed, does nothing', () {
    final end = notifier().beginTurn('a');
    end(ready: true);
    notifier().seen('a');
    end(ready: true);
    expect(activity().isReady('a'), isFalse);

    final stale = notifier().beginTurn('b');
    (container.read(authProvider.notifier) as _Auth).flip(
      AuthStatus.noSession,
    );
    expect(activity().isWorking('b'), isFalse);
    stale(ready: true);
    expect(activity().isReady('b'), isFalse);
  });

  test('a new mix is pending until the server names it, then ready', () {
    final end = notifier().beginNewMix('a rainy drive home');
    expect(activity().pending?.prompt, 'a rainy drive home');

    end(sessionId: 'new');
    expect(activity().pending, isNull);
    expect(activity().isReady('new'), isTrue);
  });

  test('a new mix that failed before a row existed leaves nothing', () {
    final end = notifier().beginNewMix('a rainy drive home');
    end();
    expect(activity().pending, isNull);
    expect(activity().ready, isEmpty);
  });

  group('where a turn has got to (turn steps 2026-11-13)', () {
    final at = DateTime(2026, 11, 13, 21);
    final crates = WorkingStep(
      const TurnStep('digging', scope: 'catalogue'),
      at,
    );

    test('a turn\'s step rides its working entry until the turn ends', () {
      final turn = notifier().beginTurn('a');
      expect(activity().workingStep('a'), isNull);
      final working = activity().working;
      turn.step(crates);
      expect(activity().workingStep('a'), crates);
      expect(activity().workingSince('a'), isNotNull);
      // A step leaves the working map as it was, so the list does not
      // rebuild for it.
      expect(activity().working, same(working));

      turn(ready: true);
      expect(activity().workingStep('a'), isNull);
      // A step after the end writes nothing.
      turn.step(crates);
      expect(activity().isWorking('a'), isFalse);
    });

    test('an earlier turn\'s step never lands on a later one', () async {
      final first = notifier().beginTurn('a');
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final second = notifier().beginTurn('a');
      first.step(crates);
      expect(activity().workingStep('a'), isNull);
      second.step(crates);
      expect(activity().workingStep('a'), crates);
    });

    test('a new mix carries its step, and the id the server gave it', () {
      final made = notifier().beginNewMix('a rainy drive home');
      final named = activity().pending;
      made.step(crates);
      expect(activity().pendingStep, crates);
      // A step leaves the pending row as it was, so the list does not
      // rebuild for it.
      expect(activity().pending, same(named));
      made.named('new');
      expect(activity().pending?.sessionId, 'new');
      expect(activity().pending?.prompt, 'a rainy drive home');
      expect(activity().pendingStep, crates);

      made(sessionId: 'new');
      expect(activity().pending, isNull);
      expect(activity().pendingStep, isNull);
      made.step(crates);
      expect(activity().pendingStep, isNull);
    });

    test('a new mix that knows its id adopts exactly that row', () {
      final start = DateTime(2026, 11, 13, 22);
      final pending = PendingMix(
        prompt: 'p',
        startedAt: start,
        knownIds: const {'old'},
        sessionId: 'mine',
      );
      // Another device's new mix is not this one.
      expect(pending.adopt([_session('theirs', start)]), isNull);
      expect(
        pending.adopt([_session('theirs', start), _session('mine', start)]),
        'mine',
      );
    });
  });

  group('a list read while a new mix is being made', () {
    final start = DateTime(2026, 11, 13, 22);

    test('names the row that was not there when it started', () {
      final pending = PendingMix(
        prompt: 'p',
        startedAt: start,
        knownIds: const {'old'},
      );
      expect(
        pending.adopt([
          _session('old', start.add(const Duration(minutes: 5))),
          _session('new', start),
        ]),
        'new',
      );
      expect(pending.adopt([_session('old', start)]), isNull);
    });

    test('without a list to compare, the newest row made since', () {
      final pending = PendingMix(prompt: 'p', startedAt: start);
      expect(
        pending.adopt([
          _session('older', start.subtract(const Duration(hours: 2))),
          _session('new', start.add(const Duration(seconds: 1))),
        ]),
        'new',
      );
      expect(
        pending.adopt([
          _session('older', start.subtract(const Duration(hours: 2))),
        ]),
        isNull,
      );
    });
  });
}
