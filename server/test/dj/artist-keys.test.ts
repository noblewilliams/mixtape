import { describe, it, expect } from 'vitest'
import { sql } from 'drizzle-orm'
import { createTestDb } from '../helpers/db'
import { tracks } from '../../src/db/schema'
import { artistKey, creditedArtists, creditedKeys } from '../../src/dj/artist-keys'

// Spellings that must fold to one key.
const KEY_CASES: [string, string][] = [
  ['jay z', 'jayz'],
  ['Jaÿ-Z', 'jayz'],
  ['JAY-Z', 'jayz'],
  ['jay-z', 'jayz'],
  ['jaÿ-z', 'jayz'],
  ['beyoncé', 'beyonce'],
  ['Beyoncé', 'beyonce'],
  ['Kids See Ghosts', 'kidsseeghosts'],
  ['Beyoncé ❤️', 'beyonce'],
  ['Beyonce\u20dd', 'beyonce'],
  ['Mø', 'mo'],
  ['Sigur Rós', 'sigurros'],
  ['Motörhead', 'motorhead'],
  ['Céline Dion', 'celinedion'],
  ['Ólafur Arnalds', 'olafurarnalds'],
  ['Straßenjungs', 'strassenjungs'],
  ['Æther Realm', 'aetherrealm'],
  ['Œil', 'oeil'],
  ['Łona', 'lona'],
  ['Đorđe Balašević', 'dordebalasevic'],
  // `$` touching a letter reads as "s"; a lone `$` is dropped.
  ['Ty Dolla $ign', 'tydollasign'],
  ['ty dolla sign', 'tydollasign'],
  ['A$AP Rocky', 'asaprocky'],
  ['Ke$ha', 'kesha'],
  ['$uicideboy$', 'suicideboys'],
  ['¥$', ''],
  ['21 Savage', '21savage'],
  ['宇多田ヒカル', '宇多田ヒカル'],
  ['', ''],
]

// Latin letters we expect to fold to ASCII, lower and upper.
const DIACRITICS =
  'àáâäãåāăąçćčďđèéêëēėęěìíîïīįıľłñńňòóôöõøōőŕřśşšţťùúûüūůűųýÿźżž' +
  'ÀÁÂÄÃÅĀĂĄÇĆČĎĐÈÉÊËĒĖĘĚÌÍÎÏĪĮĽŁÑŃŇÒÓÔÖÕØŌŐŔŘŚŞŠŢŤÙÚÛÜŪŮŰŲÝŸŹŻŽ' +
  'ßẞæÆœŒ'

// Scripts and forms beyond the catalogue's Latin, checked only for agreement.
const AGREEMENT_EXTRAS = [
  'アイナ・ジ・エンド', 'ガガ', '아이유', 'अरिजीत सिंह', 'ลิซ่า', 'Sơn Tùng M-TP',
  'Ọlamide', 'Àṣà', 'ΣΑΒΒΑΣ', 'Βασίλης Παπακωνσταντίνου', 'Ｐｅｒｆｕｍｅ', 'ﬁve',
  'İbrahim Tatlıses', 'Björk feat. Sigur Rós', 'Мумий Тролль', 'Ⅻ', 'Mac DeMarco ft Ñu',
]

const CREDIT_CASES: { credit: string; artists: string[]; keys: string[] }[] = [
  {
    credit: '¥$, kanye west & ty dolla $ign',
    artists: ['¥$', 'kanye west', 'ty dolla $ign'],
    keys: ['kanyewest', 'tydollasign', 'kanyewesttydollasign'],
  },
  {
    credit: 'jaÿ-z & kanye west',
    artists: ['jaÿ-z', 'kanye west'],
    keys: ['jayz', 'kanyewest', 'jayzkanyewest'],
  },
  { credit: 'drake x future', artists: ['drake', 'future'], keys: ['drake', 'future', 'drakexfuture'] },
  { credit: 'Drake X Future', artists: ['Drake', 'Future'], keys: ['drake', 'future', 'drakexfuture'] },
  { credit: 'Tems feat. Wizkid', artists: ['Tems', 'Wizkid'], keys: ['tems', 'wizkid', 'temsfeatwizkid'] },
  { credit: 'Tems FEAT Wizkid', artists: ['Tems', 'Wizkid'], keys: ['tems', 'wizkid', 'temsfeatwizkid'] },
  { credit: 'Wizkid ft. Tems', artists: ['Wizkid', 'Tems'], keys: ['wizkid', 'tems', 'wizkidfttems'] },
  { credit: 'Wizkid ft Tems', artists: ['Wizkid', 'Tems'], keys: ['wizkid', 'tems', 'wizkidfttems'] },
  {
    credit: 'Metro Boomin with Future',
    artists: ['Metro Boomin', 'Future'],
    keys: ['metroboomin', 'future', 'metroboominwithfuture'],
  },
  { credit: 'Burna Boy × Ed Sheeran', artists: ['Burna Boy', 'Ed Sheeran'], keys: ['burnaboy', 'edsheeran', 'burnaboyedsheeran'] },
  { credit: 'drake & 21 savage', artists: ['drake', '21 savage'], keys: ['drake', '21savage', 'drake21savage'] },
  { credit: 'beyoncé', artists: ['beyoncé'], keys: ['beyonce'] },
  { credit: 'Kids See Ghosts', artists: ['Kids See Ghosts'], keys: ['kidsseeghosts'] },
  // The whole credit is a key too (separator words and all), so a seed for a name that contains a
  // separator still matches.
  { credit: 'Tyler, The Creator', artists: ['Tyler', 'The Creator'], keys: ['tyler', 'thecreator', 'tylerthecreator'] },
  { credit: 'Simon & Garfunkel', artists: ['Simon', 'Garfunkel'], keys: ['simon', 'garfunkel', 'simongarfunkel'] },
  // Separators are word-bounded: letters inside names never split.
  { credit: 'Xzibit', artists: ['Xzibit'], keys: ['xzibit'] },
  { credit: 'Within Temptation', artists: ['Within Temptation'], keys: ['withintemptation'] },
  { credit: 'Feather & Fox', artists: ['Feather', 'Fox'], keys: ['feather', 'fox', 'featherfox'] },
  { credit: 'Ftsk', artists: ['Ftsk'], keys: ['ftsk'] },
  { credit: 'Jay-Z & JAY Z', artists: ['Jay-Z', 'JAY Z'], keys: ['jayz', 'jayzjayz'] },
  { credit: '  , drake ,  ', artists: ['drake'], keys: ['drake'] },
  { credit: 'Tems\u00a0feat.\u00a0Wizkid', artists: ['Tems', 'Wizkid'], keys: ['tems', 'wizkid', 'temsfeatwizkid'] },
  { credit: 'Drake\u2009&\u2009Future', artists: ['Drake', 'Future'], keys: ['drake', 'future', 'drakefuture'] },
  { credit: '宇多田ヒカル\u3000x\u3000椎名林檎', artists: ['宇多田ヒカル', '椎名林檎'], keys: ['宇多田ヒカル', '椎名林檎', '宇多田ヒカルx椎名林檎'] },
  { credit: '', artists: [], keys: [] },
]

describe('artistKey', () => {
  it.each(KEY_CASES)('folds %j to %j', (name, key) => {
    expect(artistKey(name)).toBe(key)
  })
})

describe('creditedArtists and creditedKeys', () => {
  it.each(CREDIT_CASES)('splits $credit', ({ credit, artists, keys }) => {
    expect(creditedArtists(credit)).toEqual(artists)
    expect(creditedKeys(credit)).toEqual(keys)
  })
})

describe('artist_keys SQL function', () => {
  it('agrees with the TypeScript helpers on every case', async () => {
    const db = await createTestDb()
    const inputs = [
      ...KEY_CASES.map(([name]) => name),
      ...CREDIT_CASES.map((c) => c.credit),
      ...[...DIACRITICS],
      ...AGREEMENT_EXTRAS,
    ]
    for (const input of inputs) {
      const result = await db.execute<{ key: string; keys: string[] }>(
        sql`SELECT artist_key(${input}) AS key, artist_keys(${input}) AS keys`,
      )
      expect({ input, ...result.rows[0] }).toEqual({
        input,
        key: artistKey(input),
        keys: creditedKeys(input),
      })
    }
  })

  it('folds every letter in the translate table to plain Latin', () => {
    for (const ch of DIACRITICS) {
      expect(artistKey(ch), ch).toMatch(/^[a-z]+$/)
    }
  })

  it('fills tracks.artist_keys on insert and indexes it with GIN', async () => {
    const db = await createTestDb()
    const [row] = await db
      .insert(tracks)
      .values({ title: 'Watch the Throne cut', artist: 'jaÿ-z & kanye west' })
      .returning()
    expect(row.artistKeys).toEqual(['jayz', 'kanyewest', 'jayzkanyewest'])

    const [updated] = await db
      .update(tracks)
      .set({ artist: 'Beyoncé' })
      .where(sql`${tracks.id} = ${row.id}`)
      .returning()
    expect(updated.artistKeys).toEqual(['beyonce'])

    const matched = await db.execute<{ id: string }>(
      sql`SELECT id FROM tracks WHERE artist_keys && ARRAY[${artistKey('Beyonce')}]::text[]`,
    )
    expect(matched.rows.map((r) => r.id)).toEqual([row.id])

    const index = await db.execute<{ indexdef: string }>(
      sql`SELECT indexdef FROM pg_indexes WHERE tablename = 'tracks' AND indexname = 'tracks_artist_keys_idx'`,
    )
    expect(index.rows[0]?.indexdef).toMatch(/USING gin \(artist_keys\)/)
  })
})
