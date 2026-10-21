import { describe, it, expect } from 'vitest'
import { sql } from 'drizzle-orm'
import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { createTestDb } from '../helpers/db'
import { user, userArtistSeeds } from '../../src/db/schema'

const MIGRATION = fileURLToPath(new URL('../../drizzle/0041_artist_seed_prompt_source.sql', import.meta.url))

async function dbWithUser() {
  const db = await createTestDb()
  await db.insert(user).values({ id: 'u1', name: 'u1', email: 'u1@example.com', emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
  return db
}

// Migration 0041: user_artist_seeds.source admits 'prompt' (artists the
// listener names in a brief, saved by the DJ loop) and nothing else new.
describe('user_artist_seeds.source', () => {
  it("accepts 'prompt' next to the existing sources", async () => {
    const db = await dbWithUser()
    for (const [name, source] of [['a', 'interview'], ['b', 'pasted'], ['c', 'spotify_export'], ['d', 'prompt']] as const) {
      await db.insert(userArtistSeeds).values({ userId: 'u1', name, source })
    }
    expect(await db.select().from(userArtistSeeds)).toHaveLength(4)
  })

  it('still rejects an unknown source', async () => {
    const db = await dbWithUser()
    const err = await db
      .execute(sql`INSERT INTO user_artist_seeds (user_id, name, source) VALUES ('u1', 'x', 'bogus')`)
      .then(() => undefined, (e: unknown) => e as { cause?: { constraint?: string }; constraint?: string })
    expect(err?.cause?.constraint ?? err?.constraint).toBe('user_artist_seeds_source_check')
  })

  it('the migration only swaps that one constraint', async () => {
    const statements = (await readFile(MIGRATION, 'utf8'))
      .split('--> statement-breakpoint')
      .map((s) => s.trim())
      .filter((s) => s !== '')
    expect(statements).toHaveLength(2)
    expect(statements[0]).toMatch(/^ALTER TABLE "user_artist_seeds" DROP CONSTRAINT "user_artist_seeds_source_check";?$/)
    expect(statements[1]).toMatch(/^ALTER TABLE "user_artist_seeds" ADD CONSTRAINT "user_artist_seeds_source_check" CHECK/)
    expect(statements[1]).toContain("'prompt'")
  })
})
