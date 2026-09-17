import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/api/api_client.dart';
import 'package:mixtape/data/dj/dj_api.dart';
import 'package:mixtape/data/dj/dj_models.dart';
import 'package:mixtape/data/playlists/playlist_context_models.dart';
import 'package:mixtape/presentation/providers/auth_provider.dart';
import 'package:mixtape/presentation/providers/dj_providers.dart';
import 'package:mixtape/presentation/providers/playlist_context_provider.dart';
import 'playlist_context_provider_test.dart'
    show FakeContextApi, TestAuth, seed;

class FakeDj implements DjApi {
  int sends = 0;
  Future<SessionDetail> Function()? read;
  Future<TurnResult> Function() send = () async => throw ApiException(500, '');
  @override
  Future<SessionDetail> getSession(String id) async => read != null
      ? read!()
      : SessionDetail(
          session: DjSession(
            id: id,
            title: 'Mix',
            status: 'active',
            queueVersion: 1,
            updatedAt: DateTime(2026),
          ),
          messages: [],
          queue: [],
        );
  @override
  Future<TurnResult> sendMessage(String id, String text) {
    sends++;
    return send();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late ProviderContainer container;
  late FakeDj dj;
  late FakeContextApi context;
  final chat = chatProvider('mix');
  final seedProvider = sessionPlaylistContextProvider('mix');
  setUp(() async {
    dj = FakeDj();
    context = FakeContextApi();
    container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(TestAuth.new),
        djApiProvider.overrideWithValue(dj),
        playlistContextApiProvider.overrideWithValue(context),
      ],
    );
    container.listen(chat, (_, _) {});
    container.listen(seedProvider, (_, _) {});
    await container.read(chat.future);
    await Future<void>.delayed(Duration.zero);
  });
  tearDown(() => container.dispose());
  test(
    'seed write blocks sending before any local message is appended',
    () async {
      final pending = Completer<PlaylistSeedState>();
      context.write = () => pending.future;
      final selected = container
          .read(seedProvider.notifier)
          .select(playlistId: 'p');
      await container.read(chat.notifier).send('Change music');
      expect(dj.sends, 0);
      expect(container.read(chat).value!.messages, isEmpty);
      pending.complete(seed(1, id: 'p'));
      await selected;
      await container.read(chat.notifier).send('Now send');
      expect(dj.sends, 1);
    },
  );
  test('send blocks seed change and releases after an error', () async {
    final pending = Completer<TurnResult>();
    dj.send = () => pending.future;
    final sent = container.read(chat.notifier).send('Change music');
    expect(
      await container.read(seedProvider.notifier).select(playlistId: 'p'),
      false,
    );
    expect(context.writes, 0);
    pending.completeError(ApiException(500, ''));
    await sent;
    expect(
      await container.read(seedProvider.notifier).select(playlistId: 'p'),
      true,
    );
  });
  test(
    'old account send cannot append errors to rebuilt chat or keep gate locked',
    () async {
      final pending = Completer<TurnResult>();
      dj.send = () => pending.future;
      final sent = container.read(chat.notifier).send('Old account');
      final auth = container.read(authProvider.notifier) as TestAuth;
      auth.set(AuthStatus.signedOut);
      await container.pump();
      auth.set(AuthStatus.signedIn);
      await container.pump();
      await Future<void>.delayed(Duration.zero);
      pending.completeError(ApiException(500, ''));
      await sent;
      expect(container.read(chat).value!.messages, isEmpty);
      expect(
        await container.read(seedProvider.notifier).select(playlistId: 'new'),
        true,
      );
    },
  );
  test(
    'stale recovery GET cannot replace rebuilt account conversation',
    () async {
      final recovery = Completer<SessionDetail>();
      final started = Completer<void>();
      dj.read = () {
        if (!started.isCompleted) started.complete();
        return recovery.future;
      };
      dj.send = () async =>
          throw DjApiException(kind: 'stale', message: 'Refresh');
      final sent = container.read(chat.notifier).send('Old account');
      await started.future;
      final auth = container.read(authProvider.notifier) as TestAuth;
      auth.set(AuthStatus.signedOut);
      dj.read = null;
      await container.pump();
      auth.set(AuthStatus.signedIn);
      await container.pump();
      await Future<void>.delayed(Duration.zero);
      recovery.complete(
        SessionDetail(
          session: DjSession(
            id: 'mix',
            title: 'Old private mix',
            status: 'active',
            queueVersion: 9,
            updatedAt: DateTime(2026),
          ),
          messages: [],
          queue: [],
        ),
      );
      await sent;
      expect(container.read(chat).value!.session.title, 'Mix');
      expect(container.read(chat).value!.session.queueVersion, 1);
      expect(container.read(chat).value!.messages, isEmpty);
    },
  );
}
