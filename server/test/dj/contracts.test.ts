import { describe, it, expect } from 'vitest'
import { intentSchema, opIntentSchema, queueOpSchema, queueOpsSchema, DJ_TOOLS } from '../../src/dj/contracts'

describe('intentSchema', () => {
  it('parses a valid intent, applying defaults', () => {
    const result = intentSchema.parse({ themes: 'rainy night drive' })
    expect(result).toEqual({
      themes: 'rainy night drive',
      allowExplicit: true,
      familiarity: 'mix',
      targetCount: 15,
    })
  })

  it('rejects empty themes', () => {
    expect(() => intentSchema.parse({ themes: '' })).toThrow()
  })

  it('rejects a missing themes field', () => {
    expect(() => intentSchema.parse({})).toThrow()
  })

  it('enforces tempo bounds', () => {
    expect(() => intentSchema.parse({ themes: 'x', tempoMin: 39 })).toThrow()
    expect(() => intentSchema.parse({ themes: 'x', tempoMax: 261 })).toThrow()
    expect(intentSchema.parse({ themes: 'x', tempoMin: 40, tempoMax: 260 })).toMatchObject({
      tempoMin: 40,
      tempoMax: 260,
    })
  })

  it('enforces era bounds', () => {
    expect(() => intentSchema.parse({ themes: 'x', eraFrom: 1899 })).toThrow()
    expect(() => intentSchema.parse({ themes: 'x', eraTo: 2101 })).toThrow()
    expect(intentSchema.parse({ themes: 'x', eraFrom: 1900, eraTo: 2100 })).toMatchObject({
      eraFrom: 1900,
      eraTo: 2100,
    })
  })

  it('enforces targetCount bounds', () => {
    expect(() => intentSchema.parse({ themes: 'x', targetCount: 2 })).toThrow()
    expect(() => intentSchema.parse({ themes: 'x', targetCount: 61 })).toThrow()
    expect(intentSchema.parse({ themes: 'x', targetCount: 3 }).targetCount).toBe(3)
    expect(intentSchema.parse({ themes: 'x', targetCount: 60 }).targetCount).toBe(60)
  })

  it('rejects an invalid energyArc value', () => {
    expect(() => intentSchema.parse({ themes: 'x', energyArc: 'sideways' })).toThrow()
    expect(intentSchema.parse({ themes: 'x', energyArc: 'arc' }).energyArc).toBe('arc')
  })

  it('rejects an invalid familiarity value', () => {
    expect(() => intentSchema.parse({ themes: 'x', familiarity: 'chaotic' })).toThrow()
    expect(intentSchema.parse({ themes: 'x', familiarity: 'comfort' }).familiarity).toBe('comfort')
  })

  it('allows allowExplicit to be overridden to false', () => {
    expect(intentSchema.parse({ themes: 'x', allowExplicit: false }).allowExplicit).toBe(false)
  })
})

describe('cross-field window ordering', () => {
  it('rejects an inverted tempo window', () => {
    expect(() => intentSchema.parse({ themes: 'x', tempoMin: 200, tempoMax: 100 })).toThrow()
  })

  it('accepts an equal tempo window (equal is not inverted)', () => {
    expect(intentSchema.parse({ themes: 'x', tempoMin: 120, tempoMax: 120 }).tempoMin).toBe(120)
  })

  it('rejects an inverted era window', () => {
    expect(() => intentSchema.parse({ themes: 'x', eraFrom: 2000, eraTo: 1990 })).toThrow()
  })

  it('accepts an equal era window (equal is not inverted)', () => {
    expect(intentSchema.parse({ themes: 'x', eraFrom: 2000, eraTo: 2000 }).eraFrom).toBe(2000)
  })

  it('applies the same ordering check to opIntentSchema', () => {
    expect(() => opIntentSchema.parse({ themes: 'x', tempoMin: 200, tempoMax: 100 })).toThrow()
    expect(() => opIntentSchema.parse({ themes: 'x', eraFrom: 2000, eraTo: 1990 })).toThrow()
  })

  it('rejects an inverted tempo window nested in a swap op intent', () => {
    expect(() =>
      queueOpSchema.parse({ op: 'swap', position: 0, intent: { themes: 'x', tempoMin: 200, tempoMax: 100 } }),
    ).toThrow()
  })
})

describe('opIntentSchema', () => {
  it('has no targetCount field at all', () => {
    expect(opIntentSchema.parse({ themes: 'x' })).not.toHaveProperty('targetCount')
  })

  it('silently strips a targetCount the caller still sends (lenient, not strict)', () => {
    const parsed = opIntentSchema.parse({ themes: 'x', targetCount: 99 } as never)
    expect(parsed).not.toHaveProperty('targetCount')
  })

  it('still applies allowExplicit/familiarity defaults', () => {
    expect(opIntentSchema.parse({ themes: 'x' })).toEqual({ themes: 'x', allowExplicit: true, familiarity: 'mix' })
  })
})

describe('queueOpSchema', () => {
  it('parses a remove op', () => {
    expect(queueOpSchema.parse({ op: 'remove', position: 0 })).toEqual({ op: 'remove', position: 0 })
  })

  it('rejects a remove op with a negative position', () => {
    expect(() => queueOpSchema.parse({ op: 'remove', position: -1 })).toThrow()
  })

  it('parses a move op', () => {
    expect(queueOpSchema.parse({ op: 'move', from: 0, to: 2 })).toEqual({ op: 'move', from: 0, to: 2 })
  })

  it('parses a swap op without an intent', () => {
    expect(queueOpSchema.parse({ op: 'swap', position: 1 })).toEqual({ op: 'swap', position: 1 })
  })

  it('parses a swap op with an intent, applying intent defaults but never a targetCount', () => {
    const parsed = queueOpSchema.parse({ op: 'swap', position: 1, intent: { themes: 'more chill' } })
    expect(parsed).toEqual({
      op: 'swap',
      position: 1,
      intent: { themes: 'more chill', allowExplicit: true, familiarity: 'mix' },
    })
  })

  it('parses an extend op without an intent', () => {
    expect(queueOpSchema.parse({ op: 'extend', count: 5 })).toEqual({ op: 'extend', count: 5 })
  })

  it('parses an extend op with an intent, never carrying a targetCount', () => {
    const parsed = queueOpSchema.parse({ op: 'extend', count: 5, intent: { themes: 'keep it up' } })
    if (parsed.op !== 'extend') throw new Error('expected an extend op')
    expect(parsed.intent).not.toHaveProperty('targetCount')
    expect(parsed.intent).toEqual({ themes: 'keep it up', allowExplicit: true, familiarity: 'mix' })
  })

  it('enforces extend count bounds', () => {
    expect(() => queueOpSchema.parse({ op: 'extend', count: 0 })).toThrow()
    expect(() => queueOpSchema.parse({ op: 'extend', count: 21 })).toThrow()
    expect(queueOpSchema.parse({ op: 'extend', count: 1 })).toMatchObject({ count: 1 })
    expect(queueOpSchema.parse({ op: 'extend', count: 20 })).toMatchObject({ count: 20 })
  })

  it('rejects an unknown op name', () => {
    expect(() => queueOpSchema.parse({ op: 'shuffle', position: 0 })).toThrow()
  })

  it('rejects an unknown property on each op variant (strict)', () => {
    expect(() => queueOpSchema.parse({ op: 'remove', position: 0, oops: true })).toThrow()
    expect(() => queueOpSchema.parse({ op: 'move', from: 0, to: 1, oops: true })).toThrow()
    expect(() => queueOpSchema.parse({ op: 'swap', position: 0, oops: true })).toThrow()
    expect(() => queueOpSchema.parse({ op: 'extend', count: 1, oops: true })).toThrow()
  })

  it('does not reject an unknown property nested inside an op intent (intent stays lenient)', () => {
    expect(() =>
      queueOpSchema.parse({ op: 'swap', position: 0, intent: { themes: 'x', mood: 'whatever' } }),
    ).not.toThrow()
  })
})

describe('queueOpsSchema', () => {
  it('accepts between 1 and 20 ops', () => {
    expect(queueOpsSchema.parse([{ op: 'remove', position: 0 }])).toHaveLength(1)
    const twenty = Array.from({ length: 20 }, (_, i) => ({ op: 'remove' as const, position: i }))
    expect(queueOpsSchema.parse(twenty)).toHaveLength(20)
  })

  it('rejects an empty ops array', () => {
    expect(() => queueOpsSchema.parse([])).toThrow()
  })

  it('rejects more than 20 ops', () => {
    const twentyOne = Array.from({ length: 21 }, (_, i) => ({ op: 'remove' as const, position: i }))
    expect(() => queueOpsSchema.parse(twentyOne)).toThrow()
  })
})

// Tiny hand-rolled JSON-Schema checker covering just what DJ_TOOLS' longhand
// schemas use: object/array/string/integer/boolean, required, enum, min/max,
// minLength, minItems/maxItems, oneOf, and additionalProperties:false.
// Unknown-property rejection is enforced ONLY when additionalProperties is
// explicitly false on that object schema (the four op schemas) — everywhere
// else unknown properties are ignored, mirroring zod's default lenient
// stripping on plain (non-strict) objects.
//
// tempoMin<=tempoMax and eraFrom<=eraTo are hardcoded here too: JSON Schema
// has no generic way to express an ordering constraint between sibling
// properties, so this mirrors intentSchema/opIntentSchema's superRefine by
// name, scoped to any object schema whose properties include that pair.
function matchesJsonSchema(schema: any, value: unknown): boolean {
  if (schema.oneOf) {
    return schema.oneOf.some((sub: any) => matchesJsonSchema(sub, value))
  }
  switch (schema.type) {
    case 'object': {
      if (typeof value !== 'object' || value === null || Array.isArray(value)) return false
      const obj = value as Record<string, unknown>
      for (const req of schema.required ?? []) {
        if (!(req in obj)) return false
      }
      for (const [key, val] of Object.entries(obj)) {
        const propSchema = schema.properties?.[key]
        if (!propSchema) {
          if (schema.additionalProperties === false) return false
          continue
        }
        if (!matchesJsonSchema(propSchema, val)) return false
      }
      if (schema.properties?.tempoMin && schema.properties?.tempoMax) {
        const tempoMin = obj.tempoMin as number | undefined
        const tempoMax = obj.tempoMax as number | undefined
        if (tempoMin !== undefined && tempoMax !== undefined && tempoMin > tempoMax) return false
      }
      if (schema.properties?.eraFrom && schema.properties?.eraTo) {
        const eraFrom = obj.eraFrom as number | undefined
        const eraTo = obj.eraTo as number | undefined
        if (eraFrom !== undefined && eraTo !== undefined && eraFrom > eraTo) return false
      }
      return true
    }
    case 'array': {
      if (!Array.isArray(value)) return false
      if (schema.minItems !== undefined && value.length < schema.minItems) return false
      if (schema.maxItems !== undefined && value.length > schema.maxItems) return false
      if (schema.items) return value.every((v) => matchesJsonSchema(schema.items, v))
      return true
    }
    case 'string': {
      if (typeof value !== 'string') return false
      if (schema.minLength !== undefined && value.length < schema.minLength) return false
      if (schema.enum && !schema.enum.includes(value)) return false
      return true
    }
    case 'integer': {
      if (typeof value !== 'number' || !Number.isInteger(value)) return false
      if (schema.minimum !== undefined && value < schema.minimum) return false
      if (schema.maximum !== undefined && value > schema.maximum) return false
      return true
    }
    case 'boolean':
      return typeof value === 'boolean'
    default:
      return false
  }
}

describe('DJ_TOOLS', () => {
  it('defines exactly generate_queue and edit_queue', () => {
    expect(DJ_TOOLS.map((t) => t.name).sort()).toEqual(['edit_queue', 'generate_queue'])
  })

  it('is frozen, along with its intent schema objects', () => {
    expect(Object.isFrozen(DJ_TOOLS)).toBe(true)
    const generateQueue = DJ_TOOLS.find((t) => t.name === 'generate_queue')!
    expect(Object.isFrozen(generateQueue.input_schema)).toBe(true)
    const editQueue = DJ_TOOLS.find((t) => t.name === 'edit_queue')!
    const opsSchema = editQueue.input_schema.properties.ops as { items: { oneOf: unknown[] } }
    const swapIntent = (opsSchema.items.oneOf[2] as { properties: { intent: unknown } }).properties.intent
    expect(Object.isFrozen(swapIntent)).toBe(true)
  })
})

type Row = { label: string; sample: Record<string, unknown> }

// Each row is asserted for AGREEMENT, not a fixed valid/invalid expectation:
// zod's own accept/reject on the row must match the hand-rolled JSON-schema
// checker's accept/reject on the same row. This is what catches the two
// representations drifting apart — a fixed-direction test only proves one
// side accepts/rejects what it's supposed to, not that the other side agrees.
const generateQueueRows: Row[] = [
  { label: 'minimal valid', sample: { themes: 'rain' } },
  {
    label: 'fully specified valid',
    sample: {
      themes: 'upbeat 80s workout',
      tempoMin: 120,
      tempoMax: 160,
      energyArc: 'rise',
      eraFrom: 1980,
      eraTo: 1989,
      allowExplicit: false,
      familiarity: 'adventurous',
      targetCount: 25,
    },
  },
  { label: 'equal tempo window is valid (not inverted)', sample: { themes: 'x', tempoMin: 100, tempoMax: 100 } },
  { label: 'extra unknown top-level field is valid (lenient)', sample: { themes: 'x', mood: 'whatever' } },
  { label: 'missing themes is invalid', sample: {} },
  { label: 'empty themes string is invalid', sample: { themes: '' } },
  { label: 'inverted tempo window is invalid', sample: { themes: 'x', tempoMin: 200, tempoMax: 100 } },
  { label: 'inverted era window is invalid', sample: { themes: 'x', eraFrom: 2000, eraTo: 1990 } },
  { label: 'invalid energyArc enum value', sample: { themes: 'x', energyArc: 'sideways' } },
  { label: 'out-of-range targetCount is invalid', sample: { themes: 'x', targetCount: 61 } },
  { label: 'tempoMin one below the floor is invalid', sample: { themes: 'x', tempoMin: 39 } },
  { label: 'tempoMax one above the ceiling is invalid', sample: { themes: 'x', tempoMax: 261 } },
  { label: 'eraFrom one before the floor is invalid', sample: { themes: 'x', eraFrom: 1899 } },
  { label: 'eraTo one after the ceiling is invalid', sample: { themes: 'x', eraTo: 2101 } },
  { label: 'invalid familiarity enum value', sample: { themes: 'x', familiarity: 'chaotic' } },
]

describe('generate_queue: zod and its longhand JSON schema agree', () => {
  const schema = DJ_TOOLS.find((t) => t.name === 'generate_queue')!.input_schema
  const results = generateQueueRows.map((row) => ({
    label: row.label,
    zod: intentSchema.safeParse(row.sample).success,
    json: matchesJsonSchema(schema, row.sample),
  }))

  it.each(results)('$label', ({ zod, json }) => {
    expect(json).toBe(zod)
  })

  it('the table actually exercises both valid and invalid samples', () => {
    expect(results.some((r) => r.zod)).toBe(true)
    expect(results.some((r) => !r.zod)).toBe(true)
  })
})

type OpsRow = { label: string; sample: { ops: unknown[] } }

const editQueueRows: OpsRow[] = [
  { label: 'single remove is valid', sample: { ops: [{ op: 'remove', position: 2 }] } },
  {
    label: 'move plus swap-with-intent is valid',
    sample: {
      ops: [
        { op: 'move', from: 0, to: 3 },
        { op: 'swap', position: 1, intent: { themes: 'more chill' } },
      ],
    },
  },
  {
    label: 'extend-with-intent is valid (no targetCount on an op intent)',
    sample: { ops: [{ op: 'extend', count: 5, intent: { themes: 'keep the energy up' } }] },
  },
  {
    label: 'extra unknown field inside an op intent is valid (intent stays lenient)',
    sample: { ops: [{ op: 'swap', position: 0, intent: { themes: 'x', mood: 'whatever' } }] },
  },
  { label: 'unknown op name is invalid', sample: { ops: [{ op: 'shuffle', position: 0 }] } },
  {
    label: 'extra unknown field on the op itself is invalid (ops are strict)',
    sample: { ops: [{ op: 'remove', position: 0, oops: true }] },
  },
  { label: 'extend count out of range is invalid', sample: { ops: [{ op: 'extend', count: 21 }] } },
  { label: 'empty ops array is invalid', sample: { ops: [] } },
  {
    label: '21 ops exceeds the bound and is invalid',
    sample: { ops: Array.from({ length: 21 }, (_, i) => ({ op: 'remove', position: i })) },
  },
  {
    label: 'swap intent with an inverted tempo window is invalid',
    sample: { ops: [{ op: 'swap', position: 0, intent: { themes: 'x', tempoMin: 200, tempoMax: 100 } }] },
  },
  {
    label: 'remove op with position -1 is invalid',
    sample: { ops: [{ op: 'remove', position: -1 }] },
  },
]

describe('edit_queue: zod and its longhand JSON schema agree', () => {
  const schema = DJ_TOOLS.find((t) => t.name === 'edit_queue')!.input_schema
  const results = editQueueRows.map((row) => ({
    label: row.label,
    zod: queueOpsSchema.safeParse(row.sample.ops).success,
    json: matchesJsonSchema(schema, row.sample),
  }))

  it.each(results)('$label', ({ zod, json }) => {
    expect(json).toBe(zod)
  })

  it('the table actually exercises both valid and invalid samples', () => {
    expect(results.some((r) => r.zod)).toBe(true)
    expect(results.some((r) => !r.zod)).toBe(true)
  })
})
