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
  foreignKey,
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

const playlistKindSql = sql`IN ('user', 'editorial', 'external', 'personal_mix', 'replay', 'user_shared', 'unknown')`
const artworkColorSql = (column: unknown) =>
  sql`${column} IS NULL OR ${column} ~ '^[0-9a-f]{6}$'`
const positiveOrNullSql = (column: unknown) => sql`${column} IS NULL OR ${column} > 0`
const nonnegativeOrNullSql = (column: unknown) => sql`${column} IS NULL OR ${column} >= 0`

export const userMusicProfiles = pgTable(
  'user_music_profiles',
  {
    userId: text('user_id')
      .primaryKey()
      .references(() => user.id, { onDelete: 'cascade' }),
    appleStorefront: text('apple_storefront').notNull(),
    librarySyncedAt: timestamp('library_synced_at', { withTimezone: true }),
    playlistsSyncedAt: timestamp('playlists_synced_at', { withTimezone: true }),
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp('updated_at', { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (t) => [
    check('user_music_profiles_storefront_check', sql`${t.appleStorefront} ~ '^[a-z]{2}$'`),
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
    index('playlist_entries_track_idx').on(t.trackId).where(sql`${t.trackId} IS NOT NULL`),
    check('playlist_entries_position_nonnegative_check', sql`${t.position} >= 0`),
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
    status: text('status', { enum: ['open', 'completed', 'failed', 'expired'] }).notNull(),
    appleStorefront: text('apple_storefront').notNull(),
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
    check(
      'playlist_sync_runs_status_check',
      sql`${t.status} IN ('open', 'completed', 'failed', 'expired')`,
    ),
    check('playlist_sync_runs_storefront_check', sql`${t.appleStorefront} ~ '^[a-z]{2}$'`),
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
