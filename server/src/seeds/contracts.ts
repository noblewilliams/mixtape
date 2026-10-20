import { z } from 'zod'
import { safeString } from '../contracts/safe-string'
import { SPOTIFY_ID_PATTERN } from '../listening/contracts'

export const ARTIST_SEEDS_MAX = 50
// Matches the user_artist_seeds name check (1..500 characters).
export const ARTIST_SEED_NAME_MAX = 500
export const SEED_TRACKS_MAX = 200
export const INTERVIEW_ARTISTS_MAX = 20
export const INTERVIEW_ARTIST_MAX = 200
export const INTERVIEW_ANSWER_MAX = 300

// Stored as typed and sanitized where it is rendered (dj/sanitize.ts), never
// on the way in; safeString refuses only what Postgres cannot hold as sent.
const trimmedName = (max: number) => safeString(z.string().trim().min(1).max(max))
const answer = safeString(z.string().trim().max(INTERVIEW_ANSWER_MAX))

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

// Spotify-listener funnel, in order (spec 2026-09-01 → Funnel). The funnel
// report walks this list step to step.
export const SPOTIFY_FUNNEL_EVENT_TYPES = [
  'chose_spotify',
  'marked_requested',
  'interview_completed',
  'file_inspected',
  'import_completed',
  'first_personal_mix',
  'first_output',
] as const
// First-run funnel, one-time per anonymous user (spec 2026-10-20 → Clients,
// Funnel events). Not a strict chain: the make-mix and add-music paths branch.
export const FIRST_RUN_FUNNEL_EVENT_TYPES = [
  'first_run_opened',
  'chose_make_mix',
  'chose_add_music',
  'chose_service',
  'chose_method',
  'sync_done',
  'first_mix_made',
  'first_mix_refused',
  'keep_sheet_shown',
  'keep_sheet_signed_in',
  'keep_sheet_dismissed',
  'cap_reached',
  'account_linked_new',
  'account_linked_existing',
] as const
// Every accepted type; the schema check on funnel_events.type lists the same
// values in the same order.
export const FUNNEL_EVENT_TYPES = [...SPOTIFY_FUNNEL_EVENT_TYPES, ...FIRST_RUN_FUNNEL_EVENT_TYPES] as const
export type FunnelEventType = (typeof FUNNEL_EVENT_TYPES)[number]

export const funnelEventSchema = z.object({
  type: z.enum(FUNNEL_EVENT_TYPES),
  surface: surfaceSchema,
}).strict()
