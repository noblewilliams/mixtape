// Artist keys: one folded spelling per credited artist, so "jay z", "JAY-Z"
// and "jaÿ-z" match (spec 2026-10-21 everyone-gets-a-mix, step 1).
//
// The Postgres function `artist_keys(text)` (migration 0040_artist_keys)
// fills `tracks.artist_keys` and must agree with these helpers exactly;
// test/dj/artist-keys.test.ts checks both on the same table. Change them
// together, in a new migration, and have that migration also recompute the
// stored rows (`UPDATE tracks SET artist = artist`): replacing the function
// does not rewrite a generated column that is already stored.

// Letters NFKD does not decompose. `ς` is final sigma, which JS lowercases
// by context and Postgres does not.
const FOLD: Record<string, string> = {
  ß: 'ss',
  æ: 'ae',
  œ: 'oe',
  ł: 'l',
  đ: 'd',
  ø: 'o',
  ı: 'i',
  ς: 'σ',
}

// Only Latin combining diacritics are stripped, so kana voicing marks and
// Hangul survive (NFC puts them back together).
const COMBINING_DIACRITICS = /[\u0300-\u036f]/g

// `$` touching a Latin letter reads as "s" (Ty Dolla $ign, A$AP, Ke$ha); a
// `$` on its own, as in "¥$", is dropped with the other symbols.
const DOLLAR_AS_S = /(?<=[a-z])\$|\$(?=[a-z])/g

// Punctuation, spaces and symbols, listed by range rather than by Unicode
// class: Postgres classes follow the server's libc, and the column must not
// change with it. Everything else (letters, digits, marks of any script)
// stays. Same ranges as the SQL in migration 0040_artist_keys.
const NOT_LETTER_OR_DIGIT =
  /[\x00-\x2f\x3a-\x40\x5b-\x60\x7b-\xbf\xd7\xf7\u02b9-\u02ff\u2000-\u206f\u20a0-\u20ff\u2190-\u2bff\u3000-\u3003\u3008-\u3011\u3014-\u301f\u30fb\ufe00-\ufe0f\ufeff\u{1f000}-\u{1faff}]/gu

// `,`, or `&` `feat.` `feat` `ft.` `ft` `with` `x` `×` between spaces. The
// space class is explicit (no-break, thin and ideographic spaces included)
// because JS `\s` and the Postgres regex disagree on no-break space.
const CREDIT_SEPARATOR = /[ \t\n\r\u00a0\u2000-\u200a\u202f\u205f\u3000]*,[ \t\n\r\u00a0\u2000-\u200a\u202f\u205f\u3000]*|[ \t\n\r\u00a0\u2000-\u200a\u202f\u205f\u3000]+(?:&|feat\.?|ft\.?|with|x|×)[ \t\n\r\u00a0\u2000-\u200a\u202f\u205f\u3000]+/i

export function artistKey(name: string): string {
  return name
    .toLowerCase()
    .replace(/[ßæœłđøıς]/g, (ch) => FOLD[ch])
    .normalize('NFKD')
    .replace(COMBINING_DIACRITICS, '')
    .normalize('NFC')
    .toLowerCase()
    .replace(DOLLAR_AS_S, 's')
    .replace(NOT_LETTER_OR_DIGIT, '')
}

export function creditedArtists(credit: string): string[] {
  return credit
    .split(CREDIT_SEPARATOR)
    .map((part) => part.trim())
    .filter((part) => part !== '')
}

// Keys of each credited artist, then the whole credit's key, distinct and in
// order. The whole credit counts so a name that holds a separator ("Tyler,
// The Creator", "Simon & Garfunkel") still matches a seed spelled whole.
export function creditedKeys(credit: string): string[] {
  const keys = [...creditedArtists(credit), credit].map(artistKey)
  return [...new Set(keys)].filter((key) => key !== '')
}
