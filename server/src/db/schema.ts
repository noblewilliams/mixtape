import { sql } from 'drizzle-orm'
import {
  pgTable,
  uuid,
  text,
  timestamp,
  uniqueIndex,
  index,
  integer,
  bigint,
  bigserial,
  boolean,
  date,
  primaryKey,
  doublePrecision,
  smallint,
  vector,
  check,
  foreignKey,
} from 'drizzle-orm/pg-core'
import { user } from './auth-schema'

export * from './auth-schema'

const playlistKindSql = sql`IN ('user', 'editorial', 'external', 'personal_mix', 'replay', 'user_shared', 'unknown')`
const listeningSourceSql = sql`IN ('spotify_export', 'apple_export')`
const artworkColorSql = (column: unknown) =>
  sql`${column} IS NULL OR ${column} ~ '^[0-9a-f]{6}$'`
const positiveOrNullSql = (column: unknown) => sql`${column} IS NULL OR ${column} > 0`
const nonnegativeOrNullSql = (column: unknown) => sql`${column} IS NULL OR ${column} >= 0`
// Spotify track and artist ids are 22 base62 characters.
const spotifyIdOrNullSql = (column: unknown) =>
  sql`${column} IS NULL OR ${column} ~ '^[0-9A-Za-z]{22}$'`
const storefrontOrNullSql = (column: unknown) =>
  sql`${column} IS NULL OR ${column} ~ '^[a-z]{2}$'`
const countryOrNullSql = (column: unknown) =>
  sql`${column} IS NULL OR ${column} ~ '^[A-Z]{2}$'`
// -1 dislike, 0 neutral, 1 love (Apple library export).
const likeRatingOrNullSql = (column: unknown) =>
  sql`${column} IS NULL OR ${column} IN (-1, 0, 1)`
// 24-bit mask: bit i set when the track played in local hour i.
const hoursMaskOrNullSql = (column: unknown) =>
  sql`${column} IS NULL OR ${column} BETWEEN 0 AND 16777215`
const platformIdSql = (column: unknown) => sql`char_length(${column}) BETWEEN 1 AND 64`
const artistNameSql = (column: unknown) => sql`char_length(${column}) BETWEEN 1 AND 500`

export const tracks = pgTable(
  'tracks',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    appleId: text('apple_id'),
    // Peer of apple_id, never a replacement: one recording may exist as
    // several rows that link by isrc (spec 2026-09-01 → Identity).
    spotifyId: text('spotify_id'),
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
    // Who last wrote `artist`. An export never overwrites a correction that
    // came from ReccoBeats or the Apple catalog.
    artistSource: text('artist_source', {
      enum: ['sync', 'export', 'reccobeats', 'apple_catalog'],
    })
      .notNull()
      .default('sync'),
    // Enrichment runs highest first; an import raises it for pool candidates.
    enrichPriority: integer('enrich_priority').notNull().default(0),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    uniqueIndex('tracks_apple_id_idx').on(t.appleId).where(sql`${t.appleId} IS NOT NULL`),
    uniqueIndex('tracks_spotify_id_idx')
      .on(t.spotifyId)
      .where(sql`${t.spotifyId} IS NOT NULL`),
    index('tracks_isrc_idx').on(t.isrc),
    index('tracks_enrich_priority_idx').on(t.enrichPriority.desc(), t.createdAt, t.id),
    check('tracks_spotify_id_check', spotifyIdOrNullSql(t.spotifyId)),
    check(
      'tracks_artist_source_check',
      sql`${t.artistSource} IN ('sync', 'export', 'reccobeats', 'apple_catalog')`,
    ),
    check('tracks_enrich_priority_check', sql`${t.enrichPriority} >= 0`),
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
    // Web MusicKit cannot observe lifetime play counts. Keeping an explicit
    // quality bit prevents "unknown" from becoming false zero-play evidence.
    playCountObserved: boolean('play_count_observed').notNull().default(true),
    lastPlayedAt: timestamp('last_played_at', { withTimezone: true }),
    dateAdded: timestamp('date_added', { withTimezone: true }),
    inLibrary: boolean('in_library').notNull().default(true),
    // Counted plays in the last 730 days, from the listening ledger.
    playCountRecent: integer('play_count_recent').notNull().default(0),
    skipCount: integer('skip_count'),
    likeRating: smallint('like_rating'),
    // Pasted or interview-seeded taste; an import never touches it.
    seeded: boolean('seeded').notNull().default(false),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (t) => [
    primaryKey({ columns: [t.userId, t.trackId] }),
    index('user_tracks_track_idx').on(t.trackId),
    check('user_tracks_play_count_recent_check', sql`${t.playCountRecent} >= 0`),
    check('user_tracks_skip_count_check', nonnegativeOrNullSql(t.skipCount)),
    check('user_tracks_like_rating_check', likeRatingOrNullSql(t.likeRating)),
  ],
)

export const userRecentTrackObservations = pgTable(
  'user_recent_track_observations',
  {
    userId: text('user_id')
      .notNull()
      .references(() => user.id, { onDelete: 'cascade' }),
    source: text('source', { enum: ['web_musickit'] }).notNull(),
    trackId: uuid('track_id')
      .notNull()
      .references(() => tracks.id, { onDelete: 'cascade' }),
    rank: integer('rank').notNull(),
    observedAt: timestamp('observed_at', { withTimezone: true }).notNull(),
  },
  (t) => [
    primaryKey({ columns: [t.userId, t.source, t.trackId] }),
    uniqueIndex('user_recent_tracks_source_rank_idx').on(t.userId, t.source, t.rank),
    index('user_recent_tracks_track_idx').on(t.trackId),
    check('user_recent_tracks_source_check', sql`${t.source} = 'web_musickit'`),
    check('user_recent_tracks_rank_check', sql`${t.rank} BETWEEN 0 AND 29`),
  ],
)

// Per-track-per-day play ledger from a listener's own export. `day` arrives
// already localized to the run's time zone; the server never converts it.
// A re-import replaces a day row's values, it never adds to them.
export const listeningDays = pgTable(
  'listening_days',
  {
    userId: text('user_id')
      .notNull()
      .references(() => user.id, { onDelete: 'cascade' }),
    source: text('source', { enum: ['spotify_export', 'apple_export'] }).notNull(),
    trackId: uuid('track_id')
      .notNull()
      .references(() => tracks.id, { onDelete: 'cascade' }),
    day: date('day', { mode: 'string' }).notNull(),
    plays: integer('plays').notNull(),
    skips: integer('skips'),
    completes: integer('completes'),
    msPlayed: bigint('ms_played', { mode: 'number' }).notNull(),
    hoursMask: integer('hours_mask'),
  },
  (t) => [
    primaryKey({ columns: [t.userId, t.source, t.trackId, t.day] }),
    index('listening_days_user_day_idx').on(t.userId, t.day),
    index('listening_days_track_idx').on(t.trackId),
    check('listening_days_source_check', sql`${t.source} ${listeningSourceSql}`),
    check('listening_days_plays_check', sql`${t.plays} >= 0`),
    check('listening_days_skips_check', nonnegativeOrNullSql(t.skips)),
    check('listening_days_completes_check', nonnegativeOrNullSql(t.completes)),
    check('listening_days_ms_played_check', sql`${t.msPlayed} >= 0`),
    check('listening_days_hours_mask_check', hoursMaskOrNullSql(t.hoursMask)),
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

// A single row serializes artwork catalog runs across cron and admin requests.
// Holding its row lock inside the batch transaction prevents duplicate Apple
// requests and stale late-arriving writes without permanently claiming tracks.
export const artworkRunLocks = pgTable('artwork_run_locks', {
  name: text('name').primaryKey(),
  updatedAt: timestamp('updated_at', { withTimezone: true }).notNull().defaultNow(),
})

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
    // Set when a mix came from the shared corpus and seeds rather than the
    // listener's own data ("not personal yet").
    notPersonal: boolean('not_personal').notNull().default(false),
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
    // Backs insertMemoryNote's onConflictDoNothing dupe guard
    // (dj/memory-notes.ts, shared by remember_preference and the interview) —
    // a plain select-then-insert check alone can't stop two concurrent saves
    // of the identical note from both landing, so the real guarantee lives
    // here at the DB level, not in application code.
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

// Spotify-listener funnel steps, counts only (spec 2026-09-01 → Funnel).
export const funnelEvents = pgTable(
  'funnel_events',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    userId: text('user_id')
      .notNull()
      .references(() => user.id, { onDelete: 'cascade' }),
    type: text('type', {
      enum: [
        'chose_spotify',
        'marked_requested',
        'interview_completed',
        'file_inspected',
        'import_completed',
        'first_personal_mix',
        'first_output',
      ],
    }).notNull(),
    surface: text('surface', { enum: ['ios', 'web'] }).notNull(),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    index('funnel_events_type_idx').on(t.type, t.createdAt),
    index('funnel_events_user_idx').on(t.userId, t.createdAt),
    check(
      'funnel_events_type_check',
      sql`${t.type} IN ('chose_spotify', 'marked_requested', 'interview_completed', 'file_inspected', 'import_completed', 'first_personal_mix', 'first_output')`,
    ),
    check('funnel_events_surface_check', sql`${t.surface} IN ('ios', 'web')`),
  ],
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

export const userMusicProfiles = pgTable(
  'user_music_profiles',
  {
    userId: text('user_id')
      .primaryKey()
      .references(() => user.id, { onDelete: 'cascade' }),
    // Null for a listener who has only brought an export (no Apple Music).
    appleStorefront: text('apple_storefront'),
    librarySyncedAt: timestamp('library_synced_at', { withTimezone: true }),
    playlistsSyncedAt: timestamp('playlists_synced_at', { withTimezone: true }),
    country: text('country'),
    // IANA zone name from the device; export day rows are localized to it.
    timeZone: text('time_zone'),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (t) => [
    check('user_music_profiles_storefront_check', storefrontOrNullSql(t.appleStorefront)),
    check('user_music_profiles_country_check', countryOrNullSql(t.country)),
    check(
      'user_music_profiles_time_zone_check',
      sql`${t.timeZone} IS NULL OR char_length(${t.timeZone}) <= 64`,
    ),
  ],
)

// Artists a listener named (interview), pasted, or follows on Spotify. Seed
// matches against the enriched corpus drive the pool before any data lands.
export const userArtistSeeds = pgTable(
  'user_artist_seeds',
  {
    userId: text('user_id')
      .notNull()
      .references(() => user.id, { onDelete: 'cascade' }),
    name: text('name').notNull(),
    spotifyId: text('spotify_id'),
    source: text('source', { enum: ['interview', 'pasted', 'spotify_export'] }).notNull(),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    primaryKey({ columns: [t.userId, t.name] }),
    check('user_artist_seeds_name_check', artistNameSql(t.name)),
    check('user_artist_seeds_spotify_id_check', spotifyIdOrNullSql(t.spotifyId)),
    check(
      'user_artist_seeds_source_check',
      sql`${t.source} IN ('interview', 'pasted', 'spotify_export')`,
    ),
  ],
)

// The set of places a listener's music comes from. Pool mode is personal as
// soon as one row exists; ledger bounds are tracked per source.
export const userMusicSources = pgTable(
  'user_music_sources',
  {
    userId: text('user_id')
      .notNull()
      .references(() => user.id, { onDelete: 'cascade' }),
    source: text('source', { enum: ['apple_live', 'apple_export', 'spotify_export'] }).notNull(),
    connectedAt: timestamp('connected_at', { withTimezone: true }).notNull().defaultNow(),
    lastImportedAt: timestamp('last_imported_at', { withTimezone: true }),
    ledgerFrom: date('ledger_from', { mode: 'string' }),
    ledgerTo: date('ledger_to', { mode: 'string' }),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (t) => [
    primaryKey({ columns: [t.userId, t.source] }),
    check(
      'user_music_sources_source_check',
      sql`${t.source} IN ('apple_live', 'apple_export', 'spotify_export')`,
    ),
  ],
)

export const librarySyncRuns = pgTable(
  'library_sync_runs',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    userId: text('user_id')
      .notNull()
      .references(() => user.id, { onDelete: 'cascade' }),
    source: text('source', { enum: ['ios_native', 'web_musickit'] }).notNull(),
    status: text('status', { enum: ['open', 'completed', 'failed', 'expired'] }).notNull(),
    appleStorefront: text('apple_storefront').notNull(),
    expectedSongs: integer('expected_songs').notNull(),
    receivedSongs: integer('received_songs').notNull().default(0),
    expectedRecentTracks: integer('expected_recent_tracks').notNull().default(0),
    receivedRecentTracks: integer('received_recent_tracks').notNull().default(0),
    resultSongs: integer('result_songs'),
    resultCatalogResolved: integer('result_catalog_resolved'),
    resultPlayCountsObserved: integer('result_play_counts_observed'),
    resultRecentTracks: integer('result_recent_tracks'),
    startedAt: timestamp('started_at', { withTimezone: true }).notNull().defaultNow(),
    expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
    completedAt: timestamp('completed_at', { withTimezone: true }),
  },
  (t) => [
    uniqueIndex('library_sync_runs_one_open_user_idx')
      .on(t.userId)
      .where(sql`${t.status} = 'open'`),
    index('library_sync_runs_user_status_started_idx').on(t.userId, t.status, t.startedAt),
    index('library_sync_runs_open_cleanup_idx')
      .on(t.startedAt, t.id)
      .where(sql`${t.status} = 'open'`),
    index('library_sync_runs_expired_cleanup_idx')
      .on(t.expiresAt, t.id)
      .where(sql`${t.status} = 'expired'`),
    index('library_sync_runs_completed_cleanup_idx')
      .on(t.completedAt, t.id)
      .where(sql`${t.status} = 'completed'`),
    check(
      'library_sync_runs_source_check',
      sql`${t.source} IN ('ios_native', 'web_musickit')`,
    ),
    check(
      'library_sync_runs_status_check',
      sql`${t.status} IN ('open', 'completed', 'failed', 'expired')`,
    ),
    check('library_sync_runs_storefront_check', sql`${t.appleStorefront} ~ '^[a-z]{2}$'`),
    check('library_sync_runs_expected_songs_check', sql`${t.expectedSongs} >= 0`),
    check('library_sync_runs_received_songs_check', sql`${t.receivedSongs} >= 0`),
    check(
      'library_sync_runs_expected_recent_check',
      sql`${t.expectedRecentTracks} BETWEEN 0 AND 30`,
    ),
    check(
      'library_sync_runs_received_recent_check',
      sql`${t.receivedRecentTracks} BETWEEN 0 AND 30`,
    ),
    check('library_sync_runs_result_songs_check', nonnegativeOrNullSql(t.resultSongs)),
    check(
      'library_sync_runs_result_catalog_check',
      nonnegativeOrNullSql(t.resultCatalogResolved),
    ),
    check(
      'library_sync_runs_result_play_counts_check',
      nonnegativeOrNullSql(t.resultPlayCountsObserved),
    ),
    check(
      'library_sync_runs_result_recent_check',
      nonnegativeOrNullSql(t.resultRecentTracks),
    ),
  ],
)

export const librarySyncSongs = pgTable(
  'library_sync_songs',
  {
    syncId: uuid('sync_id')
      .notNull()
      .references(() => librarySyncRuns.id, { onDelete: 'cascade' }),
    ordinal: integer('ordinal').notNull(),
    appleLibraryId: text('apple_library_id'),
    appleCatalogId: text('apple_catalog_id').notNull(),
    title: text('title').notNull(),
    artist: text('artist').notNull(),
    album: text('album'),
    genre: text('genre'),
    releaseYear: integer('release_year'),
    explicit: boolean('explicit'),
    playCount: integer('play_count'),
    lastPlayedAt: timestamp('last_played_at', { withTimezone: true }),
    dateAdded: timestamp('date_added', { withTimezone: true }),
  },
  (t) => [
    primaryKey({ columns: [t.syncId, t.ordinal] }),
    uniqueIndex('library_sync_songs_sync_catalog_idx').on(t.syncId, t.appleCatalogId),
    uniqueIndex('library_sync_songs_sync_library_idx')
      .on(t.syncId, t.appleLibraryId)
      .where(sql`${t.appleLibraryId} IS NOT NULL`),
    check('library_sync_songs_ordinal_check', sql`${t.ordinal} >= 0`),
    check('library_sync_songs_play_count_check', nonnegativeOrNullSql(t.playCount)),
    check(
      'library_sync_songs_release_year_check',
      sql`${t.releaseYear} IS NULL OR ${t.releaseYear} BETWEEN 1900 AND 3000`,
    ),
  ],
)

export const librarySyncRecentTracks = pgTable(
  'library_sync_recent_tracks',
  {
    syncId: uuid('sync_id')
      .notNull()
      .references(() => librarySyncRuns.id, { onDelete: 'cascade' }),
    rank: integer('rank').notNull(),
    appleCatalogId: text('apple_catalog_id').notNull(),
  },
  (t) => [
    primaryKey({ columns: [t.syncId, t.rank] }),
    uniqueIndex('library_sync_recent_sync_catalog_idx').on(t.syncId, t.appleCatalogId),
    check('library_sync_recent_rank_check', sql`${t.rank} BETWEEN 0 AND 29`),
  ],
)

// Listening-export staging, same discipline as library_sync_*: one open run
// per (user, source), chunks land here, complete publishes in one transaction.
export const listeningImportRuns = pgTable(
  'listening_import_runs',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    userId: text('user_id')
      .notNull()
      .references(() => user.id, { onDelete: 'cascade' }),
    source: text('source', { enum: ['spotify_export', 'apple_export'] }).notNull(),
    // Which files the device parsed; decides which chunk types the run carries.
    package: text('package', {
      enum: ['spotify_extended', 'spotify_account', 'apple_media'],
    }).notNull(),
    status: text('status', { enum: ['open', 'completed', 'failed', 'expired'] }).notNull(),
    timeZone: text('time_zone').notNull(),
    country: text('country'),
    expectedTracks: integer('expected_tracks').notNull(),
    receivedTracks: integer('received_tracks').notNull().default(0),
    expectedDays: integer('expected_days').notNull(),
    receivedDays: integer('received_days').notNull().default(0),
    expectedLibraryTracks: integer('expected_library_tracks').notNull(),
    receivedLibraryTracks: integer('received_library_tracks').notNull().default(0),
    expectedArtists: integer('expected_artists').notNull(),
    receivedArtists: integer('received_artists').notNull().default(0),
    // Export rows the parser could not attribute to a track: counts only.
    unresolvedRows: integer('unresolved_rows').notNull().default(0),
    unresolvedPlays: integer('unresolved_plays').notNull().default(0),
    resultTracks: integer('result_tracks'),
    resultDays: integer('result_days'),
    resultLibraryTracks: integer('result_library_tracks'),
    resultArtists: integer('result_artists'),
    // Spotify account re-import: liked rows marked out of the library, or
    // skipped (and why the summary says so) for listeners with a live Apple
    // library, whose in_library the library sync owns.
    resultLikedRemoved: integer('result_liked_removed'),
    resultLikedRemovalSkipped: boolean('result_liked_removal_skipped'),
    ledgerFrom: date('ledger_from', { mode: 'string' }),
    ledgerTo: date('ledger_to', { mode: 'string' }),
    startedAt: timestamp('started_at', { withTimezone: true }).notNull().defaultNow(),
    expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
    completedAt: timestamp('completed_at', { withTimezone: true }),
  },
  (t) => [
    uniqueIndex('listening_import_runs_one_open_user_source_idx')
      .on(t.userId, t.source)
      .where(sql`${t.status} = 'open'`),
    index('listening_import_runs_user_status_started_idx').on(t.userId, t.status, t.startedAt),
    index('listening_import_runs_open_cleanup_idx')
      .on(t.startedAt, t.id)
      .where(sql`${t.status} = 'open'`),
    index('listening_import_runs_expired_cleanup_idx')
      .on(t.expiresAt, t.id)
      .where(sql`${t.status} = 'expired'`),
    index('listening_import_runs_completed_cleanup_idx')
      .on(t.completedAt, t.id)
      .where(sql`${t.status} = 'completed'`),
    check('listening_import_runs_source_check', sql`${t.source} ${listeningSourceSql}`),
    check(
      'listening_import_runs_package_check',
      sql`${t.package} IN ('spotify_extended', 'spotify_account', 'apple_media')`,
    ),
    check(
      'listening_import_runs_status_check',
      sql`${t.status} IN ('open', 'completed', 'failed', 'expired')`,
    ),
    check(
      'listening_import_runs_package_source_check',
      sql`(${t.source} = 'spotify_export' AND ${t.package} IN ('spotify_extended', 'spotify_account')) OR (${t.source} = 'apple_export' AND ${t.package} = 'apple_media')`,
    ),
    // A package only expects the chunk types it carries.
    check(
      'listening_import_runs_extended_counts_check',
      sql`${t.package} <> 'spotify_extended' OR (${t.expectedLibraryTracks} = 0 AND ${t.expectedArtists} = 0)`,
    ),
    check(
      'listening_import_runs_account_counts_check',
      sql`${t.package} <> 'spotify_account' OR ${t.expectedDays} = 0`,
    ),
    check(
      'listening_import_runs_apple_counts_check',
      sql`${t.package} <> 'apple_media' OR ${t.expectedArtists} = 0`,
    ),
    check('listening_import_runs_time_zone_check', sql`char_length(${t.timeZone}) <= 64`),
    check('listening_import_runs_country_check', countryOrNullSql(t.country)),
    check('listening_import_runs_expected_tracks_check', sql`${t.expectedTracks} >= 0`),
    check('listening_import_runs_received_tracks_check', sql`${t.receivedTracks} >= 0`),
    check('listening_import_runs_expected_days_check', sql`${t.expectedDays} >= 0`),
    check('listening_import_runs_received_days_check', sql`${t.receivedDays} >= 0`),
    check(
      'listening_import_runs_expected_library_tracks_check',
      sql`${t.expectedLibraryTracks} >= 0`,
    ),
    check(
      'listening_import_runs_received_library_tracks_check',
      sql`${t.receivedLibraryTracks} >= 0`,
    ),
    check('listening_import_runs_expected_artists_check', sql`${t.expectedArtists} >= 0`),
    check('listening_import_runs_received_artists_check', sql`${t.receivedArtists} >= 0`),
    check('listening_import_runs_unresolved_rows_check', sql`${t.unresolvedRows} >= 0`),
    check('listening_import_runs_unresolved_plays_check', sql`${t.unresolvedPlays} >= 0`),
    check('listening_import_runs_result_tracks_check', nonnegativeOrNullSql(t.resultTracks)),
    check('listening_import_runs_result_days_check', nonnegativeOrNullSql(t.resultDays)),
    check(
      'listening_import_runs_result_library_tracks_check',
      nonnegativeOrNullSql(t.resultLibraryTracks),
    ),
    check('listening_import_runs_result_artists_check', nonnegativeOrNullSql(t.resultArtists)),
    check(
      'listening_import_runs_result_liked_removed_check',
      nonnegativeOrNullSql(t.resultLikedRemoved),
    ),
  ],
)

export const listeningImportTracks = pgTable(
  'listening_import_tracks',
  {
    importId: uuid('import_id')
      .notNull()
      .references(() => listeningImportRuns.id, { onDelete: 'cascade' }),
    ordinal: integer('ordinal').notNull(),
    // Spotify track id or Apple song id; the store validates it per the run's source.
    platformId: text('platform_id').notNull(),
    title: text('title').notNull(),
    artist: text('artist').notNull(),
    album: text('album'),
    durationMs: integer('duration_ms'),
  },
  (t) => [
    primaryKey({ columns: [t.importId, t.ordinal] }),
    uniqueIndex('listening_import_tracks_import_platform_idx').on(t.importId, t.platformId),
    check('listening_import_tracks_ordinal_check', sql`${t.ordinal} >= 0`),
    check('listening_import_tracks_platform_id_check', platformIdSql(t.platformId)),
    check('listening_import_tracks_duration_check', nonnegativeOrNullSql(t.durationMs)),
  ],
)

export const listeningImportDays = pgTable(
  'listening_import_days',
  {
    importId: uuid('import_id')
      .notNull()
      .references(() => listeningImportRuns.id, { onDelete: 'cascade' }),
    ordinal: integer('ordinal').notNull(),
    platformId: text('platform_id').notNull(),
    day: date('day', { mode: 'string' }).notNull(),
    plays: integer('plays').notNull(),
    skips: integer('skips'),
    completes: integer('completes'),
    msPlayed: bigint('ms_played', { mode: 'number' }).notNull(),
    hoursMask: integer('hours_mask'),
  },
  (t) => [
    primaryKey({ columns: [t.importId, t.ordinal] }),
    uniqueIndex('listening_import_days_import_platform_day_idx').on(
      t.importId,
      t.platformId,
      t.day,
    ),
    check('listening_import_days_ordinal_check', sql`${t.ordinal} >= 0`),
    check('listening_import_days_platform_id_check', platformIdSql(t.platformId)),
    check('listening_import_days_plays_check', sql`${t.plays} >= 0`),
    check('listening_import_days_skips_check', nonnegativeOrNullSql(t.skips)),
    check('listening_import_days_completes_check', nonnegativeOrNullSql(t.completes)),
    check('listening_import_days_ms_played_check', sql`${t.msPlayed} >= 0`),
    check('listening_import_days_hours_mask_check', hoursMaskOrNullSql(t.hoursMask)),
  ],
)

// Apple library rows or Spotify liked tracks, keyed by the run's platform id.
export const listeningImportLibrary = pgTable(
  'listening_import_library',
  {
    importId: uuid('import_id')
      .notNull()
      .references(() => listeningImportRuns.id, { onDelete: 'cascade' }),
    ordinal: integer('ordinal').notNull(),
    platformId: text('platform_id').notNull(),
    playCount: integer('play_count'),
    skipCount: integer('skip_count'),
    lastPlayedAt: timestamp('last_played_at', { withTimezone: true }),
    dateAdded: timestamp('date_added', { withTimezone: true }),
    likeRating: smallint('like_rating'),
  },
  (t) => [
    primaryKey({ columns: [t.importId, t.ordinal] }),
    uniqueIndex('listening_import_library_import_platform_idx').on(t.importId, t.platformId),
    check('listening_import_library_ordinal_check', sql`${t.ordinal} >= 0`),
    check('listening_import_library_platform_id_check', platformIdSql(t.platformId)),
    check('listening_import_library_play_count_check', nonnegativeOrNullSql(t.playCount)),
    check('listening_import_library_skip_count_check', nonnegativeOrNullSql(t.skipCount)),
    check('listening_import_library_like_rating_check', likeRatingOrNullSql(t.likeRating)),
  ],
)

export const listeningImportArtists = pgTable(
  'listening_import_artists',
  {
    importId: uuid('import_id')
      .notNull()
      .references(() => listeningImportRuns.id, { onDelete: 'cascade' }),
    ordinal: integer('ordinal').notNull(),
    name: text('name').notNull(),
    spotifyId: text('spotify_id'),
  },
  (t) => [
    primaryKey({ columns: [t.importId, t.ordinal] }),
    uniqueIndex('listening_import_artists_import_name_idx').on(t.importId, t.name),
    check('listening_import_artists_ordinal_check', sql`${t.ordinal} >= 0`),
    check('listening_import_artists_name_check', artistNameSql(t.name)),
    check('listening_import_artists_spotify_id_check', spotifyIdOrNullSql(t.spotifyId)),
  ],
)

export const userPlaylists = pgTable(
  'user_playlists',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    userId: text('user_id')
      .notNull()
      .references(() => user.id, { onDelete: 'cascade' }),
    appleLibraryId: text('apple_library_id').notNull(),
    appleCatalogId: text('apple_catalog_id'),
    name: text('name').notNull(),
    description: text('description'),
    curatorName: text('curator_name'),
    artworkUrlTemplate: text('artwork_url_template'),
    artworkWidth: integer('artwork_width'),
    artworkHeight: integer('artwork_height'),
    artworkBgColor: text('artwork_bg_color'),
    kind: text('kind', {
      enum: ['user', 'editorial', 'external', 'personal_mix', 'replay', 'user_shared', 'unknown'],
    }).notNull(),
    canEdit: boolean('can_edit').notNull().default(false),
    isMixtapeOwned: boolean('is_mixtape_owned').notNull().default(false),
    appleDateAdded: timestamp('apple_date_added', { withTimezone: true }),
    appleLastModifiedAt: timestamp('apple_last_modified_at', { withTimezone: true }),
    sourceFingerprint: text('source_fingerprint').notNull(),
    inLibrary: boolean('in_library').notNull().default(true),
    // Where the playlist came from; the Apple-flavored id columns hold the
    // Spotify export's opaque keys for that source (naming debt, backlog).
    source: text('source', { enum: ['apple', 'spotify_export'] }).notNull().default('apple'),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (t) => [
    uniqueIndex('user_playlists_user_library_idx').on(t.userId, t.appleLibraryId),
    index('user_playlists_active_browse_idx')
      .on(t.userId, sql`coalesce(${t.appleLastModifiedAt}, ${t.updatedAt})`, t.id)
      .where(sql`${t.inLibrary} = true`),
    check('user_playlists_kind_check', sql`${t.kind} ${playlistKindSql}`),
    check('user_playlists_source_check', sql`${t.source} IN ('apple', 'spotify_export')`),
    check('user_playlists_artwork_bg_color_check', artworkColorSql(t.artworkBgColor)),
    check('user_playlists_artwork_width_positive_check', positiveOrNullSql(t.artworkWidth)),
    check('user_playlists_artwork_height_positive_check', positiveOrNullSql(t.artworkHeight)),
    check(
      'user_playlists_source_fingerprint_check',
      sql`${t.sourceFingerprint} ~ '^[0-9a-f]{64}$'`,
    ),
  ],
)

export const playlistEntries = pgTable(
  'playlist_entries',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    playlistId: uuid('playlist_id')
      .notNull()
      .references(() => userPlaylists.id, { onDelete: 'cascade' }),
    position: integer('position').notNull(),
    trackId: uuid('track_id').references(() => tracks.id, { onDelete: 'set null' }),
    appleLibraryEntryId: text('apple_library_entry_id').notNull(),
    appleLibraryTrackId: text('apple_library_track_id'),
    appleCatalogId: text('apple_catalog_id'),
    spotifyId: text('spotify_id'),
    isrcSnapshot: text('isrc_snapshot'),
    titleSnapshot: text('title_snapshot').notNull(),
    artistSnapshot: text('artist_snapshot').notNull(),
    albumSnapshot: text('album_snapshot'),
    durationMsSnapshot: integer('duration_ms_snapshot'),
    artworkUrlTemplateSnapshot: text('artwork_url_template_snapshot'),
    artworkWidthSnapshot: integer('artwork_width_snapshot'),
    artworkHeightSnapshot: integer('artwork_height_snapshot'),
    artworkBgColorSnapshot: text('artwork_bg_color_snapshot'),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (t) => [
    uniqueIndex('playlist_entries_playlist_position_idx').on(t.playlistId, t.position),
    uniqueIndex('playlist_entries_playlist_library_entry_idx')
      .on(t.playlistId, t.appleLibraryEntryId),
    index('playlist_entries_track_idx').on(t.trackId).where(sql`${t.trackId} IS NOT NULL`),
    check('playlist_entries_position_nonnegative_check', sql`${t.position} >= 0`),
    check('playlist_entries_spotify_id_check', spotifyIdOrNullSql(t.spotifyId)),
    check(
      'playlist_entries_duration_nonnegative_check',
      nonnegativeOrNullSql(t.durationMsSnapshot),
    ),
    check(
      'playlist_entries_artwork_bg_color_check',
      artworkColorSql(t.artworkBgColorSnapshot),
    ),
    check(
      'playlist_entries_artwork_width_positive_check',
      positiveOrNullSql(t.artworkWidthSnapshot),
    ),
    check(
      'playlist_entries_artwork_height_positive_check',
      positiveOrNullSql(t.artworkHeightSnapshot),
    ),
  ],
)

export const playlistSyncRuns = pgTable(
  'playlist_sync_runs',
  {
    id: uuid('id').primaryKey().defaultRandom(),
    userId: text('user_id')
      .notNull()
      .references(() => user.id, { onDelete: 'cascade' }),
    source: text('source', { enum: ['ios_native', 'web_musickit', 'spotify_export'] })
      .notNull()
      .default('ios_native'),
    status: text('status', { enum: ['open', 'completed', 'failed', 'expired'] }).notNull(),
    // Null only for a Spotify export run.
    appleStorefront: text('apple_storefront'),
    expectedPlaylists: integer('expected_playlists').notNull(),
    expectedEntries: integer('expected_entries').notNull(),
    receivedPlaylists: integer('received_playlists').notNull().default(0),
    receivedEntries: integer('received_entries').notNull().default(0),
    resultPlaylists: integer('result_playlists'),
    resultEntries: integer('result_entries'),
    resultResolvedEntries: integer('result_resolved_entries'),
    resultUnresolvedEntries: integer('result_unresolved_entries'),
    startedAt: timestamp('started_at', { withTimezone: true }).notNull().defaultNow(),
    expiresAt: timestamp('expires_at', { withTimezone: true }).notNull(),
    completedAt: timestamp('completed_at', { withTimezone: true }),
  },
  (t) => [
    uniqueIndex('playlist_sync_runs_one_open_user_idx')
      .on(t.userId)
      .where(sql`${t.status} = 'open'`),
    index('playlist_sync_runs_user_status_started_idx').on(t.userId, t.status, t.startedAt),
    index('playlist_sync_runs_open_cleanup_idx')
      .on(t.startedAt, t.id)
      .where(sql`${t.status} = 'open'`),
    index('playlist_sync_runs_expired_cleanup_idx')
      .on(t.expiresAt, t.id)
      .where(sql`${t.status} = 'expired'`),
    index('playlist_sync_runs_completed_cleanup_idx')
      .on(t.completedAt, t.id)
      .where(sql`${t.status} = 'completed'`),
    check(
      'playlist_sync_runs_status_check',
      sql`${t.status} IN ('open', 'completed', 'failed', 'expired')`,
    ),
    check(
      'playlist_sync_runs_source_check',
      sql`${t.source} IN ('ios_native', 'web_musickit', 'spotify_export')`,
    ),
    check('playlist_sync_runs_storefront_check', storefrontOrNullSql(t.appleStorefront)),
    check('playlist_sync_runs_expected_playlists_check', sql`${t.expectedPlaylists} >= 0`),
    check('playlist_sync_runs_expected_entries_check', sql`${t.expectedEntries} >= 0`),
    check('playlist_sync_runs_received_playlists_check', sql`${t.receivedPlaylists} >= 0`),
    check('playlist_sync_runs_received_entries_check', sql`${t.receivedEntries} >= 0`),
    check('playlist_sync_runs_result_playlists_check', nonnegativeOrNullSql(t.resultPlaylists)),
    check('playlist_sync_runs_result_entries_check', nonnegativeOrNullSql(t.resultEntries)),
    check(
      'playlist_sync_runs_result_resolved_check',
      nonnegativeOrNullSql(t.resultResolvedEntries),
    ),
    check(
      'playlist_sync_runs_result_unresolved_check',
      nonnegativeOrNullSql(t.resultUnresolvedEntries),
    ),
  ],
)

export const playlistSyncPlaylists = pgTable(
  'playlist_sync_playlists',
  {
    syncId: uuid('sync_id')
      .notNull()
      .references(() => playlistSyncRuns.id, { onDelete: 'cascade' }),
    ordinal: integer('ordinal').notNull(),
    appleLibraryId: text('apple_library_id').notNull(),
    appleCatalogId: text('apple_catalog_id'),
    name: text('name').notNull(),
    description: text('description'),
    curatorName: text('curator_name'),
    artworkUrlTemplate: text('artwork_url_template'),
    artworkWidth: integer('artwork_width'),
    artworkHeight: integer('artwork_height'),
    artworkBgColor: text('artwork_bg_color'),
    kind: text('kind', {
      enum: ['user', 'editorial', 'external', 'personal_mix', 'replay', 'user_shared', 'unknown'],
    }).notNull(),
    canEdit: boolean('can_edit').notNull().default(false),
    appleDateAdded: timestamp('apple_date_added', { withTimezone: true }),
    appleLastModifiedAt: timestamp('apple_last_modified_at', { withTimezone: true }),
    sourceFingerprint: text('source_fingerprint').notNull(),
    entryCount: integer('entry_count').notNull(),
  },
  (t) => [
    primaryKey({ columns: [t.syncId, t.appleLibraryId] }),
    uniqueIndex('playlist_sync_playlists_sync_ordinal_idx').on(t.syncId, t.ordinal),
    check('playlist_sync_playlists_ordinal_check', sql`${t.ordinal} >= 0`),
    check('playlist_sync_playlists_entry_count_check', sql`${t.entryCount} >= 0`),
    check('playlist_sync_playlists_kind_check', sql`${t.kind} ${playlistKindSql}`),
    check(
      'playlist_sync_playlists_artwork_bg_color_check',
      artworkColorSql(t.artworkBgColor),
    ),
    check(
      'playlist_sync_playlists_artwork_width_positive_check',
      positiveOrNullSql(t.artworkWidth),
    ),
    check(
      'playlist_sync_playlists_artwork_height_positive_check',
      positiveOrNullSql(t.artworkHeight),
    ),
    check(
      'playlist_sync_playlists_source_fingerprint_check',
      sql`${t.sourceFingerprint} ~ '^[0-9a-f]{64}$'`,
    ),
  ],
)

export const playlistSyncEntries = pgTable(
  'playlist_sync_entries',
  {
    syncId: uuid('sync_id').notNull(),
    applePlaylistId: text('apple_playlist_id').notNull(),
    position: integer('position').notNull(),
    appleLibraryEntryId: text('apple_library_entry_id').notNull(),
    appleLibraryTrackId: text('apple_library_track_id'),
    appleCatalogId: text('apple_catalog_id'),
    spotifyId: text('spotify_id'),
    isrcSnapshot: text('isrc_snapshot'),
    titleSnapshot: text('title_snapshot').notNull(),
    artistSnapshot: text('artist_snapshot').notNull(),
    albumSnapshot: text('album_snapshot'),
    durationMsSnapshot: integer('duration_ms_snapshot'),
    artworkUrlTemplateSnapshot: text('artwork_url_template_snapshot'),
    artworkWidthSnapshot: integer('artwork_width_snapshot'),
    artworkHeightSnapshot: integer('artwork_height_snapshot'),
    artworkBgColorSnapshot: text('artwork_bg_color_snapshot'),
  },
  (t) => [
    primaryKey({ columns: [t.syncId, t.applePlaylistId, t.position] }),
    foreignKey({
      columns: [t.syncId, t.applePlaylistId],
      foreignColumns: [playlistSyncPlaylists.syncId, playlistSyncPlaylists.appleLibraryId],
      name: 'playlist_sync_entries_playlist_fk',
    }).onDelete('cascade'),
    check('playlist_sync_entries_position_check', sql`${t.position} >= 0`),
    check('playlist_sync_entries_spotify_id_check', spotifyIdOrNullSql(t.spotifyId)),
    check(
      'playlist_sync_entries_duration_check',
      nonnegativeOrNullSql(t.durationMsSnapshot),
    ),
    check(
      'playlist_sync_entries_artwork_bg_color_check',
      artworkColorSql(t.artworkBgColorSnapshot),
    ),
    check(
      'playlist_sync_entries_artwork_width_positive_check',
      positiveOrNullSql(t.artworkWidthSnapshot),
    ),
    check(
      'playlist_sync_entries_artwork_height_positive_check',
      positiveOrNullSql(t.artworkHeightSnapshot),
    ),
  ],
)
