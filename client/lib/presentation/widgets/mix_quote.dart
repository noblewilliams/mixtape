/// Quoting songs back to the DJ, and the one draft a mix's composers share.
///
/// A quote is a song from the tape pinned above the composer ("Terminator ·
/// Asake"), so "this feels out of place" says which song without typing its
/// name. It travels inside the message text as a leading `> Title — Artist`
/// line: the DJ reads it as a quote with no server change, the transcript
/// stores it like any other turn, and [LyricTurn] draws it back as a quote
/// rather than as markup.
///
/// A mix has one draft ([mixDraftProvider]): the conversation's composer and
/// the tape's bind to the same text and quotes, so a quote picked on the tape
/// is still there back in the conversation, and nothing typed on one screen
/// is lost by moving to the other.
library;

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/dj/dj_models.dart';
import '../theme/mixtape_theme.dart';

/// One quoted song.
@immutable
class QuotedSong {
  const QuotedSong({required this.title, required this.artist, this.trackId});

  QuotedSong.fromTrack(QueueTrack track)
    : this(title: track.title, artist: track.artist, trackId: track.trackId);

  final String title;
  final String artist;

  /// The tape row it came from, when it came from one: quoting the same row
  /// twice is a no-op. A quote read back out of a sent message has none.
  final String? trackId;

  static const String linePrefix = '> ';
  static const String separator = ' — ';

  /// `> Terminator — Asake`.
  String get line => '$linePrefix$title$separator$artist';

  /// "Terminator · Asake": what the chip and the transcript show.
  String get label => artist.isEmpty ? title : '$title · $artist';

  /// The song a `> Title — Artist` line quotes, or null for any other line.
  static QuotedSong? parse(String line) {
    if (!line.startsWith(linePrefix)) return null;
    final body = line.substring(linePrefix.length).trim();
    if (body.isEmpty) return null;
    final split = body.lastIndexOf(separator);
    if (split <= 0) return QuotedSong(title: body, artist: '');
    return QuotedSong(
      title: body.substring(0, split).trim(),
      artist: body.substring(split + separator.length).trim(),
    );
  }

  bool sameSong(QuotedSong other) => trackId != null && other.trackId != null
      ? trackId == other.trackId
      : title == other.title && artist == other.artist;
}

/// The message [quotes] and [text] go out as: one quote line each, then the
/// listener's own words. No quotes leaves [text] as it is.
String composeQuotedMessage(List<QuotedSong> quotes, String text) {
  final body = text.trim();
  if (quotes.isEmpty) return body;
  return [for (final quote in quotes) quote.line, body].join('\n');
}

/// The quotes a sent message opens with, and the words after them. A message
/// with no leading quote lines comes back whole as [text].
({List<QuotedSong> quotes, String text}) splitQuotedMessage(String message) {
  final lines = message.split('\n');
  final quotes = <QuotedSong>[];
  var i = 0;
  for (; i < lines.length; i++) {
    final quote = QuotedSong.parse(lines[i]);
    if (quote == null) break;
    quotes.add(quote);
  }
  if (quotes.isEmpty) return (quotes: const [], text: message);
  return (quotes: quotes, text: lines.skip(i).join('\n').trim());
}

/// A mix's unsent message: the words in the field and the songs quoted above
/// it.
class MixDraft extends ChangeNotifier {
  final TextEditingController controller = TextEditingController();
  final List<QuotedSong> _quotes = [];

  List<QuotedSong> get quotes => List.unmodifiable(_quotes);

  bool get isEmpty => controller.text.trim().isEmpty && _quotes.isEmpty;

  /// What Send posts.
  String get outgoing => composeQuotedMessage(_quotes, controller.text);

  /// Pins [song] above the field; a song already quoted stays put.
  void quote(QuotedSong song) {
    if (_quotes.any(song.sameSong)) return;
    _quotes.add(song);
    notifyListeners();
  }

  void unquote(QuotedSong song) {
    final before = _quotes.length;
    _quotes.removeWhere(song.sameSong);
    if (_quotes.length != before) notifyListeners();
  }

  void clear() {
    controller.clear();
    if (_quotes.isEmpty) return;
    _quotes.clear();
    notifyListeners();
  }

  /// Puts a sent [message] back (a stopped or refused turn), quotes and all,
  /// unless the listener has already started another.
  void restore(String message) {
    if (!isEmpty) return;
    final split = splitQuotedMessage(message);
    _quotes.addAll(split.quotes);
    controller.value = TextEditingValue(
      text: split.text,
      selection: TextSelection.collapsed(offset: split.text.length),
    );
    notifyListeners();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}

/// The one draft per mix, alive while either composer is on screen.
final mixDraftProvider = Provider.autoDispose.family<MixDraft, String>((
  ref,
  sessionId,
) {
  final draft = MixDraft();
  ref.onDispose(draft.dispose);
  return draft;
});

/// The quoted songs over the composer, each with its cross, on one row that
/// scrolls sideways. A newly quoted song slides the row to the end so it is
/// always in view. Draws nothing with nothing quoted.
class QuoteChips extends StatefulWidget {
  const QuoteChips({super.key, required this.draft, this.enabled = true});

  final MixDraft draft;
  final bool enabled;

  static const Key rowKey = Key('quote-chips-row');

  static Key chipKey(QuotedSong song) =>
      ValueKey('quote-chip-${song.trackId ?? song.label}');
  static Key removeKey(QuotedSong song) =>
      ValueKey('quote-remove-${song.trackId ?? song.label}');

  @override
  State<QuoteChips> createState() => _QuoteChipsState();
}

class _QuoteChipsState extends State<QuoteChips> {
  final _scroll = ScrollController();
  int _count = 0;

  @override
  void initState() {
    super.initState();
    _count = widget.draft.quotes.length;
    widget.draft.addListener(_onDraft);
  }

  @override
  void didUpdateWidget(QuoteChips old) {
    super.didUpdateWidget(old);
    if (old.draft != widget.draft) {
      old.draft.removeListener(_onDraft);
      widget.draft.addListener(_onDraft);
      _count = widget.draft.quotes.length;
    }
  }

  @override
  void dispose() {
    widget.draft.removeListener(_onDraft);
    _scroll.dispose();
    super.dispose();
  }

  void _onDraft() {
    final count = widget.draft.quotes.length;
    final grew = count > _count;
    setState(() => _count = count);
    if (!grew) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      if (MediaQuery.disableAnimationsOf(context)) {
        _scroll.jumpTo(end);
      } else {
        _scroll.animateTo(
          end,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final quotes = widget.draft.quotes;
    if (quotes.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SizedBox(
        height: _QuoteChip.height,
        child: ListView.separated(
          key: QuoteChips.rowKey,
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          itemCount: quotes.length,
          separatorBuilder: (_, _) => const SizedBox(width: 6),
          itemBuilder: (context, i) => _QuoteChip(
            key: QuoteChips.chipKey(quotes[i]),
            song: quotes[i],
            onRemove: widget.enabled
                ? () => widget.draft.unquote(quotes[i])
                : null,
          ),
        ),
      ),
    );
  }
}

class _QuoteChip extends StatelessWidget {
  const _QuoteChip({super.key, required this.song, this.onRemove});

  final QuotedSong song;
  final VoidCallback? onRemove;

  static const double height = 32;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      constraints: const BoxConstraints(minHeight: height, maxWidth: 260),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.08)
            : const Color.fromRGBO(247, 244, 239, 0.60),
        borderRadius: BorderRadius.circular(MixtapeMetrics.pillRadius),
        border: Border.all(color: tokens.plum.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 10),
          Icon(CupertinoIcons.quote_bubble, size: 14, color: tokens.plum),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              song.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              semanticsLabel: 'Quoting ${song.label}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: tokens.plum,
              ),
            ),
          ),
          if (onRemove != null)
            Semantics(
              button: true,
              label: 'Remove quote',
              excludeSemantics: true,
              onTap: onRemove,
              child: GestureDetector(
                key: QuoteChips.removeKey(song),
                behavior: HitTestBehavior.opaque,
                onTap: onRemove,
                child: SizedBox(
                  width: height,
                  height: height,
                  child: Icon(
                    CupertinoIcons.xmark,
                    size: 12,
                    color: tokens.plum,
                  ),
                ),
              ),
            )
          else
            const SizedBox(width: 12),
        ],
      ),
    );
  }
}

/// A sent turn's quotes in the transcript: one quiet line per song, over the
/// listener's words, aligned with them.
class QuotedSongLines extends StatelessWidget {
  const QuotedSongLines({
    super.key,
    required this.quotes,
    this.alignment = CrossAxisAlignment.end,
  });

  final List<QuotedSong> quotes;
  final CrossAxisAlignment alignment;

  static const Key lineKey = Key('quoted-song-line');

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final style = tokens.meta.copyWith(
      color: tokens.muted,
      fontWeight: FontWeight.w600,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: alignment,
      children: [
        for (final song in quotes)
          Padding(
            key: lineKey,
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  CupertinoIcons.quote_bubble,
                  size: 13,
                  color: tokens.muted,
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    song.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    semanticsLabel: 'Quoting ${song.label}',
                    style: style,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
