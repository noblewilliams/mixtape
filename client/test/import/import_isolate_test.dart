import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/import/import_isolate.dart';
import 'package:mixtape/import/spotify_parser.dart';

import 'fixtures.dart';

void main() {
  test('parses a fixture in a worker isolate with progress across the boundary', () async {
    final expected = expectedFor('extended-timezone', 'st-johns');
    final events = <ParseStage>[];
    final parsed = await parseExportInIsolate(
      fixtureArchive('extended-timezone').path,
      ParseOptions(
        timeZone: 'America/St_Johns',
        onProgress: (stage, file, completed, total) => events.add(stage),
      ),
    );
    expect(parsed.inventory.toCanonicalJson(), expected['inventory']);
    expect(parsed.snapshot.toCanonicalJson(), expected['snapshot']);
    expect(events, contains(ParseStage.inspecting));
    expect(events, contains(ParseStage.parsing));
  });

  test('an unreadable archive surfaces as UnreadableExportException with its file', () async {
    await expectLater(
      parseExportInIsolate(
        fixtureArchive('extended-malformed').path,
        const ParseOptions(timeZone: 'Africa/Lagos'),
      ),
      throwsA(
        isA<UnreadableExportException>()
            .having((e) => e.file, 'file', 'Streaming_History_Audio_2025-2026_1.json')
            .having((e) => e.inventory.read.last.rows, 'rows', isNull),
      ),
    );
  });

  test('a file that is not a ZIP surfaces as unreadable with no file', () async {
    final notZip = '${fixtureArchive('extended-basic').parent.path}/expected.default.json';
    await expectLater(
      parseExportInIsolate(notZip, const ParseOptions(timeZone: 'Africa/Lagos')),
      throwsA(isA<UnreadableExportException>().having((e) => e.file, 'file', isNull)),
    );
  });

  test('cancelling the token stops the worker with ImportCancelled', () async {
    final token = CancelToken();
    await expectLater(
      parseExportInIsolate(
        fixtureArchive('extended-basic').path,
        ParseOptions(
          timeZone: 'Africa/Lagos',
          cancelToken: token,
          onProgress: (stage, file, completed, total) => token.cancel(),
        ),
      ),
      throwsA(isA<ImportCancelled>()),
    );
  });
}
