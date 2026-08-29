import { z } from 'zod'
import type { LlmToolDef } from './llm'

export const intentSchema = z.object({
  themes: z.string().min(1),
  tempoMin: z.number().int().min(40).max(260).optional(),
  tempoMax: z.number().int().min(40).max(260).optional(),
  energyArc: z.enum(['rise', 'fall', 'arc', 'steady']).optional(),
  eraFrom: z.number().int().min(1900).max(2100).optional(),
  eraTo: z.number().int().min(1900).max(2100).optional(),
  allowExplicit: z.boolean().default(true),
  familiarity: z.enum(['comfort', 'mix', 'adventurous']).default('mix'),
  targetCount: z.number().int().min(3).max(60).default(15),
})
export type Intent = z.infer<typeof intentSchema>

const removeOp = z.object({ op: z.literal('remove'), position: z.number().int().min(0) })
const moveOp = z.object({
  op: z.literal('move'),
  from: z.number().int().min(0),
  to: z.number().int().min(0),
})
const swapOp = z.object({
  op: z.literal('swap'),
  position: z.number().int().min(0),
  intent: intentSchema.optional(),
})
const extendOp = z.object({
  op: z.literal('extend'),
  count: z.number().int().min(1).max(20),
  intent: intentSchema.optional(),
})

export const queueOpSchema = z.discriminatedUnion('op', [removeOp, moveOp, swapOp, extendOp])
export type QueueOp = z.infer<typeof queueOpSchema>

export const queueOpsSchema = z.array(queueOpSchema).min(1).max(20)

// Longhand JSON Schema for the intent fields, shared verbatim between
// generate_queue's top-level input and edit_queue's swap/extend `intent`
// field, so the two can't drift from each other — a drift test in
// contracts.test.ts also checks this against intentSchema itself.
const intentProperties: Record<string, unknown> = {
  themes: {
    type: 'string',
    minLength: 1,
    description:
      'Rich free-text description of mood, meaning, and vibe — used for semantic matching against lyric meaning, not treated as a keyword list.',
  },
  tempoMin: {
    type: 'integer',
    minimum: 40,
    maximum: 260,
    description: 'Lower BPM bound, if the listener implied a tempo floor.',
  },
  tempoMax: {
    type: 'integer',
    minimum: 40,
    maximum: 260,
    description: 'Upper BPM bound, if the listener implied a tempo ceiling.',
  },
  energyArc: {
    type: 'string',
    enum: ['rise', 'fall', 'arc', 'steady'],
    description:
      'Shape of energy across the queue: rise (build up), fall (wind down), arc (build then release), steady (flat).',
  },
  eraFrom: { type: 'integer', minimum: 1900, maximum: 2100, description: 'Earliest release year to include.' },
  eraTo: { type: 'integer', minimum: 1900, maximum: 2100, description: 'Latest release year to include.' },
  allowExplicit: {
    type: 'boolean',
    description: 'Whether explicit tracks may be included. Defaults to true.',
  },
  familiarity: {
    type: 'string',
    enum: ['comfort', 'mix', 'adventurous'],
    description:
      'How much to favor the listener\'s most-played tracks vs. deeper cuts. Defaults to "mix".',
  },
  targetCount: {
    type: 'integer',
    minimum: 3,
    maximum: 60,
    description:
      'Number of tracks to queue. Convert any requested duration to a count at ~3.5 minutes per track (e.g. "an hour" is about 17 tracks). Defaults to 15.',
  },
}

const intentJsonSchema = {
  type: 'object' as const,
  properties: intentProperties,
  required: ['themes'],
}

export const DJ_TOOLS: LlmToolDef[] = [
  {
    name: 'generate_queue',
    description:
      "Create a fresh queue for this session from the listener's request. Replaces any existing queue. Convert requested durations to a track count (~3.5 min per track). themes: a rich free-text description of mood, meaning and vibe used for semantic matching against lyric meaning.",
    input_schema: intentJsonSchema,
  },
  {
    name: 'edit_queue',
    description:
      "Modify the current queue in place. ops run in order. Use swap/extend with an intent when the listener asked for a different flavour; omit intent to stay on the session's current vibe.",
    input_schema: {
      type: 'object',
      properties: {
        ops: {
          type: 'array',
          minItems: 1,
          maxItems: 20,
          description:
            'Queue edit operations, applied in order: remove(position), move(from,to), swap(position, intent?), extend(count, intent?).',
          items: {
            oneOf: [
              {
                type: 'object',
                properties: {
                  op: { type: 'string', enum: ['remove'] },
                  position: { type: 'integer', minimum: 0, description: 'Zero-based queue position to remove.' },
                },
                required: ['op', 'position'],
              },
              {
                type: 'object',
                properties: {
                  op: { type: 'string', enum: ['move'] },
                  from: { type: 'integer', minimum: 0, description: 'Zero-based queue position to move from.' },
                  to: { type: 'integer', minimum: 0, description: 'Zero-based queue position to move to.' },
                },
                required: ['op', 'from', 'to'],
              },
              {
                type: 'object',
                properties: {
                  op: { type: 'string', enum: ['swap'] },
                  position: { type: 'integer', minimum: 0, description: 'Zero-based queue position to replace.' },
                  intent: intentJsonSchema,
                },
                required: ['op', 'position'],
              },
              {
                type: 'object',
                properties: {
                  op: { type: 'string', enum: ['extend'] },
                  count: {
                    type: 'integer',
                    minimum: 1,
                    maximum: 20,
                    description: 'Number of additional tracks to append.',
                  },
                  intent: intentJsonSchema,
                },
                required: ['op', 'count'],
              },
            ],
          },
        },
      },
      required: ['ops'],
    },
  },
]
