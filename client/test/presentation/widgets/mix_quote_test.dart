import 'package:flutter_test/flutter_test.dart';
import 'package:mixtape/presentation/widgets/mix_quote.dart';

void main() {
  const terminator = QuotedSong(
    title: 'Terminator',
    artist: 'Asake',
    trackId: 't1',
  );
  const outOfTime = QuotedSong(
    title: 'Out of Time',
    artist: 'The Weeknd',
    trackId: 't2',
  );

  test('a quoted message opens with one line per song', () {
    expect(
      composeQuotedMessage([terminator, outOfTime], '  feels out of place '),
      '> Terminator — Asake\n> Out of Time — The Weeknd\nfeels out of place',
    );
    expect(composeQuotedMessage(const [], ' plain '), 'plain');
  });

  test('a sent message splits back into its quotes and words', () {
    final split = splitQuotedMessage(
      '> Terminator — Asake\n> Out of Time — The Weeknd\nswap these',
    );
    expect(split.quotes.map((q) => q.label), [
      'Terminator · Asake',
      'Out of Time · The Weeknd',
    ]);
    expect(split.text, 'swap these');
  });

  test('a title with a dash keeps it; only the last separator splits', () {
    final quote = QuotedSong.parse('> Wait — For It — Kenny')!;
    expect(quote.title, 'Wait — For It');
    expect(quote.artist, 'Kenny');
  });

  test('a message without leading quotes comes back whole', () {
    const text = 'more like this\n> not a quote';
    final split = splitQuotedMessage(text);
    expect(split.quotes, isEmpty);
    expect(split.text, text);
  });

  group('MixDraft', () {
    test('quotes a song once, unquotes it, and clears with the text', () {
      final draft = MixDraft();
      addTearDown(draft.dispose);
      draft.quote(terminator);
      draft.quote(terminator);
      draft.quote(outOfTime);
      expect(draft.quotes, [terminator, outOfTime]);
      draft.unquote(terminator);
      expect(draft.quotes, [outOfTime]);
      draft.controller.text = 'hello';
      expect(draft.outgoing, '> Out of Time — The Weeknd\nhello');
      draft.clear();
      expect(draft.isEmpty, isTrue);
    });

    test('restore puts a stopped turn back, quotes and all', () {
      final draft = MixDraft();
      addTearDown(draft.dispose);
      draft.restore('> Terminator — Asake\nfeels out of place');
      expect(draft.quotes.single.label, 'Terminator · Asake');
      expect(draft.controller.text, 'feels out of place');
    });

    test('restore leaves a draft the listener has started alone', () {
      final draft = MixDraft();
      addTearDown(draft.dispose);
      draft.controller.text = 'something new';
      draft.restore('> Terminator — Asake\nold');
      expect(draft.quotes, isEmpty);
      expect(draft.controller.text, 'something new');
    });
  });
}
