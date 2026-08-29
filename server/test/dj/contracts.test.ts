import { describe, it, expect } from 'vitest'
import { intentSchema, queueOpSchema, queueOpsSchema, DJ_TOOLS } from '../../src/dj/contracts'

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

  it('parses a swap op with an intent, applying intent defaults', () => {
    const parsed = queueOpSchema.parse({ op: 'swap', position: 1, intent: { themes: 'more chill' } })
    expect(parsed).toMatchObject({
      op: 'swap',
      position: 1,
      intent: { themes: 'more chill', familiarity: 'mix', targetCount: 15 },
    })
  })

  it('parses an extend op without an intent', () => {
    expect(queueOpSchema.parse({ op: 'extend', count: 5 })).toEqual({ op: 'extend', count: 5 })
  })

  it('parses an extend op with an intent', () => {
    const parsed = queueOpSchema.parse({ op: 'extend', count: 5, intent: { themes: 'keep it up' } })
    expect(parsed).toMatchObject({ op: 'extend', count: 5, intent: { themes: 'keep it up' } })
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
// minLength, minItems/maxItems, and oneOf. Exists only so this drift test can
// validate a sample against the LLM-facing schema without a new dependency.
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
        if (!propSchema) return false
        if (!matchesJsonSchema(propSchema, val)) return false
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

describe('DJ_TOOLS drift', () => {
  const generateQueue = DJ_TOOLS.find((t) => t.name === 'generate_queue')!
  const editQueue = DJ_TOOLS.find((t) => t.name === 'edit_queue')!

  it('defines exactly generate_queue and edit_queue', () => {
    expect(DJ_TOOLS.map((t) => t.name).sort()).toEqual(['edit_queue', 'generate_queue'])
  })

  const generateQueueSamples = [
    { themes: 'rainy night drive' },
    {
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
    { themes: 'quiet Sunday morning', familiarity: 'comfort', targetCount: 8 },
  ]

  it('generate_queue samples parse under zod and validate under its longhand JSON schema', () => {
    expect(generateQueueSamples.length).toBeGreaterThanOrEqual(2)
    for (const sample of generateQueueSamples) {
      expect(() => intentSchema.parse(sample)).not.toThrow()
      expect(matchesJsonSchema(generateQueue.input_schema, sample)).toBe(true)
    }
  })

  const editQueueSamples = [
    { ops: [{ op: 'remove', position: 2 }] },
    {
      ops: [
        { op: 'move', from: 0, to: 3 },
        { op: 'swap', position: 1, intent: { themes: 'more chill' } },
      ],
    },
    { ops: [{ op: 'extend', count: 5, intent: { themes: 'keep the energy up', targetCount: 5 } }] },
  ]

  it('edit_queue samples parse under zod and validate under its longhand JSON schema', () => {
    expect(editQueueSamples.length).toBeGreaterThanOrEqual(2)
    for (const sample of editQueueSamples) {
      expect(() => queueOpsSchema.parse(sample.ops)).not.toThrow()
      expect(matchesJsonSchema(editQueue.input_schema, sample)).toBe(true)
    }
  })
})
