import { z } from 'zod'
import type { LlmToolDef } from '../dj/llm'
import { rememberPreferenceJsonSchema, renameSessionJsonSchema } from '../dj/contracts'

// Album picks (spec 2026-10-20 → The conversation). The model labels each
// record; Apple's isSingle/isCompilation override it after verification.
export const ALBUM_TYPES = ['album', 'ep', 'single', 'live', 'compilation', 'soundtrack', 'mixtape'] as const
export type AlbumType = (typeof ALBUM_TYPES)[number]

export const FAMILIARITIES = ['comfort', 'mix', 'adventurous'] as const
export type AlbumFamiliarity = (typeof FAMILIARITIES)[number]

const candidateSchema = z
  .object({
    artist: z.string().min(1).max(200),
    title: z.string().min(1).max(200),
    year: z.number().int().min(1900).max(2100).optional(),
    type: z.enum(ALBUM_TYPES),
    why: z.string().min(1).max(300),
    // True when the model took this record from the "On their shelf" listing
    // in context. The search budget is simply candidates.length.
    fromShelf: z.boolean().optional(),
  })
  .strict()

export const recommendAlbumInputSchema = z
  .object({
    familiarity: z.enum(FAMILIARITIES).default('mix'),
    candidates: z.array(candidateSchema).min(1).max(5),
  })
  .strict()
export type RecommendAlbumInput = z.infer<typeof recommendAlbumInputSchema>
export type AlbumCandidateInput = RecommendAlbumInput['candidates'][number]

// The JSON Schema twin of recommendAlbumInputSchema; test/albums/contracts.test.ts
// checks the two agree on required keys, enums and bounds.
export const recommendAlbumJsonSchema = Object.freeze({
  type: 'object' as const,
  properties: {
    familiarity: {
      type: 'string',
      enum: [...FAMILIARITIES],
      description:
        'comfort: choose only from the "On their shelf" listing. mix (default): shelf or new records. ' +
        'adventurous: prefer records the listener does not own.',
    },
    candidates: {
      type: 'array',
      minItems: 1,
      maxItems: 5,
      description: 'One to five real records for the brief, best first.',
      items: {
        type: 'object',
        properties: {
          artist: { type: 'string', minLength: 1, maxLength: 200, description: 'The credited album artist.' },
          title: { type: 'string', minLength: 1, maxLength: 200, description: 'The album title as released.' },
          year: { type: 'integer', minimum: 1900, maximum: 2100, description: 'Approximate release year.' },
          type: { type: 'string', enum: [...ALBUM_TYPES], description: 'The kind of record you believe it is.' },
          why: { type: 'string', minLength: 1, maxLength: 300, description: 'One line on why this one, now.' },
          fromShelf: { type: 'boolean', description: 'True when taken from the "On their shelf" listing.' },
        },
        required: ['artist', 'title', 'type', 'why'],
        additionalProperties: false,
      },
    },
  },
  required: ['candidates'],
  additionalProperties: false,
})

const albumTools: LlmToolDef[] = [
  {
    name: 'recommend_album',
    description:
      'Name one to five real albums for the brief. The server checks each against Apple Music, drops any it ' +
      'cannot find, and ranks the rest; the result says which album was chosen, the runners-up, how many were ' +
      'dropped, and whether the pick is new to the listener. Describe the result in words from the tool result ' +
      'only. Never mention or show an album the result did not confirm. Call it at most once per turn.',
    input_schema: recommendAlbumJsonSchema,
  },
  // Same names and schemas as the DJ's tools, so the DJ's executors apply.
  {
    name: 'remember_preference',
    description:
      'Save a durable listening preference the listener explicitly states as lasting, such as a favorite or ' +
      'avoided artist or genre, or a hard rule. Never for a one-off request for this moment.',
    input_schema: rememberPreferenceJsonSchema,
  },
  {
    name: 'rename_session',
    description:
      'Rename this session when the listener explicitly asks for a new name. Never on your own initiative.',
    input_schema: renameSessionJsonSchema,
  },
]
for (const tool of albumTools) Object.freeze(tool)
export const ALBUM_TOOLS: LlmToolDef[] = Object.freeze(albumTools) as LlmToolDef[]
