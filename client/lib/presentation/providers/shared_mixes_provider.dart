/// The shared mixes the listener saved, for Mixes (spec 2026-11-13
/// shared-mixes → Recipient in the app): `GET /me/shared-mixes`, newest save
/// first. A share its sender stopped is simply missing from the next read.
///
/// User-scoped: it watches [authProvider], so an auth transition reads the
/// list again for whoever is signed in next. No automatic retry: a failed
/// read leaves Mixes on the listener's own mixes until the next show or
/// pull reads again.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dj/dj_api.dart';
import '../../data/dj/dj_models.dart';
import 'auth_provider.dart';
import 'dj_providers.dart';

class SharedMixesNotifier extends AsyncNotifier<List<SharedMixRow>> {
  int _generation = 0;
  int _reads = 0;

  /// Numbers every read as it goes out, the first one included.
  int _readSeq = 0;

  /// Tokens with a Remove out: a read landing meanwhile leaves them out.
  final Set<String> _removing = {};

  /// Each removed token, with the number of the last read that went out
  /// before its Remove finished: such a read may still list it, so it is
  /// left out of that read and every earlier one.
  final Map<String, int> _removedBefore = {};

  @override
  Future<List<SharedMixRow>> build() async {
    ref.watch(authProvider);
    final api = ref.watch(djApiProvider);
    final generation = ++_generation;
    _removing.clear();
    _removedBefore.clear();
    ref.onDispose(() => _generation++);
    final seq = ++_readSeq;
    final rows = await api.listSharedMixes();
    return generation == _generation ? _visible(rows, seq) : rows;
  }

  List<SharedMixRow> _visible(List<SharedMixRow> rows, int seq) => [
    for (final row in rows)
      if (!_removing.contains(row.token) &&
          (_removedBefore[row.token] ?? 0) < seq)
        row,
  ];

  /// Reads the list again. A failure keeps the last list (and says false);
  /// with none yet, the error stands until the next read.
  Future<bool> refresh() async {
    final generation = _generation;
    final read = ++_reads;
    final seq = ++_readSeq;
    final next = await AsyncValue.guard(
      () => ref.read(djApiProvider).listSharedMixes(),
    );
    if (!ref.mounted || generation != _generation || read != _reads) {
      return false;
    }
    if (next.hasError) {
      if (!state.hasValue) state = next;
      return false;
    }
    state = AsyncData(_visible(next.requireValue, seq));
    return true;
  }

  /// Remove (deletes the save, not the share): the row goes at once and
  /// comes back in its place if the server says no. A save already gone
  /// counts as removed. A token not listed (a share its sender stopped,
  /// opened from Mixes before the list caught up) is still deleted.
  Future<bool> remove(String token) async {
    final current = state.value;
    final index = current?.indexWhere((row) => row.token == token) ?? -1;
    final row = index < 0 ? null : current![index];
    final generation = _generation;
    _removing.add(token);
    if (row != null) state = AsyncData([...current!]..removeAt(index));
    var removed = false;
    try {
      await ref.read(djApiProvider).removeSharedMix(token);
      removed = true;
    } on SharedMixGoneException {
      removed = true;
    } catch (_) {
      if (!ref.mounted || generation != _generation || row == null) {
        return false;
      }
      final now = state.value ?? const <SharedMixRow>[];
      if (!now.any((r) => r.token == token)) {
        final at = now.indexWhere((r) => r.savedAt.isBefore(row.savedAt));
        state = AsyncData([...now]..insert(at < 0 ? now.length : at, row));
      }
    } finally {
      if (ref.mounted && generation == _generation) {
        _removing.remove(token);
        if (removed) _removedBefore[token] = _readSeq;
      }
    }
    return removed;
  }
}

final sharedMixesProvider =
    AsyncNotifierProvider<SharedMixesNotifier, List<SharedMixRow>>(
      SharedMixesNotifier.new,
      retry: (_, _) => null,
    );

/// One row of Mixes' Active list: the listener's own mix, or a share they
/// saved.
sealed class MixesEntry {
  const MixesEntry();
}

class OwnMixEntry extends MixesEntry {
  const OwnMixEntry(this.session);
  final DjSession session;
}

class SharedMixEntry extends MixesEntry {
  const SharedMixEntry(this.mix);
  final SharedMixRow mix;
}

/// Own mixes in their list order (newest change first), with each share
/// placed by the time it was saved: before the first own mix changed
/// earlier than that.
List<MixesEntry> mergeMixesEntries(
  List<DjSession> own,
  List<SharedMixRow> shared,
) {
  final shares = [...shared]..sort((a, b) => b.savedAt.compareTo(a.savedAt));
  final entries = <MixesEntry>[];
  var i = 0;
  var j = 0;
  while (i < own.length || j < shares.length) {
    if (j < shares.length &&
        (i >= own.length || shares[j].savedAt.isAfter(own[i].updatedAt))) {
      entries.add(SharedMixEntry(shares[j++]));
    } else {
      entries.add(OwnMixEntry(own[i++]));
    }
  }
  return entries;
}
