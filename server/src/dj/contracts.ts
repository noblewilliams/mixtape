import { z } from 'zod'
import type { LlmToolDef } from './llm'

const intentBase = z.object({
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

// Shared by intentSchema and opIntentSchema: an inverted tempo/era window
// (e.g. tempoMin > tempoMax) is a nonsensical request, not just an
// out-of-range field, so it's checked cross-field rather than per-property.
function checkWindowOrdering(
  data: { tempoMin?: number; tempoMax?: number; eraFrom?: number; eraTo?: number },
  ctx: z.RefinementCtx,
) {
  if (data.tempoMin !== undefined && data.tempoMax !== undefined && data.tempoMin > data.tempoMax) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'tempoMin must be <= tempoMax', path: ['tempoMin'] })
  }
  if (data.eraFrom !== undefined && data.eraTo !== undefined && data.eraFrom > data.eraTo) {
    ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'eraFrom must be <= eraTo', path: ['eraFrom'] })
  }
}

export const intentSchema = intentBase.superRefine(checkWindowOrdering)
export type Intent = z.infer<typeof intentSchema>

// Used only for swap/extend's replacement intent: targetCount doesn't apply
// there (swap replaces exactly one track, extend uses its own `count`) — a
// full intentSchema would let zod inject targetCount:15 onto a 1-track swap,
// and the agent loop (Task 7) would generate 15 replacements instead of 1.
export const opIntentSchema = intentBase.omit({ targetCount: true }).superRefine(checkWindowOrdering)
export type OpIntent = z.infer<typeof opIntentSchema>

const removeOp = z.object({ op: z.literal('remove'), position: z.number().int().min(0) }).strict()
const moveOp = z
  .object({
    op: z.literal('move'),
    from: z.number().int().min(0),
    to: z.number().int().min(0),
  })
  .strict()
const swapOp = z
  .object({
    op: z.literal('swap'),
    position: z.number().int().min(0),
    intent: opIntentSchema.optional(),
  })
  .strict()
const extendOp = z
  .object({
    op: z.literal('extend'),
    count: z.number().int().min(1).max(20),
    intent: opIntentSchema.optional(),
  })
  .strict()

export const queueOpSchema = z.discriminatedUnion('op', [removeOp, moveOp, swapOp, extendOp])
export type QueueOp = z.infer<typeof queueOpSchema>

export const queueOpsSchema = z.array(queueOpSchema).min(1).max(20)

// remember_preference's tool input — validated raw (pre-trim) length, mirroring
// createSessionSchema/messageSchema's own min/max-on-the-raw-string style
// (routes/sessions.ts). The loop trims before storing, but the bound itself
// applies to what the model actually sent.
export const rememberPreferenceInputSchema = z.object({ note: z.string().min(1).max(200) })
export type RememberPreferenceInput = z.infer<typeof rememberPreferenceInputSchema>

// Longhand JSON Schema for the intent fields, shared verbatim between
// generate_queue's top-level input and edit_queue's swap/extend `intent`
// field, so the two can't drift from each other — an agreement test in
// contracts.test.ts checks both against their zod counterparts.
const intentPropertiesBase: Record<string, unknown> = {
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
    description:
      'Preferred BPM range floor, if the listener implied a tempo. Must be <= tempoMax when both are set. Given alone (no tempoMax), this expresses a direction ("upbeat"), not a cutoff — unknown-BPM tracks and tracks just below it may still appear, ranked lower.',
  },
  tempoMax: {
    type: 'integer',
    minimum: 40,
    maximum: 260,
    description:
      'Preferred BPM range ceiling, if the listener implied a tempo. Must be >= tempoMin when both are set. Given alone (no tempoMin), this expresses a direction ("chill"), not a cutoff — unknown-BPM tracks and tracks just above it may still appear, ranked lower.',
  },
  energyArc: {
    type: 'string',
    enum: ['rise', 'fall', 'arc', 'steady'],
    description:
      'Shape of energy across the queue: rise (build up), fall (wind down), arc (build then release), steady (flat).',
  },
  eraFrom: {
    type: 'integer',
    minimum: 1900,
    maximum: 2100,
    description: 'Earliest release year to include. Must be <= eraTo when both are set.',
  },
  eraTo: {
    type: 'integer',
    minimum: 1900,
    maximum: 2100,
    description: 'Latest release year to include. Must be >= eraFrom when both are set.',
  },
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
}

const targetCountProperty = {
  type: 'integer' as const,
  minimum: 3,
  maximum: 60,
  description:
    'Number of tracks to queue. Convert any requested duration to a count at ~3.5 minutes per track (e.g. "an hour" is about 17 tracks). Defaults to 15.',
}

// generate_queue's full intent, including targetCount.
const intentJsonSchema = Object.freeze({
  type: 'object' as const,
  properties: { ...intentPropertiesBase, targetCount: targetCountProperty },
  required: ['themes'],
})

// swap/extend's replacement intent — no targetCount, mirroring opIntentSchema.
const opIntentJsonSchema = Object.freeze({
  type: 'object' as const,
  properties: intentPropertiesBase,
  required: ['themes'],
})

// remember_preference's longhand JSON Schema — mirrors rememberPreferenceInputSchema
// (an agreement test in contracts.test.ts checks both against each other, same as
// the intent schemas above).
const rememberPreferenceJsonSchema = Object.freeze({
  type: 'object' as const,
  properties: {
    note: {
      type: 'string',
      minLength: 1,
      maxLength: 200,
      description:
        "A short, durable listening preference in the listener's own words — a lasting like/dislike, a " +
        'favorite or avoided artist/genre, or a hard rule ("never play explicit", "always include a Wizkid ' +
        'track on party mixes"). Not a one-off request for just this session.',
    },
  },
  required: ['note'],
})

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
      "Modify the current queue in place. ops run in order, and each op sees the queue exactly as the PRECEDING ops left it — positions are working-relative, not fixed to the queue you started with. A remove shifts every later track down one position; if you want to remove several tracks, list them in DESCENDING position order (e.g. remove 5 then remove 2, never the reverse) so earlier removals don't shift the positions you listed later. Use swap/extend with an intent when the listener asked for a different flavour; omit intent to stay on the session's current vibe.",
    input_schema: {
      type: 'object',
      properties: {
        ops: {
          type: 'array',
          minItems: 1,
          maxItems: 20,
          description:
            'Queue edit operations, applied in order: remove(position), move(from,to), swap(position, intent?), extend(count, intent?). ' +
              'Positions are working-relative — each op sees the list as the ones before it left it. List multiple removes in descending position order. ' +
              'Positions are 0-based indices into the current queue listing shown in context; listeners speak 1-based ("track 5" = position 4) — translate carefully.',
          items: {
            // If live smoke shows malformed ops from the model, the known fix is
            // flattening to one object (op enum + all fields optional) with zod
            // enforcing legal combos — see Task 3 review.
            oneOf: [
              {
                type: 'object',
                properties: {
                  op: { type: 'string', enum: ['remove'] },
                  position: { type: 'integer', minimum: 0, description: 'Zero-based queue position to remove.' },
                },
                required: ['op', 'position'],
                additionalProperties: false,
              },
              {
                type: 'object',
                properties: {
                  op: { type: 'string', enum: ['move'] },
                  from: { type: 'integer', minimum: 0, description: 'Zero-based queue position to move from.' },
                  to: { type: 'integer', minimum: 0, description: 'Zero-based queue position to move to.' },
                },
                required: ['op', 'from', 'to'],
                additionalProperties: false,
              },
              {
                type: 'object',
                properties: {
                  op: { type: 'string', enum: ['swap'] },
                  position: { type: 'integer', minimum: 0, description: 'Zero-based queue position to replace.' },
                  intent: opIntentJsonSchema,
                },
                required: ['op', 'position'],
                additionalProperties: false,
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
                  intent: opIntentJsonSchema,
                },
                required: ['op', 'count'],
                additionalProperties: false,
              },
            ],
          },
        },
      },
      required: ['ops'],
    },
  },
  {
    name: 'remember_preference',
    description:
      "Save a durable listening preference the listener EXPLICITLY STATES as lasting — not a one-off request " +
      "for this session alone. Use it for things like a favorite or avoided artist/genre, or a hard rule " +
      '("never play explicit", "always include a Wizkid track on party mixes"). Skip it for ordinary in-the-moment ' +
      'requests ("play something upbeat right now") — those go through generate_queue/edit_queue instead, not ' +
      'this tool.',
    input_schema: rememberPreferenceJsonSchema,
  },
]

Object.freeze(DJ_TOOLS)
