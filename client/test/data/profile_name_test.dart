import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/data/auth/profile_name.dart';

TextEditingValue _at(String text, [int? caret]) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: caret ?? text.length),
);

void main() {
  group('normalizeProfileName (mirrors server/src/auth/profile-name.ts)', () {
    test('trims and collapses whitespace runs', () {
      expect(normalizeProfileName('  Ada    Okafor  '), 'Ada Okafor');
      expect(normalizeProfileName('   '), '');
      expect(normalizeProfileName(''), '');
    });

    test('whitespace controls become spaces, other controls drop', () {
      expect(normalizeProfileName('Ada\nLovelace'), 'Ada Lovelace');
      expect(normalizeProfileName('Ada\u000b\u000c\u0085Okafor'), 'Ada Okafor');
      expect(normalizeProfileName('A\u0000d\u0007a'), 'Ada');
    });

    test('format characters drop except ZWJ and ZWNJ', () {
      expect(normalizeProfileName('A\u200bd\u202ea\ufeff'), 'Ada');
      const family = '\u{1F468}\u200d\u{1F469}\u200d\u{1F467}';
      expect(normalizeProfileName(family), family);
      expect(normalizeProfileName('می\u200cخواهم'), 'می\u200cخواهم');
    });

    test('lone surrogates drop', () {
      expect(normalizeProfileName('Ada\ud800'), 'Ada');
    });

    test('caps at 40 code points in whole characters', () {
      expect(normalizeProfileName('a' * 45), 'a' * 40);
      // 39 letters then a flag (two code points): the flag would make 41.
      expect(normalizeProfileName('${'a' * 39}\u{1F1F3}\u{1F1EC}'), 'a' * 39);
      expect(nameLength('${'a' * 38}\u{1F1F3}\u{1F1EC}'), 40);
      expect(
        normalizeProfileName('${'a' * 38}\u{1F1F3}\u{1F1EC}'),
        '${'a' * 38}\u{1F1F3}\u{1F1EC}',
      );
    });

    test('trims again when the cap lands on a space', () {
      expect(normalizeProfileName('${'a' * 39} bcd'), 'a' * 39);
    });
  });

  group('applyNameEdit', () {
    test('typing within room is untouched', () {
      final edit = applyNameEdit(_at('Ad'), _at('Ada'));
      expect(edit.value.text, 'Ada');
      expect(edit.cut, isFalse);
    });

    test('typing at 40 is refused and the caret stays', () {
      final full = 'a' * 40;
      final edit = applyNameEdit(
        _at(full, 20),
        _at('${'a' * 20}b${'a' * 20}', 21),
      );
      expect(edit.value.text, full);
      expect(edit.value.selection.end, 20);
      expect(edit.cut, isTrue);
    });

    test('a longer paste is cut to fit, keeping the text after it', () {
      final edit = applyNameEdit(
        _at('Ada  Okafor', 4),
        _at('Ada ${'x' * 40} Okafor', 44),
      );
      expect(nameLength(edit.value.text), 40);
      expect(edit.value.text, 'Ada ${'x' * 29} Okafor');
      expect(edit.value.selection.end, 33);
      expect(edit.cut, isTrue);
    });

    test('a pasted line break becomes a space; controls drop', () {
      final edit = applyNameEdit(_at(''), _at('Ada\nOk\u0000afor'));
      expect(edit.value.text, 'Ada Okafor');
      expect(edit.cut, isFalse);
    });

    test('deleting is always allowed', () {
      final edit = applyNameEdit(_at('a' * 40), _at('a' * 39));
      expect(edit.value.text, 'a' * 39);
      expect(edit.cut, isFalse);
    });
  });

  group('ProfileNameFormatter', () {
    test('composing input passes through until it is committed', () {
      final cuts = <bool>[];
      final formatter = ProfileNameFormatter(onCut: cuts.add);
      final base = 'a' * 39;
      // Composing (marked text) is not treated as committed: no cap yet.
      final composing = TextEditingValue(
        text: '$baseにほん',
        selection: const TextSelection.collapsed(offset: 42),
        composing: const TextRange(start: 39, end: 42),
      );
      expect(formatter.formatEditUpdate(_at(base), composing), composing);
      expect(cuts, isEmpty);
      // Committed: capped against the last committed text.
      final committed = formatter.formatEditUpdate(composing, _at('$base日本'));
      expect(committed.text, '$base日');
      expect(cuts, [true]);
    });

    test('reports no cut for an ordinary edit', () {
      final cuts = <bool>[];
      final formatter = ProfileNameFormatter(onCut: cuts.add);
      expect(formatter.formatEditUpdate(_at('A'), _at('Ad')).text, 'Ad');
      expect(cuts, [false]);
    });
  });
}
