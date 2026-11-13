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

  /// Tokens with a Remove out: a read landing meanwhile leaves them out.
  final Set<String> _removing = {};

  @override
  Future<List<SharedMixRow>> build() async {
    ref.watch(authProvider);
    final api = ref.watch(djApiProvider);
    final generation = ++_generation;
    _removing.clear();
    ref.onDispose(() => _generation++);
    final rows = await api.listSharedMixes();
    return generation == _generation ? _visible(rows) : rows;
  }

  List<SharedMixRow> _visible(List<SharedMixRow> rows) => [
    for (final row in rows)
      if (!_removing.contains(row.token)) row,
  ];

  /// Reads the list again. A failure keeps the last list (and says false);
  /// with none yet, the error stands until the next read.
  Future<bool> refresh() async {
    final generation = _generation;
    final read = ++_reads;
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
    state = AsyncData(_visible(next.requireValue));
    return true;
  }

  /// Remove (deletes the save, not the share): the row goes at once and
  /// comes back in its place if the server says no. A save already gone
  /// counts as removed.
  Future<bool> remove(String token) async {
    final current = state.value;
    if (current == null) return false;
    final index = current.indexWhere((row) => row.token == token);
    if (index < 0) return false;
    final row = current[index];
    final generation = _generation;
    _removing.add(token);
    state = AsyncData([...current]..removeAt(index));
    try {
      await ref.read(djApiProvider).removeSharedMix(token);
      return true;
    } on SharedMixGoneException {
      return true;
    } catch (_) {
      if (!ref.mounted || generation != _generation) return false;
      final now = state.value ?? const <SharedMixRow>[];
      if (!now.any((r) => r.token == token)) {
        final at = now.indexWhere((r) => r.savedAt.isBefore(row.savedAt));
        state = AsyncData([...now]..insert(at < 0 ? now.length : at, row));
      }
      return false;
    } finally {
      if (ref.mounted && generation == _generation) _removing.remove(token);
    }
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
