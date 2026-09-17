import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/playlists/playlist_context_api.dart';
import 'package:mixtape/data/playlists/playlist_context_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/playlist_context_provider.dart';

class TestAuth extends AuthNotifier {
  @override
  AuthStatus build() => AuthStatus.signedIn;
  void set(AuthStatus value) => state = value;
}

PlaylistSeedState seed(int revision, {String? id}) => PlaylistSeedState(
  playlistId: id,
  revision: revision,
  excludeSourceTracks: false,
  status: id == null ? PlaylistSeedStatus.none : PlaylistSeedStatus.ready,
  name: id,
  source: null,
  fingerprint: null,
  updatedAt: null,
  entries: 0,
  resolvedEntries: 0,
  recordings: 0,
  profile: null,
);

class FakeContextApi implements PlaylistContextApi {
  Future<PlaylistSeedState?> Function() read = () async => seed(0);
  Future<PlaylistSeedState> Function() write = () async => seed(1, id: 'p');
  int writes = 0;
  int? sentRevision;
  String? sentId;
  bool? sentExclusion;
  @override
  Future<PlaylistSeedState?> getSessionSeed(String sessionId) => read();
  @override
  Future<PlaylistSeedState> selectSeed(
    String sessionId, {
    required String? playlistId,
    required int expectedRevision,
    bool excludeSourceTracks = false,
  }) {
    writes++;
    sentRevision = expectedRevision;
    sentId = playlistId;
    sentExclusion = excludeSourceTracks;
    return write();
  }

  @override
  Future<void> confirmTaste(String id, {required bool confirmed}) =>
      throw UnimplementedError();
}

void main() {
  late FakeContextApi api;
  late ProviderContainer container;
  final provider = sessionPlaylistContextProvider('mix');
  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await container.pump();
  }

  setUp(() {
    api = FakeContextApi();
    container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(TestAuth.new),
        playlistContextApiProvider.overrideWithValue(api),
      ],
    );
    container.listen(provider, (_, _) {});
  });
  tearDown(() => container.dispose());

  test('unknown legacy state refuses writes', () async {
    api.read = () async => null;
    await container.read(provider.notifier).refresh();
    expect(
      await container.read(provider.notifier).select(playlistId: 'p'),
      false,
    );
    expect(container.read(provider).seed, isNull);
    expect(api.writes, 0);
  });

  test(
    'writes serialize and submit exact identity, revision and exclusion',
    () async {
      await settle();
      final pending = Completer<PlaylistSeedState>();
      api.write = () => pending.future;
      final notifier = container.read(provider.notifier);
      final first = notifier.select(playlistId: 'p', excludeSourceTracks: true);
      expect(container.read(provider).writing, true);
      expect(await notifier.select(playlistId: 'other'), false);
      expect(api.writes, 1);
      expect(api.sentRevision, 0);
      expect(api.sentId, 'p');
      expect(api.sentExclusion, true);
      pending.complete(seed(1, id: 'p'));
      expect(await first, true);
      expect(container.read(provider).seed!.revision, 1);
    },
  );

  test('conflict rereads canonical state without repeating mutation', () async {
    await settle();
    api.write = () async => throw PlaylistContextException(409, '', 'stale');
    api.read = () async => seed(7, id: 'other');
    expect(
      await container.read(provider.notifier).select(playlistId: 'p'),
      false,
    );
    expect(container.read(provider).seed!.playlistId, 'other');
    expect(container.read(provider).error, isA<PlaylistContextException>());
    expect(api.writes, 1);
  });

  test(
    'uncertain write plus failed recovery clears revision and blocks another write',
    () async {
      await settle();
      api.write = () async => throw NetworkException('lost response');
      api.read = () async => throw NetworkException('offline');
      final notifier = container.read(provider.notifier);
      expect(await notifier.select(playlistId: 'p'), false);
      expect(container.read(provider).seed, isNull);
      expect(container.read(provider).writing, false);
      expect(await notifier.select(playlistId: 'other'), false);
      expect(api.writes, 1);
    },
  );

  test(
    'expired authentication clears revision without a recovery request',
    () async {
      await settle();
      var reads = 0;
      api.read = () async {
        reads++;
        throw NetworkException('offline');
      };
      api.write = () async => throw PlaylistContextException(401, '', null);
      final notifier = container.read(provider.notifier);
      expect(await notifier.select(playlistId: 'p'), false);
      final value = container.read(provider);
      expect(value.seed, isNull);
      expect(
        value.error,
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401),
      );
      expect(reads, 0);
      expect(await notifier.select(playlistId: 'p'), false);
      expect(api.writes, 1);
    },
  );

  test('disposed pending read cannot publish late state', () async {
    await settle();
    final pending = Completer<PlaylistSeedState?>();
    api.read = () => pending.future;
    final result = container.read(provider.notifier).refresh();
    container.invalidate(provider);
    api.read = () async => seed(12, id: 'replacement');
    await settle();
    pending.complete(seed(3, id: 'disposed'));
    expect(await result, false);
    expect(container.read(provider).seed!.playlistId, 'replacement');
  });

  test('latest refresh wins over delayed older load', () async {
    final first = Completer<PlaylistSeedState?>();
    api.read = () => first.future;
    final older = container.read(provider.notifier).refresh();
    api.read = () async => seed(9, id: 'latest');
    expect(await container.read(provider.notifier).refresh(), true);
    first.complete(seed(1, id: 'old'));
    expect(await older, false);
    await settle();
    expect(container.read(provider).seed!.revision, 9);
  });

  test(
    'auth transition invalidates pending write even after signed-in rebuild',
    () async {
      await settle();
      final pending = Completer<PlaylistSeedState>();
      api.write = () => pending.future;
      final oldNotifier = container.read(provider.notifier);
      final result = oldNotifier.select(playlistId: 'old');
      final auth = container.read(authProvider.notifier) as TestAuth;
      auth.set(AuthStatus.signedOut);
      await settle();
      expect(container.read(provider).seed, isNull);
      api.read = () async => seed(10, id: 'new-account');
      auth.set(AuthStatus.signedIn);
      await settle();
      pending.complete(seed(2, id: 'old'));
      expect(await result, false);
      expect(container.read(provider).seed!.playlistId, 'new-account');
    },
  );
  test(
    'session reads adopt seed only before a newer selection or read',
    () async {
      await settle();
      final notifier = container.read(provider.notifier);
      final oldRead = notifier.readToken;
      expect(await notifier.select(playlistId: 'p'), true);
      expect(notifier.adoptCanonical(seed(0), oldRead), false);
      final currentRead = notifier.readToken;
      expect(
        notifier.adoptCanonical(seed(2, id: 'canonical'), currentRead),
        true,
      );
      expect(container.read(provider).seed!.playlistId, 'canonical');
      expect(notifier.adoptCanonical(null, notifier.readToken), false);
      expect(notifier.adoptCanonical(seed(1), notifier.readToken), false);
      expect(container.read(provider).seed!.revision, 2);
    },
  );
}
