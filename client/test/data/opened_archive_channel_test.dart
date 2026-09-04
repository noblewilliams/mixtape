// The `mixtape/open-archive` side of C5: what the AppDelegate pushes when a
// listener hands us a ZIP from Files or Mail, what it hands over after a
// cold start, and the delete that takes the temp copy away again.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/files/archive_picker.dart';
import 'package:mixtape/data/files/opened_archive_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('mixtape/open-archive');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Future<Object?> push(Object? arguments) async {
    final data = await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall('onOpenedArchive', arguments)),
      null,
    );
    return data == null ? null : const StandardMethodCodec().decodeEnvelope(data);
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  const extended = HandedArchive(
    name: 'my_spotify_data_extended.zip',
    archive: PickedArchive(
      path: '/tmp/opened-archives/b/my_spotify_data_extended.zip',
      name: 'my_spotify_data_extended.zip',
      bytes: 40265318,
    ),
  );

  test('a file opened while someone is listening arrives on the stream, acknowledged', () async {
    final source = MethodChannelOpenedArchiveSource();
    addTearDown(source.dispose);
    final opened = <HandedArchive>[];
    source.opened.listen(opened.add);
    await Future<void>.delayed(Duration.zero);

    final taken = await push({
      'path': '/tmp/opened-archives/abc/my_spotify_data.zip',
      'name': 'my_spotify_data.zip',
      'size': 1300000,
    });
    await Future<void>.delayed(Duration.zero);

    // The `true` is what lets the native side drop its copy of the archive.
    expect(taken, isTrue);
    expect(opened, [
      const HandedArchive(
        name: 'my_spotify_data.zip',
        archive: PickedArchive(
          path: '/tmp/opened-archives/abc/my_spotify_data.zip',
          name: 'my_spotify_data.zip',
          bytes: 1300000,
        ),
      ),
    ]);
  });

  test('a file opened with nobody listening is held for the next takePending', () async {
    final source = MethodChannelOpenedArchiveSource();
    addTearDown(source.dispose);
    var asked = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      asked++;
      return null;
    });

    await push({'path': '/tmp/opened-archives/a/export.zip', 'name': 'export.zip', 'size': 12});

    expect(
      await source.takePending(),
      const HandedArchive(
        name: 'export.zip',
        archive: PickedArchive(
          path: '/tmp/opened-archives/a/export.zip',
          name: 'export.zip',
          bytes: 12,
        ),
      ),
    );
    expect(asked, 0, reason: 'the held archive answers before the channel does');
    // Handed over exactly once.
    expect(await source.takePending(), isNull);
    expect(asked, 1);
  });

  test('a cold start drains the archive the launch buffered, and survives no answer', () async {
    final source = MethodChannelOpenedArchiveSource();
    addTearDown(source.dispose);
    var pending = <String, Object?>{
      'path': '/tmp/opened-archives/b/my_spotify_data_extended.zip',
      'name': 'my_spotify_data_extended.zip',
      'size': 40265318,
    };
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getPendingArchive');
      final answer = pending;
      pending = {};
      return answer.isEmpty ? null : answer;
    });

    expect(await source.takePending(), extended);
    expect(await source.takePending(), isNull);
  });

  test('an archive already pushed is not handed over again by the launch buffer', () async {
    // The cold-start race: the push replays as soon as the handler registers,
    // and the native buffer has not been cleared by the acknowledgement yet,
    // so `getPendingArchive` still answers with the same file. Two real opens
    // of the same file land in different UUID directories, so equality here
    // can never swallow a second open.
    final source = MethodChannelOpenedArchiveSource();
    addTearDown(source.dispose);
    var asked = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      asked++;
      return {
        'path': '/tmp/opened-archives/b/my_spotify_data_extended.zip',
        'name': 'my_spotify_data_extended.zip',
        'size': 40265318,
      };
    });
    final opened = <HandedArchive>[];
    source.opened.listen(opened.add);
    await Future<void>.delayed(Duration.zero);

    await push({
      'path': '/tmp/opened-archives/b/my_spotify_data_extended.zip',
      'name': 'my_spotify_data_extended.zip',
      'size': 40265318,
    });
    await Future<void>.delayed(Duration.zero);

    expect(opened, [extended]);
    expect(await source.takePending(), isNull, reason: 'the stream already delivered it');
    expect(asked, 1);
    // A different open of the same file (its own directory) still lands.
    messenger.setMockMethodCallHandler(channel, (call) async => {
          'path': '/tmp/opened-archives/c/my_spotify_data_extended.zip',
          'name': 'my_spotify_data_extended.zip',
          'size': 40265318,
        });
    expect((await source.takePending())?.archive?.path,
        '/tmp/opened-archives/c/my_spotify_data_extended.zip');
  });

  test('a file the app could not copy arrives as an unreadable hand-over, by name', () async {
    final source = MethodChannelOpenedArchiveSource();
    addTearDown(source.dispose);
    final opened = <HandedArchive>[];
    source.opened.listen(opened.add);
    await Future<void>.delayed(Duration.zero);

    expect(await push({'error': 'unreadable', 'name': 'my_spotify_data.zip'}), isTrue);
    await Future<void>.delayed(Duration.zero);

    expect(opened, [const HandedArchive(name: 'my_spotify_data.zip')]);
    expect(opened.single.unreadable, isTrue);
    expect(opened.single.archive, isNull);
  });

  test('discarding an archive asks the platform to delete its copy', () async {
    final source = MethodChannelOpenedArchiveSource();
    addTearDown(source.dispose);
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return true;
    });

    await source.discard(const PickedArchive(
      path: '/tmp/opened-archives/abc/my_spotify_data.zip',
      name: 'my_spotify_data.zip',
      bytes: 12,
    ));

    expect(calls.single.method, 'deleteOpenedArchive');
    expect(calls.single.arguments, {'path': '/tmp/opened-archives/abc/my_spotify_data.zip'});
  });

  test('a delete the platform refuses is not an error anyone sees', () async {
    final source = MethodChannelOpenedArchiveSource();
    addTearDown(source.dispose);
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => throw PlatformException(code: 'error'),
    );

    await expectLater(
      source.discard(const PickedArchive(path: '/tmp/a.zip', name: 'a.zip', bytes: 1)),
      completes,
    );
  });

  test('a payload without a usable path or name is not an archive', () async {
    final source = MethodChannelOpenedArchiveSource();
    addTearDown(source.dispose);
    final opened = <HandedArchive>[];
    source.opened.listen(opened.add);
    await Future<void>.delayed(Duration.zero);

    expect(await push({'path': '', 'name': 'export.zip', 'size': 1}), isFalse);
    expect(await push({'path': '/tmp/c/export.zip', 'size': 1}), isFalse);
    await Future<void>.delayed(Duration.zero);

    expect(opened, isEmpty);
    // A size the platform could not read still opens the file.
    expect(await push({'path': '/tmp/c/export.zip', 'name': 'export.zip'}), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(opened.single.archive?.bytes, 0);
  });
}
