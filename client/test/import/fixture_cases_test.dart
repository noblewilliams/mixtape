import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/import/snapshot.dart';
import 'package:mixtape/import/spotify_parser.dart' hide baseName;
import 'package:mixtape/import/zip_reader.dart';

import 'fixtures.dart';

void main() {
  for (final caseDir in fixtureCases()) {
    final caseName = baseName(caseDir.path);
    final definition = caseDefinition(caseDir);
    final options = (definition['options'] as List).cast<Map<String, dynamic>>();

    for (final option in options) {
      final optionName = option['name'] as String;
      final parseOptions = ParseOptions(
        timeZone: option['timeZone'] as String,
        includePrivateSessions: option['includePrivateSessions'] as bool,
      );

      test('$caseName/$optionName matches expected.$optionName.json', () async {
        final expected = expectedFor(caseName, optionName);
        final expectedText =
            File('${caseDir.path}/expected.$optionName.json').readAsStringSync();
        final archive = ZipExportArchive.open(File('${caseDir.path}/archive.zip'));
        try {
          final inventory = await inspectExport(archive);
          expect(inventory.toCanonicalJson(), expected['inventory']);

          if (expected.containsKey('error')) {
            final error = expected['error'] as Map<String, dynamic>;
            expect(error['code'], 'unreadable');
            await expectLater(
              parseExport(archive, parseOptions),
              throwsA(
                isA<UnreadableExportException>()
                    .having((e) => e.file, 'file', error['file'])
                    .having(
                      (e) => e.inventory.toCanonicalJson(),
                      'inventory',
                      expected['inventory'],
                    ),
              ),
            );
            expect(inventory.unreadableFile, error['file']);
            return;
          }

          final parsed = await parseExport(archive, parseOptions);
          expect(parsed.inventory.toCanonicalJson(), expected['inventory']);
          expect(parsed.snapshot.toCanonicalJson(), expected['snapshot']);
          expect(inventory.unreadableFile, isNull);

          // Byte-identical with the committed document, not only deep-equal.
          final document = canonicalJsonString({
            'inventory': parsed.inventory.toCanonicalJson(),
            'snapshot': parsed.snapshot.toCanonicalJson(),
          });
          expect(document, expectedText);
        } finally {
          await archive.close();
        }
      });
    }
  }

  test('the suite covers every case directory', () {
    final names = fixtureCases().map((dir) => baseName(dir.path)).toList();
    expect(names, hasLength(15));
    expect(names, contains('extended-timezone'));
    expect(names, contains('account-pii-present'));
  });
}
