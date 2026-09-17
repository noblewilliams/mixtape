import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/playlists/playlist_api.dart';
import 'package:mixtape/data/playlists/playlist_context_api.dart';
import 'package:mixtape/data/playlists/playlist_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/playlist_context_provider.dart';
import 'package:mixtape/presentation/providers/playlist_providers.dart';
import 'package:mixtape/presentation/providers/playlist_taste_provider.dart';

class TestAuth extends AuthNotifier {
  @override
  AuthStatus build() => AuthStatus.signedIn;
  void signOutForTest() => state = AuthStatus.signedOut;
}

PlaylistSummary summary({
  String origin = 'unknown',
  bool inLibrary = true,
  String kind = 'user',
}) => PlaylistSummary(
  id: 'p',
  name: 'Night',
  kind: kind,
  entryCount: 2,
  inLibrary: inLibrary,
  capability: 'copy_only',
  origin: origin,
);
PlaylistDetail detail(PlaylistSummary summary) =>
    PlaylistDetail(playlist: summary, entries: const [], nextEntryCursor: null);

class ReadApi implements PlaylistApi {
  Future<PlaylistDetail> Function() read = () async => detail(summary());
  @override
  Future<PlaylistDetail> get(
    String id, {
    int entryLimit = 200,
    String? entryCursor,
  }) => read();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class WriteApi implements PlaylistContextApi {
  int writes = 0;
  Future<void> Function(bool) write = (_) async {};
  @override
  Future<void> confirmTaste(String id, {required bool confirmed}) {
    writes++;
    return write(confirmed);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late ProviderContainer container;
  late ReadApi reads;
  late WriteApi writes;
  final provider = playlistTasteProvider('p');
  Future<void> settle() async {
    await Future<void>.delayed(Duration.zero);
    await container.pump();
  }

  setUp(() {
    reads = ReadApi();
    writes = WriteApi();
    container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(TestAuth.new),
        playlistApiProvider.overrideWithValue(reads),
        playlistContextApiProvider.overrideWithValue(writes),
      ],
    );
    container.listen(provider, (_, _) {});
  });
  tearDown(() => container.dispose());
  test(
    'lost mutation response uses canonical summary without changing detail entries or cursor',
    () async {
      await settle();
      final entries = [
        const PlaylistEntry(
          id: 'entry',
          position: 5,
          title: 'Song',
          artist: 'Artist',
          resolved: false,
        ),
      ];
      final loaded = PlaylistDetail(
        playlist: summary(),
        entries: entries,
        nextEntryCursor: 'page2',
      );
      writes.write = (_) async {
        reads.read = () async => detail(summary(origin: 'user_confirmed'));
        throw ApiException(503, '');
      };
      expect(await container.read(provider.notifier).setConfirmed(true), true);
      final merged = container.read(provider).applyTo(loaded);
      expect(merged.playlist.origin, 'user_confirmed');
      expect(identical(merged.entries, entries), true);
      expect(merged.nextEntryCursor, 'page2');
      expect(writes.writes, 1);
    },
  );
  test('failed canonical read locks further writes until refresh', () async {
    await settle();
    writes.write = (_) async {
      reads.read = () async => throw ApiException(503, '');
    };
    expect(await container.read(provider.notifier).setConfirmed(true), false);
    expect(container.read(provider).unknown, true);
    expect(await container.read(provider.notifier).setConfirmed(true), false);
    expect(writes.writes, 1);
    reads.read = () async => detail(summary());
    expect(await container.read(provider.notifier).refresh(), true);
    expect(container.read(provider).canConfirm, true);
  });
  test(
    'automatic playlists cannot confirm but confirmed unavailable playlists can remove',
    () async {
      reads.read = () async => detail(summary(kind: 'editorial'));
      await container.read(provider.notifier).refresh();
      expect(await container.read(provider.notifier).setConfirmed(true), false);
      expect(writes.writes, 0);
      reads.read = () async => detail(
        summary(origin: 'user_confirmed', inLibrary: false, kind: 'editorial'),
      );
      await container.read(provider.notifier).refresh();
      writes.write = (confirmed) async {
        expect(confirmed, false);
        reads.read = () async =>
            detail(summary(inLibrary: false, kind: 'editorial'));
      };
      expect(await container.read(provider.notifier).setConfirmed(false), true);
    },
  );
  test(
    'sign out discards pending mutation and does not issue canonical read',
    () async {
      await settle();
      final pending = Completer<void>();
      writes.write = (_) => pending.future;
      final operation = container.read(provider.notifier).setConfirmed(true);
      (container.read(authProvider.notifier) as TestAuth).signOutForTest();
      await container.pump();
      reads.read = () async => throw StateError('must not read');
      pending.complete();
      expect(await operation, false);
      expect(container.read(provider).summary, isNull);
    },
  );
  test(
    'legacy missing origin cannot confirm and 409 adopts canonical rejection',
    () async {
      await settle();
      final legacy = PlaylistSummary.fromJson({
        'id': 'p',
        'name': 'Night',
        'kind': 'user',
        'entryCount': 2,
        'inLibrary': true,
        'capability': 'copy_only',
      });
      reads.read = () async => detail(legacy);
      await container.read(provider.notifier).refresh();
      expect(container.read(provider).canConfirm, false);
      reads.read = () async => detail(summary());
      await container.read(provider.notifier).refresh();
      writes.write = (_) async {
        reads.read = () async => detail(summary(origin: 'mixtape'));
        throw ApiException(409, '');
      };
      expect(await container.read(provider.notifier).setConfirmed(true), false);
      expect(container.read(provider).summary!.origin, 'mixtape');
      expect(container.read(provider).canConfirm, false);
    },
  );
  test(
    'removal with missing canonical origin stays unknown and locked',
    () async {
      reads.read = () async => detail(summary(origin: 'user_confirmed'));
      await container.read(provider.notifier).refresh();
      writes.write = (_) async {
        reads.read = () async => detail(
          PlaylistSummary.fromJson({
            'id': 'p',
            'name': 'Night',
            'kind': 'user',
            'entryCount': 2,
            'inLibrary': true,
            'capability': 'copy_only',
          }),
        );
        throw ApiException(503, '');
      };
      expect(
        await container.read(provider.notifier).setConfirmed(false),
        false,
      );
      expect(container.read(provider).unknown, true);
      expect(container.read(provider).canRemove, false);
      expect(container.read(provider).canConfirm, false);
    },
  );
}
