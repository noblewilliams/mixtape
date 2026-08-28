import { sql } from 'drizzle-orm'
import { pgTable, uuid, text, timestamp, uniqueIndex, index } from 'drizzle-orm/pg-core'

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
