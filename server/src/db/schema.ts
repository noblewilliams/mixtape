import { sql } from 'drizzle-orm'
import {
  pgTable,
  uuid,
  text,
  timestamp,
  uniqueIndex,
  index,
  integer,
  bigserial,
  boolean,
  primaryKey,
  doublePrecision,
  vector,
  check,
} from 'drizzle-orm/pg-core'
import { user } from './auth-schema'

export * from './auth-schema'

export const tracks = pgTable(
  'tracks',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    appleId: text('apple_id'),
    isrc: text('isrc'),
    title: text('title').notNull(),
    artist: text('artist').notNull(),
    album: text('album'),
    genre: text('genre'),
    durationMs: integer('duration_ms'),
    releaseYear: integer('release_year'),
    explicit: boolean('explicit'),
    artworkUrlTemplate: text('artwork_url_template'),
    artworkWidth: integer('artwork_width'),
    artworkHeight: integer('artwork_height'),
    artworkBgColor: text('artwork_bg_color'),
    artworkFetchedAt: timestamp('artwork_fetched_at', { withTimezone: true }),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    uniqueIndex('tracks_apple_id_idx').on(t.appleId).where(sql`${t.appleId} IS NOT NULL`),
    index('tracks_isrc_idx').on(t.isrc),
    check(
      'tracks_artwork_bg_color_check',
      sql`${t.artworkBgColor} IS NULL OR ${t.artworkBgColor} ~ '^[0-9a-f]{6}$'`,
    ),
    check(
      'tracks_artwork_width_positive_check',
      sql`${t.artworkWidth} IS NULL OR ${t.artworkWidth} > 0`,
    ),
    check(
      'tracks_artwork_height_positive_check',
      sql`${t.artworkHeight} IS NULL OR ${t.artworkHeight} > 0`,
    ),
  ],
)

export const userTracks = pgTable(
  'user_tracks',
  {
    userId: text('user_id')
      .notNull()
      .references(() => user.id, { onDelete: 'cascade' }),
    trackId: uuid('track_id')
      .notNull()
      .references(() => tracks.id, { onDelete: 'cascade' }),
    playCount: integer('play_count').notNull().default(0),
    lastPlayedAt: timestamp('last_played_at', { withTimezone: true }),
    dateAdded: timestamp('date_added', { withTimezone: true }),
    inLibrary: boolean('in_library').notNull().default(true),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (t) => [
    primaryKey({ columns: [t.userId, t.trackId] }),
    index('user_tracks_track_idx').on(t.trackId),
  ],
)

export const trackFeatures = pgTable('track_features', {
  trackId: uuid('track_id')
    .primaryKey()
    .references(() => tracks.id, { onDelete: 'cascade' }),
  tempo: doublePrecision('tempo'),
  key: integer('key'),
  mode: integer('mode'),
  energy: doublePrecision('energy'),
  danceability: doublePrecision('danceability'),
  valence: doublePrecision('valence'),
  acousticness: doublePrecision('acousticness'),
  instrumentalness: doublePrecision('instrumentalness'),
  liveness: doublePrecision('liveness'),
  speechiness: doublePrecision('speechiness'),
  loudness: doublePrecision('loudness'),
  source: text('source').notNull(),
  fetchedAt: timestamp('fetched_at', { withTimezone: true }).notNull().defaultNow(),
})

// Lyric MEANING only — never lyric text (docs/decisions.md → lyrics stance).
export const trackMeanings = pgTable(
  'track_meanings',
  {
    trackId: uuid('track_id')
      .primaryKey()
      .references(() => tracks.id, { onDelete: 'cascade' }),
    embedding: vector('embedding', { dimensions: 1024 }), // bge-m3 width — see EMBEDDING_DIMENSIONS in enrich/embedder.ts
    lyricsSource: text('lyrics_source'),
    instrumental: boolean('instrumental').notNull().default(false),
    embeddedAt: timestamp('embedded_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    index('track_meanings_embedding_hnsw_idx').using('hnsw', t.embedding.op('vector_cosine_ops')),
  ],
)

export const enrichmentFailures = pgTable(
  'enrichment_failures',
  {
    trackId: uuid('track_id')
      .notNull()
      .references(() => tracks.id, { onDelete: 'cascade' }),
    stage: text('stage', { enum: ['itunes', 'features', 'meaning'] }).notNull(),
    error: text('error').notNull(),
    attempts: integer('attempts').notNull().default(1),
    lastAt: timestamp('last_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [primaryKey({ columns: [t.trackId, t.stage] })],
)

export const trackArtworkStatus = pgTable(
  'track_artwork_status',
  {
    trackId: uuid('track_id')
      .primaryKey()
      .references(() => tracks.id, { onDelete: 'cascade' }),
    attempts: integer('attempts').notNull().default(1),
    lastCategory: text('last_category').notNull(),
    nextAttemptAt: timestamp('next_attempt_at', { withTimezone: true }).notNull(),
    updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    check('track_artwork_status_attempts_positive_check', sql`${t.attempts} > 0`),
    check(
      'track_artwork_status_category_check',
      sql`${t.lastCategory} IN ('no_match', 'rate_limit', 'upstream', 'timeout', 'malformed', 'authorization', 'network', 'internal')`,
    ),
    index('track_artwork_status_retry_idx').on(t.nextAttemptAt),
  ],
)

export const djSessions = pgTable(
  'dj_sessions',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    userId: text('user_id')
      .notNull()
      .references(() => user.id, { onDelete: 'cascade' }),
    title: text('title').notNull(),
    status: text('status', { enum: ['active', 'archived'] }).notNull().default('active'),
    queueVersion: integer('queue_version').notNull().default(0),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (t) => [index('dj_sessions_user_idx').on(t.userId, t.createdAt)],
)

export const djMessages = pgTable(
  'dj_messages',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    sessionId: uuid('session_id')
      .notNull()
      .references(() => djSessions.id, { onDelete: 'cascade' }),
    role: text('role', { enum: ['user', 'dj'] }).notNull(),
    content: text('content').notNull(),
    queueVersion: integer('queue_version'),
    // now() is transaction-scoped: a user+dj pair written in one transaction gets
    // identical created_at, so transcript order must come from seq, not the timestamp.
    seq: bigserial('seq', { mode: 'number' }).notNull(),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [index('dj_messages_session_idx').on(t.sessionId, t.seq)],
)

// One durable "the listener said this lasts" note, saved live by the DJ's
// remember_preference tool (see dj/loop.ts) — never behaviorally distilled
// in v1. User-scoped, not session-scoped: a preference stated in one
// session should be respected in every later one.
export const djMemories = pgTable(
  'dj_memories',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    userId: text('user_id')
      .notNull()
      .references(() => user.id, { onDelete: 'cascade' }),
    note: text('note').notNull(),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    index('dj_memories_user_idx').on(t.userId, t.createdAt),
    // Backs executeRememberPreference's onConflictDoNothing dupe guard
    // (dj/loop.ts) — a plain select-then-insert check alone can't stop two
    // concurrent saves of the identical note from both landing, so the real
    // guarantee lives here at the DB level, not in application code.
    uniqueIndex('dj_memories_user_note_idx').on(t.userId, t.note),
  ],
)

export const sessionEvents = pgTable(
  'session_events',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    sessionId: uuid('session_id')
      .notNull()
      .references(() => djSessions.id, { onDelete: 'cascade' }),
    type: text('type', { enum: ['played', 'saved_playlist'] }).notNull(),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [index('session_events_session_idx').on(t.sessionId, t.createdAt)],
)

// No unique index on (session, position): renumbering would collide mid-shuffle against it.
// The queue store enforces the invariant under a per-session row lock (SELECT ... FOR UPDATE
// on dj_sessions) — see dj/queue-store.ts.
export const queueTracks = pgTable(
  'queue_tracks',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    sessionId: uuid('session_id')
      .notNull()
      .references(() => djSessions.id, { onDelete: 'cascade' }),
    position: integer('position').notNull(),
    trackId: uuid('track_id')
      .notNull()
      .references(() => tracks.id, { onDelete: 'cascade' }),
    reason: text('reason'),
    state: text('state', { enum: ['active', 'removed'] }).notNull().default('active'),
    addedBy: text('added_by', { enum: ['dj', 'user'] }).notNull(),
    removedBy: text('removed_by', { enum: ['dj', 'user'] }),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (t) => [index('queue_tracks_session_idx').on(t.sessionId, t.state, t.position)],
)
