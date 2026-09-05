import { z } from 'zod'
import type { LlmToolDef } from '../dj/llm'

const anchors = {
  afterEntryKey: z.string().uuid().optional(),
  beforeEntryKey: z.string().uuid().optional(),
}

const addOperationSchema = z.object({
  type: z.literal('add'),
  trackId: z.string().uuid(),
  placementIntent: z.literal('best_fit').optional(),
  ...anchors,
}).strict()
const removeOperationSchema = z.object({
  type: z.literal('remove'),
  entryKey: z.string().uuid(),
}).strict()
const moveOperationSchema = z.object({
  type: z.literal('move'),
  entryKey: z.string().uuid(),
  ...anchors,
}).strict()
const replaceOperationSchema = z.object({
  type: z.literal('replace'),
  entryKey: z.string().uuid(),
  trackId: z.string().uuid(),
  placementIntent: z.literal('best_fit').optional(),
}).strict()

export const playlistEditToolOperationSchema = z.discriminatedUnion('type', [
  addOperationSchema,
  removeOperationSchema,
  moveOperationSchema,
  replaceOperationSchema,
])
export type PlaylistEditToolOperation = z.infer<typeof playlistEditToolOperationSchema>

export const searchCatalogInputSchema = z.object({
  query: z.string().min(1).max(120),
  artist: z.string().min(1).max(200).optional(),
  album: z.string().min(1).max(200).optional(),
  limit: z.number().int().min(1).max(25).default(10),
}).strict()

export const editPlaylistDraftInputSchema = z.object({
  operations: z.array(playlistEditToolOperationSchema).min(1).max(20),
  expectedVersion: z.number().int().min(0).max(2147483646),
}).strict()

export const playlistEditMessageSchema = z.object({
  content: z.string().trim().min(1).max(2000),
  expectedVersion: z.number().int().min(0).max(2147483646),
}).strict()

const anchorsJson = {
  afterEntryKey: { type: 'string', format: 'uuid', description: 'Occurrence key immediately before the insertion.' },
  beforeEntryKey: { type: 'string', format: 'uuid', description: 'Occurrence key immediately after the insertion.' },
}

export const PLAYLIST_EDIT_TOOLS: LlmToolDef[] = [
  {
    name: 'search_catalog',
    description: 'Search the public Apple Music song catalog. Use this before adding or replacing with a song whose internal trackId is not already in playlist context. Artist and album constraints are exact filters, not hints. Results already present in the draft are excluded.',
    input_schema: {
      type: 'object',
      properties: {
        query: { type: 'string', minLength: 1, maxLength: 120 },
        artist: { type: 'string', minLength: 1, maxLength: 200 },
        album: { type: 'string', minLength: 1, maxLength: 200 },
        limit: { type: 'integer', minimum: 1, maximum: 25 },
      },
      required: ['query'],
      additionalProperties: false,
    },
  },
  {
    name: 'edit_playlist_draft',
    description: 'Apply the smallest requested change to Mixtape’s private draft. This never writes to Apple Music. Entry keys identify exact occurrences. For "where it fits best", set placementIntent to best_fit and omit anchors. For "a couple", submit exactly two add operations.',
    input_schema: {
      type: 'object',
      properties: {
        expectedVersion: { type: 'integer', minimum: 0, maximum: 2147483646 },
        operations: {
          type: 'array',
          minItems: 1,
          maxItems: 20,
          items: {
            oneOf: [
              {
                type: 'object',
                properties: {
                  type: { type: 'string', enum: ['add'] },
                  trackId: { type: 'string', format: 'uuid' },
                  placementIntent: { type: 'string', enum: ['best_fit'] },
                  ...anchorsJson,
                },
                required: ['type', 'trackId'],
                additionalProperties: false,
              },
              {
                type: 'object',
                properties: { type: { type: 'string', enum: ['remove'] }, entryKey: { type: 'string', format: 'uuid' } },
                required: ['type', 'entryKey'],
                additionalProperties: false,
              },
              {
                type: 'object',
                properties: { type: { type: 'string', enum: ['move'] }, entryKey: { type: 'string', format: 'uuid' }, ...anchorsJson },
                required: ['type', 'entryKey'],
                additionalProperties: false,
              },
              {
                type: 'object',
                properties: {
                  type: { type: 'string', enum: ['replace'] },
                  entryKey: { type: 'string', format: 'uuid' },
                  trackId: { type: 'string', format: 'uuid' },
                  placementIntent: { type: 'string', enum: ['best_fit'] },
                },
                required: ['type', 'entryKey', 'trackId'],
                additionalProperties: false,
              },
            ],
          },
        },
      },
      required: ['operations', 'expectedVersion'],
      additionalProperties: false,
    },
  },
]
