import { sql } from 'drizzle-orm'
import {
  pgTable,
  uuid,
  text,
  timestamp,
  uniqueIndex,
  index,
  integer,
  boolean,
  primaryKey,
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
    createdAt: timestamp('created_at', { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    uniqueIndex('tracks_apple_id_idx').on(t.appleId).where(sql`${t.appleId} IS NOT NULL`),
    index('tracks_isrc_idx').on(t.isrc),
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
