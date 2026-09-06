import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/playlists/playlist_edit_api.dart';
import 'package:mixtape/data/playlists/playlist_edit_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/playlist_providers.dart';

class TestAuthNotifier extends AuthNotifier {
  @override
  AuthStatus build() => AuthStatus.signedIn;
}

class FakePlaylistEditApi implements PlaylistEditApi {
  PlaylistEditView? Function(String playlistId)? onCreateOrResume;
  Future<PlaylistEditThread> Function(String draftId)? onGetThread;
  Future<PlaylistEditTurnResult> Function(
    String draftId,
    String content,
    int version,
  )?
  onSendMessage;
  final sentVersions = <int>[];

  @override
  Duration get timeout => const Duration(seconds: 120);

  @override
  Future<PlaylistEditView> createOrResume(String playlistId) async {
    final result = onCreateOrResume?.call(playlistId);
    if (result == null) throw UnimplementedError();
    return result;
  }

  @override
  Future<PlaylistEditThread> getThread(String draftId) {
    final call = onGetThread;
    if (call == null) throw UnimplementedError();
    return call(draftId);
  }

  @override
  Future<PlaylistEditTurnResult> sendMessage(
    String draftId,
    String content,
    int expectedVersion,
  ) {
    sentVersions.add(expectedVersion);
    final call = onSendMessage;
    if (call == null) throw UnimplementedError();
    return call(draftId, content, expectedVersion);
  }

  @override
  Future<PlaylistApplyPlan> prepareApply(
    String draftId, {
    required int expectedVersion,
    required String currentSourceFingerprint,
  }) => throw UnimplementedError();

  @override
  Future<PlaylistApplyConfirmation> confirmApply(
    String draftId, {
    required String operationId,
    required int expectedVersion,
    required String applePlaylistLibraryId,
    required String resultingFingerprint,
  }) => throw UnimplementedError();

  @override
  void close() {}
}

Map<String, dynamic> _viewJson(int version) => {
  'draft': {
    'id': '00000000-0000-4000-8000-000000000010',
    'sourcePlaylistId': '00000000-0000-4000-8000-000000000001',
    'sourceProviderLibraryId': 'p.source',
    'status': 'active',
    'version': version,
    'baseSourceFingerprint':
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    'baseName': 'Night Bus Notes',
    'sourceType': 'apple',
    'createdAt': '2026-09-05T10:00:00.000Z',
    'updatedAt': '2026-09-05T11:00:00.000Z',
  },
  'entries': [],
  'diff': {'added': [], 'removed': [], 'moved': [], 'replaced': []},
  'review': {'added': [], 'removed': [], 'moved': [], 'replaced': []},
  'capability': {
    'possibleModes': ['revised_copy'],
    'sourceWillRemainUntouched': true,
    'applyAvailable': false,
  },
};

PlaylistEditMessage _message(
  String id,
  String role,
  String content, {
  int? version,
}) => PlaylistEditMessage(
  id: id,
  role: role,
  content: content,
  seq: int.tryParse(id) ?? 0,
  draftVersion: version,
  createdAt: DateTime(2026, 9, 5),
);

PlaylistEditThread _thread(
  int version, {
  List<PlaylistEditMessage> messages = const [],
}) {
  final view = PlaylistEditView.fromJson(_viewJson(version));
  return PlaylistEditThread(
    draft: view.draft,
    entries: view.entries,
    diff: view.diff,
    review: view.review,
    capability: view.capability,
    messages: messages,
  );
}

ProviderContainer _container(FakePlaylistEditApi api) {
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith(TestAuthNotifier.new),
      playlistEditApiProvider.overrideWithValue(api),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test(
    'a turn posts the canonical version and adopts the returned draft',
    () async {
      final api = FakePlaylistEditApi();
      api.onGetThread = (_) async => _thread(1);
      api.onSendMessage = (_, __, ___) async => PlaylistEditTurnResult(
        djMessage: _message('2', 'dj', 'I placed two songs.', version: 2),
        draft: PlaylistEditView.fromJson(_viewJson(2)),
      );
      final container = _container(api);
      final provider = playlistEditThreadProvider(
        '00000000-0000-4000-8000-000000000010',
      );
      final sub = container.listen(provider, (_, __) {});
      addTearDown(sub.close);
      await container.read(provider.future);

      await container.read(provider.notifier).send('add a couple');

      final state = container.read(provider).requireValue;
      expect(api.sentVersions, [1]);
      expect(state.view.draft.version, 2);
      expect(state.messages.map((m) => [m.message.role, m.message.content]), [
        ['user', 'add a couple'],
        ['dj', 'I placed two songs.'],
      ]);
      expect(state.sending, isFalse);
    },
  );

  test(
    'a conflict replaces local state with the canonical draft and explains refresh',
    () async {
      final api = FakePlaylistEditApi();
      var reads = 0;
      api.onGetThread = (_) async {
        reads += 1;
        return reads == 1
            ? _thread(2, messages: [_message('1', 'dj', 'Before conflict')])
            : _thread(3, messages: [_message('2', 'dj', 'Canonical')]);
      };
      api.onSendMessage = (_, __, ___) async => throw PlaylistEditApiException(
        kind: 'conflict',
        message:
            'This playlist draft changed somewhere else. Refresh it and try again.',
        draft: PlaylistEditView.fromJson(_viewJson(3)),
      );
      final container = _container(api);
      final provider = playlistEditThreadProvider(
        '00000000-0000-4000-8000-000000000010',
      );
      final sub = container.listen(provider, (_, __) {});
      addTearDown(sub.close);
      await container.read(provider.future);

      await container.read(provider.notifier).send('move it');

      final state = container.read(provider).requireValue;
      expect(reads, 2);
      expect(state.view.draft.version, 3);
      expect(state.messages.map((m) => m.message.content), ['Canonical']);
      expect(
        state.transientError,
        'This playlist draft changed somewhere else. Refresh it and try again.',
      );
      expect(state.sending, isFalse);
    },
  );

  test('double send is fenced while the first DJ turn is in flight', () async {
    final completer = Completer<PlaylistEditTurnResult>();
    final api = FakePlaylistEditApi();
    api.onGetThread = (_) async => _thread(0);
    api.onSendMessage = (_, __, ___) => completer.future;
    final container = _container(api);
    final provider = playlistEditThreadProvider(
      '00000000-0000-4000-8000-000000000010',
    );
    final sub = container.listen(provider, (_, __) {});
    addTearDown(sub.close);
    await container.read(provider.future);

    final first = container.read(provider.notifier).send('first');
    final second = container.read(provider.notifier).send('second');
    await second;
    expect(api.sentVersions, [0]);

    completer.complete(
      PlaylistEditTurnResult(
        djMessage: _message('2', 'dj', 'Done', version: 0),
        draft: PlaylistEditView.fromJson(_viewJson(0)),
      ),
    );
    await first;
    expect(container.read(provider).requireValue.sending, isFalse);
  });

  test('a failed turn keeps the exact request available for retry', () async {
    final api = FakePlaylistEditApi();
    api.onGetThread = (_) async => _thread(0);
    api.onSendMessage = (_, __, ___) async =>
        throw NetworkException(StateError('offline'));
    final container = _container(api);
    final provider = playlistEditThreadProvider(
      '00000000-0000-4000-8000-000000000010',
    );
    final sub = container.listen(provider, (_, __) {});
    addTearDown(sub.close);
    await container.read(provider.future);

    await container.read(provider.notifier).send('move the closer later');

    final error = container.read(provider).requireValue.messages.last;
    expect(error.isError, isTrue);
    expect(error.retryContent, 'move the closer later');
  });
}
