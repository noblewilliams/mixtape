// The listener's Listen later shelf (album picks spec 2026-10-20 → Listen
// later). User-scoped: it watches authProvider in build(), so every auth
// transition resets it, and it is empty without a network call for anyone
// album picks are not offered to.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dj/dj_models.dart';
import 'auth_provider.dart';
import 'capabilities_provider.dart';
import 'dj_providers.dart';

/// The server's order: unlistened newest-saved first, then listened
/// newest-listened first.
List<ListenLaterEntry> sortListenLater(Iterable<ListenLaterEntry> entries) {
  final unlistened = entries.where((e) => !e.listened).toList()
    ..sort((a, b) => b.savedAt.compareTo(a.savedAt));
  final listened = entries.where((e) => e.listened).toList()
    ..sort((a, b) => b.listenedAt!.compareTo(a.listenedAt!));
  return [...unlistened, ...listened];
}

class ListenLaterNotifier extends AsyncNotifier<List<ListenLaterEntry>> {
  int _generation = 0;
  int _read = 0;

  /// One write per album at a time, so an Undo can't race its own removal.
  final _writes = <String>{};

  @override
  Future<List<ListenLaterEntry>> build() async {
    final status = ref.watch(authProvider);
    final anonymous = ref.watch(isAnonymousProvider);
    final enabled = ref.watch(albumPicksEnabledProvider);
    final api = ref.watch(djApiProvider);
    final generation = ++_generation;
    _writes.clear();
    ref.onDispose(() => _generation++);
    if (status != AuthStatus.session || anonymous || !enabled) return const [];
    final read = ++_read;
    final entries = await api.listListenLater();
    if (generation != _generation) return entries;
    // A later read, removal or note superseded this one: keep what it left
    // rather than resurrecting rows it already took out.
    if (read != _read && state.value != null) return state.requireValue;
    return sortListenLater(entries);
  }

  bool _current(int generation) => ref.mounted && generation == _generation;

  bool get _offered =>
      ref.read(authProvider) == AuthStatus.session &&
      !ref.read(isAnonymousProvider) &&
      ref.read(albumPicksEnabledProvider);

  /// Keeps the last usable shelf on a failed read; with none, the error.
  Future<bool> refresh() async {
    if (!ref.mounted || !_offered) return false;
    final generation = _generation;
    final read = ++_read;
    try {
      final entries = await ref.read(djApiProvider).listListenLater();
      if (!_current(generation) || read != _read) return false;
      state = AsyncData(sortListenLater(entries));
      return true;
    } catch (error, stack) {
      if (!_current(generation) || read != _read) return false;
      if (state.value == null) state = AsyncError(error, stack);
      return false;
    }
  }

  /// Optimistic: the row leaves at once and comes back if the server says
  /// no. Returns whether the removal landed.
  Future<bool> remove(String albumId) async {
    final current = state.value;
    if (!ref.mounted || current == null || !_writes.add(albumId)) return false;
    final removed = current.where((e) => e.id == albumId).firstOrNull;
    if (removed == null) {
      _writes.remove(albumId);
      return false;
    }
    final generation = _generation;
    ++_read; // A read started before this removal must not bring it back.
    state = AsyncData([
      for (final e in current)
        if (e.id != albumId) e,
    ]);
    try {
      await ref.read(djApiProvider).unsaveForLater(albumId);
      return _current(generation);
    } catch (_) {
      if (_current(generation)) {
        final now = state.value ?? const <ListenLaterEntry>[];
        if (!now.any((e) => e.id == albumId)) {
          state = AsyncData(sortListenLater([...now, removed]));
        }
      }
      return false;
    } finally {
      if (_current(generation)) _writes.remove(albumId);
    }
  }

  /// Undo for [remove]: re-saves with no session (the server keeps the
  /// row's own source), then reads the canonical shelf.
  Future<bool> restore(String albumId) async {
    if (!ref.mounted || !_writes.add(albumId)) return false;
    final generation = _generation;
    try {
      final entry = await ref.read(djApiProvider).saveForLater(albumId);
      if (!_current(generation)) return false;
      noteSaved(entry);
      _writes.remove(albumId);
      await refresh();
      return _current(generation);
    } catch (_) {
      return false;
    } finally {
      if (_current(generation)) _writes.remove(albumId);
    }
  }

  /// Adopts the server's entry (it keeps the first listened date) and moves
  /// it under the listened rows.
  Future<bool> markListened(String albumId) async {
    if (!ref.mounted || !_writes.add(albumId)) return false;
    final generation = _generation;
    try {
      final entry = await ref.read(djApiProvider).markListened(albumId);
      if (!_current(generation)) return false;
      _put(entry);
      return true;
    } catch (_) {
      return false;
    } finally {
      if (_current(generation)) _writes.remove(albumId);
    }
  }

  /// The chat saved an album: keep the shelf in step without a refetch.
  void noteSaved(ListenLaterEntry entry) {
    if (!ref.mounted || state.value == null) return;
    ++_read;
    _put(entry);
  }

  /// The chat unsaved an album.
  void noteUnsaved(String albumId) {
    final current = state.value;
    if (!ref.mounted || current == null) return;
    ++_read;
    state = AsyncData([
      for (final e in current)
        if (e.id != albumId) e,
    ]);
  }

  void _put(ListenLaterEntry entry) {
    final current = state.value ?? const <ListenLaterEntry>[];
    state = AsyncData(
      sortListenLater([
        for (final e in current)
          if (e.id != entry.id) e,
        entry,
      ]),
    );
  }
}

final listenLaterProvider =
    AsyncNotifierProvider<ListenLaterNotifier, List<ListenLaterEntry>>(
      ListenLaterNotifier.new,
    );
