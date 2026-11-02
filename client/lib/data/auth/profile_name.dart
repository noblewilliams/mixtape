/// The profile name rule (spec 2026-11-02 profile name), mirrored from
/// `server/src/auth/profile-name.ts` (and `web/src/lib/profile-name.ts`) so
/// the field never disagrees with what the server will store. The server
/// applies it again on every write; keep the copies in step.
library;

import 'package:characters/characters.dart';
import 'package:flutter/services.dart';

const int profileNameMax = 40;

// Line and other whitespace controls become spaces; every other control (Cc),
// lone surrogate (Cs) and format character (Cf) is dropped, except ZWNJ and
// ZWJ, which joined emoji and Persian or Indic spelling need.
final _whitespaceControls = RegExp('[\t\n\u000b\u000c\r\u0085]');
final _dropped = RegExp(
  r'[\p{Cc}\p{Cs}]|(?![\u200c\u200d])\p{Cf}',
  unicode: true,
);
final _spaces = RegExp(r'\s+');

/// The stored shape: cleaned, whitespace collapsed, trimmed, capped in whole
/// characters. Blank means no name.
String normalizeProfileName(String raw) {
  final cleaned = cleanNameInput(raw).replaceAll(_spaces, ' ').trim();
  return capWhole(cleaned, profileNameMax).trim();
}

/// What the field accepts while typing: the character rule only, no trim or
/// collapse, so the caret never jumps.
String cleanNameInput(String raw) =>
    raw.replaceAll(_whitespaceControls, ' ').replaceAll(_dropped, '');

/// Length as the server counts it: code points.
int nameLength(String text) => text.runes.length;

/// At most [max] code points, taken in whole user-perceived characters so a
/// flag, a joined emoji or a letter and its accent is kept or dropped whole.
String capWhole(String text, int max) {
  final out = StringBuffer();
  var used = 0;
  for (final character in text.characters) {
    final size = nameLength(character);
    if (used + size > max) break;
    out.write(character);
    used += size;
  }
  return out.toString();
}

/// One edit after the hard stop: the value to show and whether input was
/// refused or cut to fit.
typedef NameEdit = ({TextEditingValue value, bool cut});

/// A hard stop at 40 for an edit from [previous] to [next]. Only the inserted
/// text is cleaned and trimmed to fit; the text around it is kept, and an
/// insert with no room is refused with the caret left where it was.
NameEdit applyNameEdit(TextEditingValue previous, TextEditingValue next) {
  final prev = previous.text;
  final text = next.text;
  final caret = next.selection.isValid ? next.selection.end : null;
  var suffix = 0;
  if (caret != null &&
      caret <= text.length &&
      prev.endsWith(text.substring(caret))) {
    suffix = text.length - caret;
  } else {
    while (suffix < prev.length &&
        suffix < text.length &&
        prev[prev.length - 1 - suffix] == text[text.length - 1 - suffix]) {
      suffix++;
    }
  }
  // Never end the kept tail inside a surrogate pair (😀 → 🈀 share the low
  // half): give the whole character to the edit.
  if (suffix > 0 && _isLow(prev.codeUnitAt(prev.length - suffix))) suffix--;
  final limit = (prev.length - suffix) < (text.length - suffix)
      ? prev.length - suffix
      : text.length - suffix;
  var prefix = 0;
  while (prefix < limit && prev[prefix] == text[prefix]) {
    prefix++;
  }
  // Nor start the edit inside one (😀 → 😃 share the high half).
  if (prefix > 0 && _isHigh(prev.codeUnitAt(prefix - 1))) prefix--;

  final before = prev.substring(0, prefix);
  final after = prev.substring(prev.length - suffix);
  final removed = prev.substring(prefix, prev.length - suffix);
  final inserted = cleanNameInput(text.substring(prefix, text.length - suffix));
  final room = profileNameMax - nameLength(before) - nameLength(after);
  final kept = capWhole(inserted, room < 0 ? 0 : room);
  final cut = kept.length < inserted.length;
  if (cut && kept.isEmpty && removed.isEmpty) {
    return (
      value: TextEditingValue(
        text: prev,
        selection: TextSelection.collapsed(offset: prefix),
      ),
      cut: true,
    );
  }
  final result = before + kept + after;
  if (result == text && !cut) return (value: next, cut: false);
  return (
    value: TextEditingValue(
      text: result,
      selection: TextSelection.collapsed(offset: prefix + kept.length),
    ),
    cut: cut,
  );
}

bool _isHigh(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
bool _isLow(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// The text the keyboard has committed: [value] without its composing
/// (marked) range, which an IME may still change.
String committedText(TextEditingValue value) {
  final composing = value.composing;
  if (!composing.isValid || composing.isCollapsed) return value.text;
  return composing.textBefore(value.text) + composing.textAfter(value.text);
}

/// The field's hard stop. Composing (marked) text from an IME passes through
/// untouched until it is committed, then the commit is measured against the
/// last committed text, so a half-typed word is never cut.
class ProfileNameFormatter extends TextInputFormatter {
  ProfileNameFormatter({required this.onCut});

  /// Told after every committed edit whether input was refused or cut.
  final void Function(bool cut) onCut;

  TextEditingValue? _committed;

  static bool _composing(TextEditingValue value) =>
      value.composing.isValid && !value.composing.isCollapsed;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (_composing(newValue)) {
      if (!_composing(oldValue)) _committed = oldValue;
      return newValue;
    }
    final previous = _composing(oldValue) ? (_committed ?? oldValue) : oldValue;
    _committed = null;
    var edit = applyNameEdit(previous, newValue);
    // A previous value already over the limit (set from outside): cap whole.
    if (nameLength(edit.value.text) > profileNameMax) {
      final capped = capWhole(edit.value.text, profileNameMax);
      edit = (
        value: TextEditingValue(
          text: capped,
          selection: TextSelection.collapsed(offset: capped.length),
        ),
        cut: true,
      );
    }
    onCut(edit.cut);
    return edit.value;
  }
}
