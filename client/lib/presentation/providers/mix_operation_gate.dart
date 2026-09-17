import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'auth_provider.dart';

enum MixOperation { sending, selectingInspiration }

/// Sending a turn and changing its inspiration must not race. A lease keeps
/// the gate alive until its request settles, even if its screen goes away.
class MixOperationGate extends Notifier<MixOperation?> {
  MixOperationGate(this.sessionId);
  final String sessionId;
  int _generation = 0;
  int _lease = 0;

  @override
  MixOperation? build() {
    ref.watch(authProvider);
    _generation++;
    ref.onDispose(() => _generation++);
    return null;
  }

  void Function()? acquire(MixOperation operation) {
    if (!ref.mounted ||
        ref.read(authProvider) != AuthStatus.signedIn ||
        state != null) {
      return null;
    }
    final generation = _generation;
    final lease = ++_lease;
    final keepAlive = ref.keepAlive();
    var released = false;
    state = operation;
    return () {
      if (released) return;
      released = true;
      if (ref.mounted && generation == _generation && lease == _lease) {
        state = null;
      }
      keepAlive.close();
    };
  }
}

final mixOperationProvider = NotifierProvider.autoDispose
    .family<MixOperationGate, MixOperation?, String>(MixOperationGate.new);
