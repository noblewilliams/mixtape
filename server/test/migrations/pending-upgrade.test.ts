import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { PGlite } from '@electric-sql/pglite'
import { vector } from '@electric-sql/pglite-pgvector'
import { drizzle } from 'drizzle-orm/pglite'
import { migrate } from 'drizzle-orm/pglite/migrator'
import { afterEach, describe, expect, it } from 'vitest'

const migrationsDir = fileURLToPath(new URL('../../drizzle', import.meta.url))
const cleanupPaths: string[] = []

afterEach(async () => {
  await Promise.all(cleanupPaths.splice(0).map((path) => rm(path, { recursive: true, force: true })))
})

async function createProductionBaselineMigrations(): Promise<string> {
  const baselineDir = await mkdtemp(join(tmpdir(), 'mixtape-migrations-0014-'))
  cleanupPaths.push(baselineDir)
  await mkdir(join(baselineDir, 'meta'))

  const journal = JSON.parse(await readFile(join(migrationsDir, 'meta', '_journal.json'), 'utf8')) as {
    entries: Array<{ idx: number; tag: string }>
  }
  const baselineEntries = journal.entries.filter((entry) => entry.idx <= 14)

  await writeFile(
    join(baselineDir, 'meta', '_journal.json'),
    `${JSON.stringify({ ...journal, entries: baselineEntries }, null, 2)}\n`,
  )
  await Promise.all(
    baselineEntries.map((entry) =>
      copyFile(join(migrationsDir, `${entry.tag}.sql`), join(baselineDir, `${entry.tag}.sql`)),
    ),
  )

  return baselineDir
}

describe('pending production migration chain', () => {
  it('upgrades representative 0014 data through the current journal', async () => {
    const baselineDir = await createProductionBaselineMigrations()
    const client = new PGlite({ extensions: { vector } })
    const db = drizzle(client)

    try {
      await migrate(db, { migrationsFolder: baselineDir })

      await client.exec(`
        INSERT INTO "user" ("id", "name", "email")
        VALUES ('upgrade-user', 'Upgrade Test', 'upgrade@example.test');

        INSERT INTO "tracks" ("id", "apple_id", "title", "artist")
        VALUES ('00000000-0000-4000-8000-000000000001', 'legacy-song', 'Legacy Song', 'Legacy Artist');

        INSERT INTO "user_tracks" ("user_id", "track_id", "play_count", "in_library")
        VALUES ('upgrade-user', '00000000-0000-4000-8000-000000000001', 9, true);

        INSERT INTO "user_music_profiles" ("user_id", "apple_storefront")
        VALUES ('upgrade-user', 'us');

        INSERT INTO "user_playlists" (
          "id", "user_id", "apple_library_id", "name", "kind", "source_fingerprint"
        ) VALUES (
          '00000000-0000-4000-8000-000000000002',
          'upgrade-user',
          'legacy-playlist',
          'Legacy Playlist',
          'user',
          '${'a'.repeat(64)}'
        );

        INSERT INTO "dj_sessions" ("id", "user_id", "title")
        VALUES ('00000000-0000-4000-8000-000000000003', 'upgrade-user', 'Legacy Session');
      `)

      await migrate(db, { migrationsFolder: migrationsDir })

      const migratedUserTrack = await client.query<{
        play_count: number
        play_count_observed: boolean
        play_count_recent: number
        seeded: boolean
      }>(`
        SELECT "play_count", "play_count_observed", "play_count_recent", "seeded"
        FROM "user_tracks"
        WHERE "user_id" = 'upgrade-user'
      `)
      expect(migratedUserTrack.rows).toEqual([
        { play_count: 9, play_count_observed: true, play_count_recent: 0, seeded: false },
      ])

      const librarySources = await client.query<{ source: string }>(`
        SELECT "source"
        FROM "user_track_library_sources"
        WHERE "user_id" = 'upgrade-user'
      `)
      expect(librarySources.rows).toEqual([{ source: 'legacy' }])

      const playlist = await client.query<{ source: string }>(`
        SELECT "source"
        FROM "user_playlists"
        WHERE "user_id" = 'upgrade-user'
      `)
      expect(playlist.rows).toEqual([{ source: 'apple' }])

      const session = await client.query<{ not_personal: boolean }>(`
        SELECT "not_personal"
        FROM "dj_sessions"
        WHERE "user_id" = 'upgrade-user'
      `)
      expect(session.rows).toEqual([{ not_personal: false }])

      await client.exec(`
        INSERT INTO "session_playlist_seeds" (
          "session_id", "playlist_id", "enabled", "exclude_source_tracks"
        ) VALUES (
          '00000000-0000-4000-8000-000000000003',
          '00000000-0000-4000-8000-000000000002',
          true,
          true
        );
      `)

      const migrationCount = await client.query<{ count: number }>(`
        SELECT count(*)::int AS "count"
        FROM "drizzle"."__drizzle_migrations"
      `)
      expect(migrationCount.rows).toEqual([{ count: 27 }])
    } finally {
      await client.close()
    }
  })
})
