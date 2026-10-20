import { describe, it, expect } from 'vitest'
import { ALBUM_TOOLS, ALBUM_TYPES, recommendAlbumInputSchema } from '../../src/albums/contracts'
import { rememberPreferenceJsonSchema, renameSessionJsonSchema } from '../../src/dj/contracts'

// The same minimal JSON Schema matcher test/dj/contracts.test.ts uses, cut to
// the keywords recommend_album's schema carries.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function matchesJsonSchema(schema: any, value: unknown): boolean {
  switch (schema.type) {
    case 'object': {
      if (typeof value !== 'object' || value === null || Array.isArray(value)) return false
      const obj = value as Record<string, unknown>
      for (const req of schema.required ?? []) if (!(req in obj)) return false
      for (const [key, val] of Object.entries(obj)) {
        const prop = schema.properties?.[key]
        if (!prop) {
          if (schema.additionalProperties === false) return false
          continue
        }
        if (!matchesJsonSchema(prop, val)) return false
      }
      return true
    }
    case 'array':
      if (!Array.isArray(value)) return false
      if (schema.minItems !== undefined && value.length < schema.minItems) return false
      if (schema.maxItems !== undefined && value.length > schema.maxItems) return false
      return value.every((v) => matchesJsonSchema(schema.items, v))
    case 'string':
      if (typeof value !== 'string') return false
      if (schema.minLength !== undefined && value.length < schema.minLength) return false
      if (schema.maxLength !== undefined && value.length > schema.maxLength) return false
      if (schema.enum && !schema.enum.includes(value)) return false
      return true
    case 'integer':
      if (typeof value !== 'number' || !Number.isInteger(value)) return false
      if (schema.minimum !== undefined && value < schema.minimum) return false
      if (schema.maximum !== undefined && value > schema.maximum) return false
      return true
    case 'boolean':
      return typeof value === 'boolean'
    default:
      return false
  }
}

const one = { artist: 'Sade', title: 'Love Deluxe', type: 'album', why: 'quiet and warm' }

describe('recommendAlbumInputSchema', () => {
  it('accepts a full input', () => {
    const parsed = recommendAlbumInputSchema.parse({
      familiarity: 'adventurous',
      candidates: [{ ...one, year: 1992, fromShelf: true }],
    })
    expect(parsed.familiarity).toBe('adventurous')
    expect(parsed.candidates[0]).toEqual({ ...one, year: 1992, fromShelf: true })
  })

  it('defaults familiarity to mix', () => {
    expect(recommendAlbumInputSchema.parse({ candidates: [one] }).familiarity).toBe('mix')
  })

  it('rejects zero and six candidates', () => {
    expect(recommendAlbumInputSchema.safeParse({ candidates: [] }).success).toBe(false)
    expect(recommendAlbumInputSchema.safeParse({ candidates: Array(6).fill(one) }).success).toBe(false)
    expect(recommendAlbumInputSchema.safeParse({ candidates: Array(5).fill(one) }).success).toBe(true)
  })

  it('rejects a bad type, a long why and unknown keys', () => {
    expect(recommendAlbumInputSchema.safeParse({ candidates: [{ ...one, type: 'boxset' }] }).success).toBe(false)
    expect(recommendAlbumInputSchema.safeParse({ candidates: [{ ...one, why: 'x'.repeat(301) }] }).success).toBe(false)
    expect(recommendAlbumInputSchema.safeParse({ candidates: [one], mood: 'x' }).success).toBe(false)
    expect(recommendAlbumInputSchema.safeParse({ candidates: [{ ...one, label: 'x' }] }).success).toBe(false)
  })
})

type Row = { label: string; sample: unknown }
const rows: Row[] = [
  { label: 'minimal valid', sample: { candidates: [one] } },
  { label: 'full valid', sample: { familiarity: 'comfort', candidates: [{ ...one, year: 2001, fromShelf: false }] } },
  { label: 'five candidates valid', sample: { candidates: Array(5).fill(one) } },
  { label: 'every type valid', sample: { candidates: ALBUM_TYPES.slice(0, 5).map((type) => ({ ...one, type })) } },
  { label: 'why at 300 valid', sample: { candidates: [{ ...one, why: 'x'.repeat(300) }] } },
  { label: 'artist at 200 valid', sample: { candidates: [{ ...one, artist: 'x'.repeat(200) }] } },
  { label: 'year 1900 valid', sample: { candidates: [{ ...one, year: 1900 }] } },
  { label: 'missing candidates invalid', sample: {} },
  { label: 'zero candidates invalid', sample: { candidates: [] } },
  { label: 'six candidates invalid', sample: { candidates: Array(6).fill(one) } },
  { label: 'bad familiarity invalid', sample: { familiarity: 'chaotic', candidates: [one] } },
  { label: 'bad type invalid', sample: { candidates: [{ ...one, type: 'boxset' }] } },
  { label: 'why at 301 invalid', sample: { candidates: [{ ...one, why: 'x'.repeat(301) }] } },
  { label: 'empty why invalid', sample: { candidates: [{ ...one, why: '' }] } },
  { label: 'empty artist invalid', sample: { candidates: [{ ...one, artist: '' }] } },
  { label: 'title at 201 invalid', sample: { candidates: [{ ...one, title: 'x'.repeat(201) }] } },
  { label: 'year 1899 invalid', sample: { candidates: [{ ...one, year: 1899 }] } },
  { label: 'year 2101 invalid', sample: { candidates: [{ ...one, year: 2101 }] } },
  { label: 'fractional year invalid', sample: { candidates: [{ ...one, year: 1999.5 }] } },
  { label: 'missing type invalid', sample: { candidates: [{ artist: 'a', title: 't', why: 'w' }] } },
  { label: 'unknown top-level key invalid', sample: { candidates: [one], mood: 'x' } },
  { label: 'unknown candidate key invalid', sample: { candidates: [{ ...one, label: 'x' }] } },
  { label: 'non-boolean fromShelf invalid', sample: { candidates: [{ ...one, fromShelf: 'yes' }] } },
]

describe('recommend_album: zod and its JSON schema agree', () => {
  const schema = ALBUM_TOOLS.find((t) => t.name === 'recommend_album')!.input_schema
  const results = rows.map((row) => ({
    label: row.label,
    zod: recommendAlbumInputSchema.safeParse(row.sample).success,
    json: matchesJsonSchema(schema, row.sample),
  }))

  it.each(results)('$label', ({ zod, json }) => {
    expect(json).toBe(zod)
  })

  it('exercises both valid and invalid samples', () => {
    expect(results.some((r) => r.zod)).toBe(true)
    expect(results.some((r) => !r.zod)).toBe(true)
  })

  it('advertises the same type enum as ALBUM_TYPES', () => {
    const items = (schema.properties.candidates as { items: { properties: { type: { enum: string[] } } } }).items
    expect(items.properties.type.enum).toEqual([...ALBUM_TYPES])
  })
})

describe('ALBUM_TOOLS', () => {
  it('has exactly recommend_album, remember_preference and rename_session', () => {
    expect(ALBUM_TOOLS.map((t) => t.name)).toEqual(['recommend_album', 'remember_preference', 'rename_session'])
  })

  it('is frozen with frozen schemas, reusing the DJ preference and rename schemas', () => {
    expect(Object.isFrozen(ALBUM_TOOLS)).toBe(true)
    for (const tool of ALBUM_TOOLS) expect(Object.isFrozen(tool.input_schema)).toBe(true)
    expect(ALBUM_TOOLS[1].input_schema).toBe(rememberPreferenceJsonSchema)
    expect(ALBUM_TOOLS[2].input_schema).toBe(renameSessionJsonSchema)
  })

  it('tells the model never to show an album the result did not confirm', () => {
    expect(ALBUM_TOOLS[0].description).toMatch(/never/i)
    expect(JSON.stringify(ALBUM_TOOLS[0])).not.toContain('—')
  })
})
