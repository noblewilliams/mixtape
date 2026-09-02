import { z } from 'zod'
import { SPOTIFY_ID_PATTERN } from '../listening/contracts'

export const ARTIST_SEEDS_MAX = 50
// Matches the user_artist_seeds name check (1..500 characters).
export const ARTIST_SEED_NAME_MAX = 500
export const SEED_TRACKS_MAX = 200
export const INTERVIEW_ARTISTS_MAX = 20
export const INTERVIEW_ARTIST_MAX = 200
export const INTERVIEW_ANSWER_MAX = 300

// Postgres rejects a NUL byte in text; everything else is stored as typed and
// sanitized where it is rendered (dj/sanitize.ts), never on the way in.
const noNul = <T extends z.ZodString>(schema: T) => schema.refine((value) => !value.includes('\0'))
const trimmedName = (max: number) => noNul(z.string().trim().min(1).max(max))
const answer = noNul(z.string().trim().max(INTERVIEW_ANSWER_MAX))

export const surfaceSchema = z.enum(['ios', 'web'])
export type Surface = z.infer<typeof surfaceSchema>

export const putArtistSeedsSchema = z.object({
  names: z.array(trimmedName(ARTIST_SEED_NAME_MAX)).max(ARTIST_SEEDS_MAX),
}).strict()

export const postSeedTracksSchema = z.object({
  spotifyIds: z.array(z.string().regex(SPOTIFY_ID_PATTERN)).min(1).max(SEED_TRACKS_MAX),
}).strict()

export const interviewSchema = z.object({
  surface: surfaceSchema,
  neverSkip: z.array(trimmedName(INTERVIEW_ARTIST_MAX)).max(INTERVIEW_ARTISTS_MAX),
  playsMost: answer,
  listensWhen: answer,
  neverWants: answer,
  era: answer,
}).strict()
export type InterviewAnswers = z.infer<typeof interviewSchema>

// Funnel order (spec 2026-09-01 → Funnel); the schema check on
// funnel_events.type lists the same values.
export const FUNNEL_EVENT_TYPES = [
  'chose_spotify',
  'marked_requested',
  'interview_completed',
  'file_inspected',
  'import_completed',
  'first_personal_mix',
  'first_output',
] as const
export type FunnelEventType = (typeof FUNNEL_EVENT_TYPES)[number]

export const funnelEventSchema = z.object({
  type: z.enum(FUNNEL_EVENT_TYPES),
  surface: surfaceSchema,
}).strict()
